// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./CurvesERC20.sol";
import "./CurvesERC20Factory.sol";

import "./FeeSplitter.sol";
import "./Security.sol";

interface CurvesErrors {
    // Access-related
    error UnauthorizedCurvesTokenSubject();
    // Balance-related
    error InsufficientPayment();
    error CannotSendFunds();
    error InsufficientBalance();
    // ERC20-related
    error InvalidERC20Metadata();
    error ERC20TokenAlreadyMinted();
    // State-related
    error TokenAbsentForCurvesTokenSubject();
    error CurveAlreadyExists();
    // Transaction-related
    error LastTokenCannotBeSold();
    error ContractCannotReceiveTransfer();
    error ExceededMaxBuyAmount();
    error NonIntegerDepositAmount();
    // Proof-related
    error UnverifiedProof();
    // Presale-related
    error PresaleUnavailable();
    error InvalidPresaleStartTime();
    error SaleNotOpen();
    // Fee related
    error InvalidFeeDefinition();
}

contract Curves is CurvesErrors, Security {
    address public curvesERC20Factory;
    FeeSplitter public feeRedistributor;
    string public constant DEFAULT_NAME = "Curves";
    string public constant DEFAULT_SYMBOL = "CURVES";
    // Counter for CURVES tokens minted
    uint256 private _curvesTokenCounter = 0;

    struct ExternalTokenMeta {
        string name;
        string symbol;
        address token;
    }

    struct PresaleMeta {
        uint256 startTime;
        bytes32 merkleRoot;
        uint256 maxBuy;
    }

    mapping(address => ExternalTokenMeta) public externalCurvesTokens;
    mapping(address => address) public externalCurvesToSubject;
    mapping(string => address) public symbolToSubject;

    mapping(address => PresaleMeta) public presalesMeta;
    mapping(address => mapping(address => uint256)) public presalesBuys;

    struct FeesEconomics {
        address protocolFeeDestination;
        uint256 protocolFeePercent;
        uint256 subjectFeePercent;
        uint256 referralFeePercent;
        uint256 holdersFeePercent;
        uint256 maxFeePercent;
    }

    FeesEconomics public feesEconomics;
    mapping(address => address) public referralFeeDestination;

    event Trade(
        address trader,
        address subject,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 protocolEthAmount,
        uint256 subjectEthAmount,
        uint256 supply
    );

    event Transfer(address indexed curvesTokenSubject, address indexed from, address indexed to, uint256 value);
    event WhitelistUpdated(address indexed presale, bytes32 indexed root);
    event TokenDeployed(address indexed curvesTokenSubject, address indexed erc20token, string name, string symbol);

    // TokenSubject => (Holder => Balance)
    mapping(address => mapping(address => uint256)) public curvesTokenBalance;

    // TokenSubject => Supply
    mapping(address => uint256) public curvesTokenSupply;

    mapping(address => address[]) private ownedCurvesTokenSubjects;

    modifier onlyTokenSubject(address curvesTokenSubject) {
        if (curvesTokenSubject != msg.sender) revert UnauthorizedCurvesTokenSubject();
        _;
    }

    constructor(address curvesERC20Factory_, address feeRedistributor_) Security() {
        curvesERC20Factory = curvesERC20Factory_;
        feeRedistributor = FeeSplitter(payable(feeRedistributor_));
    }

    function setFeeRedistributor(address feeRedistributor_) external onlyOwner {
        feeRedistributor = FeeSplitter(payable(feeRedistributor_));
    }

    function setMaxFeePercent(uint256 maxFeePercent_) external onlyManager {
        if (
            feesEconomics.protocolFeePercent +
                feesEconomics.subjectFeePercent +
                feesEconomics.referralFeePercent +
                feesEconomics.holdersFeePercent >
            maxFeePercent_
        ) revert InvalidFeeDefinition();
        feesEconomics.maxFeePercent = maxFeePercent_;
    }

    function setProtocolFeePercent(uint256 protocolFeePercent_, address protocolFeeDestination_) external onlyOwner {
        if (
            protocolFeePercent_ +
                feesEconomics.subjectFeePercent +
                feesEconomics.referralFeePercent +
                feesEconomics.holdersFeePercent >
            feesEconomics.maxFeePercent ||
            protocolFeeDestination_ == address(0)
        ) revert InvalidFeeDefinition();
        feesEconomics.protocolFeePercent = protocolFeePercent_;
        feesEconomics.protocolFeeDestination = protocolFeeDestination_;
    }

    function setExternalFeePercent(
        uint256 subjectFeePercent_,
        uint256 referralFeePercent_,
        uint256 holdersFeePercent_
    ) external onlyManager {
        if (
            feesEconomics.protocolFeePercent + subjectFeePercent_ + referralFeePercent_ + holdersFeePercent_ >
            feesEconomics.maxFeePercent
        ) revert InvalidFeeDefinition();
        feesEconomics.subjectFeePercent = subjectFeePercent_;
        feesEconomics.referralFeePercent = referralFeePercent_;
        feesEconomics.holdersFeePercent = holdersFeePercent_;
    }

    function setReferralFeeDestination(
        address curvesTokenSubject,
        address referralFeeDestination_
    ) public onlyTokenSubject(curvesTokenSubject) {
        referralFeeDestination[curvesTokenSubject] = referralFeeDestination_;
    }

    function setERC20Factory(address factory_) external onlyOwner {
        curvesERC20Factory = factory_;
    }

    function getFees(
        uint256 price
    )
        public
        view
        returns (uint256 protocolFee, uint256 subjectFee, uint256 referralFee, uint256 holdersFee, uint256 totalFee)
    {
        protocolFee = (price * feesEconomics.protocolFeePercent) / 1 ether;
        subjectFee = (price * feesEconomics.subjectFeePercent) / 1 ether;
        referralFee = (price * feesEconomics.referralFeePercent) / 1 ether;
        holdersFee = (price * feesEconomics.holdersFeePercent) / 1 ether;
        totalFee = protocolFee + subjectFee + referralFee + holdersFee;
    }

    function getPrice(uint256 supply, uint256 amount) public pure returns (uint256) {
        uint256 sum1 = supply == 0 ? 0 : ((supply - 1) * (supply) * (2 * (supply - 1) + 1)) / 6;
        uint256 sum2 = supply == 0 && amount == 1
            ? 0
            : ((supply - 1 + amount) * (supply + amount) * (2 * (supply - 1 + amount) + 1)) / 6;
        uint256 summation = sum2 - sum1;
        return (summation * 1 ether) / 16000;
    }

    function getBuyPrice(address curvesTokenSubject, uint256 amount) public view returns (uint256) {
        return getPrice(curvesTokenSupply[curvesTokenSubject], amount);
    }

    function getSellPrice(address curvesTokenSubject, uint256 amount) public view returns (uint256) {
        return getPrice(curvesTokenSupply[curvesTokenSubject] - amount, amount);
    }

    function getBuyPriceAfterFee(address curvesTokenSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(curvesTokenSubject, amount);
        (, , , , uint256 totalFee) = getFees(price);

        return price + totalFee;
    }

    function getSellPriceAfterFee(address curvesTokenSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(curvesTokenSubject, amount);
        (, , , , uint256 totalFee) = getFees(price);

        return price - totalFee;
    }

    function buyCurvesToken(address curvesTokenSubject, uint256 amount) public payable {
        uint256 startTime = presalesMeta[curvesTokenSubject].startTime;
        if (startTime != 0 && startTime >= block.timestamp) revert SaleNotOpen();

        _buyCurvesToken(curvesTokenSubject, amount);
    }

    function _transferFees(
        address curvesTokenSubject,
        bool isBuy,
        uint256 price,
        uint256 amount,
        uint256 supply
    ) internal {
        (uint256 protocolFee, uint256 subjectFee, uint256 referralFee, uint256 holderFee, ) = getFees(price);
        {
            bool referralDefined = referralFeeDestination[curvesTokenSubject] != address(0);
            {
                address firstDestination = isBuy ? feesEconomics.protocolFeeDestination : msg.sender;
                uint256 buyValue = referralDefined ? protocolFee : protocolFee + referralFee;
                uint256 sellValue = price - protocolFee - subjectFee - referralFee - holderFee;
                (bool success1, ) = firstDestination.call{value: isBuy ? buyValue : sellValue}("");
                if (!success1) revert CannotSendFunds();
            }
            {
                (bool success2, ) = curvesTokenSubject.call{value: subjectFee}("");
                if (!success2) revert CannotSendFunds();
            }
            {
                (bool success3, ) = referralDefined
                    ? referralFeeDestination[curvesTokenSubject].call{value: referralFee}("")
                    : (true, bytes(""));
                if (!success3) revert CannotSendFunds();
            }

            if (feesEconomics.holdersFeePercent > 0 && address(feeRedistributor) != address(0)) {
                feeRedistributor.onBalanceChange(curvesTokenSubject, msg.sender);
                feeRedistributor.addFees{value: holderFee}(curvesTokenSubject);
            }
        }
        emit Trade(
            msg.sender,
            curvesTokenSubject,
            isBuy,
            amount,
            price,
            protocolFee,
            subjectFee,
            isBuy ? supply + amount : supply - amount
        );
    }

    function _buyCurvesToken(address curvesTokenSubject, uint256 amount) internal {
        uint256 supply = curvesTokenSupply[curvesTokenSubject];
        if (!(supply > 0 || curvesTokenSubject == msg.sender)) revert UnauthorizedCurvesTokenSubject();

        uint256 price = getPrice(supply, amount);
        (, , , , uint256 totalFee) = getFees(price);

        if (msg.value < price + totalFee) revert InsufficientPayment();

        curvesTokenBalance[curvesTokenSubject][msg.sender] += amount;
        curvesTokenSupply[curvesTokenSubject] = supply + amount;
        _transferFees(curvesTokenSubject, true, price, amount, supply);

        // If is the first token bought, add to the list of owned tokens
        if (curvesTokenBalance[curvesTokenSubject][msg.sender] - amount == 0) {
            _addOwnedCurvesTokenSubject(msg.sender, curvesTokenSubject);
        }
    }

    function sellCurvesToken(address curvesTokenSubject, uint256 amount) public {
        uint256 supply = curvesTokenSupply[curvesTokenSubject];
        if (supply <= amount) revert LastTokenCannotBeSold();
        if (curvesTokenBalance[curvesTokenSubject][msg.sender] < amount) revert InsufficientBalance();

        uint256 price = getPrice(supply - amount, amount);

        curvesTokenBalance[curvesTokenSubject][msg.sender] -= amount;
        curvesTokenSupply[curvesTokenSubject] = supply - amount;

        _transferFees(curvesTokenSubject, false, price, amount, supply);
    }

    // Transfers tokens from current owner to receiver. Can be used for gifting or distributing tokens.
    function transferCurvesToken(address curvesTokenSubject, address to, uint256 amount) external {
        if (to == address(this)) revert ContractCannotReceiveTransfer();
        _transfer(curvesTokenSubject, msg.sender, to, amount);
    }

    // Transfer the total balance of all my tokens to another address. Can be used for migrating tokens.
    function transferAllCurvesTokens(address to) external {
        if (to == address(this)) revert ContractCannotReceiveTransfer();
        address[] storage subjects = ownedCurvesTokenSubjects[msg.sender];
        for (uint256 i = 0; i < subjects.length; i++) {
            uint256 amount = curvesTokenBalance[subjects[i]][msg.sender];
            if (amount > 0) {
                _transfer(subjects[i], msg.sender, to, amount);
            }
        }
    }

    function _transfer(address curvesTokenSubject, address from, address to, uint256 amount) internal {
        if (amount > curvesTokenBalance[curvesTokenSubject][from]) revert InsufficientBalance();

        // If transferring from oneself, skip adding to the list
        if (from != to) {
            _addOwnedCurvesTokenSubject(to, curvesTokenSubject);
        }

        curvesTokenBalance[curvesTokenSubject][from] = curvesTokenBalance[curvesTokenSubject][from] - amount;
        curvesTokenBalance[curvesTokenSubject][to] = curvesTokenBalance[curvesTokenSubject][to] + amount;

        emit Transfer(curvesTokenSubject, from, to, amount);
    }

    // Internal function to add a curvesTokenSubject to the list if not already present
    function _addOwnedCurvesTokenSubject(address owner_, address curvesTokenSubject) internal {
        address[] storage subjects = ownedCurvesTokenSubjects[owner_];
        for (uint256 i = 0; i < subjects.length; i++) {
            if (subjects[i] == curvesTokenSubject) {
                return;
            }
        }
        subjects.push(curvesTokenSubject);
    }

    function _deployERC20(
        address curvesTokenSubject,
        string memory name,
        string memory symbol
    ) internal returns (address) {
        // If the token's symbol is CURVES, append a counter value
        if (keccak256(bytes(symbol)) == keccak256(bytes(DEFAULT_SYMBOL))) {
            _curvesTokenCounter += 1;
            name = string(abi.encodePacked(name, " ", Strings.toString(_curvesTokenCounter)));
            symbol = string(abi.encodePacked(symbol, Strings.toString(_curvesTokenCounter)));
        }

        if (symbolToSubject[symbol] != address(0)) revert InvalidERC20Metadata();

        address tokenContract = CurvesERC20Factory(curvesERC20Factory).deploy(name, symbol, address(this));

        externalCurvesTokens[curvesTokenSubject].token = tokenContract;
        externalCurvesTokens[curvesTokenSubject].name = name;
        externalCurvesTokens[curvesTokenSubject].symbol = symbol;
        externalCurvesToSubject[tokenContract] = curvesTokenSubject;
        symbolToSubject[symbol] = curvesTokenSubject;

        emit TokenDeployed(curvesTokenSubject, tokenContract, name, symbol);
        return address(tokenContract);
    }

    function buyCurvesTokenWithName(
        address curvesTokenSubject,
        uint256 amount,
        string memory name,
        string memory symbol
    ) public payable {
        uint256 supply = curvesTokenSupply[curvesTokenSubject];
        if (supply != 0) revert CurveAlreadyExists();

        _buyCurvesToken(curvesTokenSubject, amount);
        _mint(curvesTokenSubject, name, symbol);
    }

    function buyCurvesTokenForPresale(
        address curvesTokenSubject,
        uint256 amount,
        uint256 startTime,
        bytes32 merkleRoot,
        uint256 maxBuy
    ) public payable onlyTokenSubject(curvesTokenSubject) {
        if (startTime <= block.timestamp) revert InvalidPresaleStartTime();
        uint256 supply = curvesTokenSupply[curvesTokenSubject];
        if (supply != 0) revert CurveAlreadyExists();
        presalesMeta[curvesTokenSubject].startTime = startTime;
        presalesMeta[curvesTokenSubject].merkleRoot = merkleRoot;
        presalesMeta[curvesTokenSubject].maxBuy = (maxBuy == 0 ? type(uint256).max : maxBuy);

        _buyCurvesToken(curvesTokenSubject, amount);
    }

    function setWhitelist(bytes32 merkleRoot) external {
        uint256 supply = curvesTokenSupply[msg.sender];
        if (supply > 1) revert CurveAlreadyExists();

        if (presalesMeta[msg.sender].merkleRoot != merkleRoot) {
            presalesMeta[msg.sender].merkleRoot = merkleRoot;
            emit WhitelistUpdated(msg.sender, merkleRoot);
        }
    }

    function buyCurvesTokenWhitelisted(
        address curvesTokenSubject,
        uint256 amount,
        bytes32[] memory proof
    ) public payable {
        if (
            presalesMeta[curvesTokenSubject].startTime == 0 ||
            presalesMeta[curvesTokenSubject].startTime <= block.timestamp
        ) revert PresaleUnavailable();

        presalesBuys[curvesTokenSubject][msg.sender] += amount;
        uint256 tokenBought = presalesBuys[curvesTokenSubject][msg.sender];
        if (tokenBought > presalesMeta[curvesTokenSubject].maxBuy) revert ExceededMaxBuyAmount();

        verifyMerkle(curvesTokenSubject, msg.sender, proof);
        _buyCurvesToken(curvesTokenSubject, amount);
    }

    function verifyMerkle(address curvesTokenSubject, address caller, bytes32[] memory proof) public view {
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(caller));
        if (!MerkleProof.verify(proof, presalesMeta[curvesTokenSubject].merkleRoot, leaf)) revert UnverifiedProof();
    }

    function setNameAndSymbol(
        address curvesTokenSubject,
        string memory name,
        string memory symbol
    ) external onlyTokenSubject(curvesTokenSubject) {
        if (externalCurvesTokens[curvesTokenSubject].token != address(0)) revert ERC20TokenAlreadyMinted();
        if (symbolToSubject[symbol] != address(0)) revert InvalidERC20Metadata();
        externalCurvesTokens[curvesTokenSubject].name = name;
        externalCurvesTokens[curvesTokenSubject].symbol = symbol;
    }

    function mint(address curvesTokenSubject) external onlyTokenSubject(curvesTokenSubject) {
        if (
            keccak256(abi.encodePacked(externalCurvesTokens[curvesTokenSubject].name)) ==
            keccak256(abi.encodePacked("")) ||
            keccak256(abi.encodePacked(externalCurvesTokens[curvesTokenSubject].symbol)) ==
            keccak256(abi.encodePacked(""))
        ) {
            externalCurvesTokens[curvesTokenSubject].name = DEFAULT_NAME;
            externalCurvesTokens[curvesTokenSubject].symbol = DEFAULT_SYMBOL;
        }
        _mint(
            curvesTokenSubject,
            externalCurvesTokens[curvesTokenSubject].name,
            externalCurvesTokens[curvesTokenSubject].symbol
        );
    }

    function _mint(
        address curvesTokenSubject,
        string memory name,
        string memory symbol
    ) internal onlyTokenSubject(curvesTokenSubject) {
        if (externalCurvesTokens[curvesTokenSubject].token != address(0)) revert ERC20TokenAlreadyMinted();
        _deployERC20(curvesTokenSubject, name, symbol);
    }

    function withdraw(address curvesTokenSubject, uint256 amount) public {
        if (amount > curvesTokenBalance[curvesTokenSubject][msg.sender]) revert InsufficientBalance();

        address externalToken = externalCurvesTokens[curvesTokenSubject].token;
        if (externalToken == address(0)) {
            if (
                keccak256(abi.encodePacked(externalCurvesTokens[curvesTokenSubject].name)) ==
                keccak256(abi.encodePacked("")) ||
                keccak256(abi.encodePacked(externalCurvesTokens[curvesTokenSubject].symbol)) ==
                keccak256(abi.encodePacked(""))
            ) {
                externalCurvesTokens[curvesTokenSubject].name = DEFAULT_NAME;
                externalCurvesTokens[curvesTokenSubject].symbol = DEFAULT_SYMBOL;
            }
            _deployERC20(
                curvesTokenSubject,
                externalCurvesTokens[curvesTokenSubject].name,
                externalCurvesTokens[curvesTokenSubject].symbol
            );
            externalToken = externalCurvesTokens[curvesTokenSubject].token;
        }
        _transfer(curvesTokenSubject, msg.sender, address(this), amount);
        CurvesERC20(externalToken).mint(msg.sender, amount * 1 ether);
    }

    function deposit(address curvesTokenSubject, uint256 amount) public {
        if (amount % 1 ether != 0) revert NonIntegerDepositAmount();

        address externalToken = externalCurvesTokens[curvesTokenSubject].token;
        uint256 tokenAmount = amount / 1 ether;

        if (externalToken == address(0)) revert TokenAbsentForCurvesTokenSubject();
        if (amount > CurvesERC20(externalToken).balanceOf(msg.sender)) revert InsufficientBalance();
        if (tokenAmount > curvesTokenBalance[curvesTokenSubject][address(this)]) revert InsufficientBalance();

        CurvesERC20(externalToken).burn(msg.sender, amount);
        _transfer(curvesTokenSubject, address(this), msg.sender, tokenAmount);
    }

    function sellExternalCurvesToken(address curvesTokenSubject, uint256 amount) public {
        if (externalCurvesTokens[curvesTokenSubject].token == address(0)) revert TokenAbsentForCurvesTokenSubject();

        deposit(curvesTokenSubject, amount);
        sellCurvesToken(curvesTokenSubject, amount / 1 ether);
    }
}
