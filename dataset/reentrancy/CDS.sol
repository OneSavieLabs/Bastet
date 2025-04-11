// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interface/IUSDa.sol";
import "../interface/IBorrowing.sol";
import "../interface/ITreasury.sol";
import "../interface/CDSInterface.sol";
import "../interface/IMultiSign.sol";
import "../interface/IGlobalVariables.sol";
import "../lib/CDSLib.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../oracles/BasePriceOracle.sol";

/**
 * @title CDS contract
 * @author Autonomint
 * @notice One of the main point of interaction with an Autonomint protocol's market
 * - Users can:
 *   # Deposit USDa and USDT
 *   # Withdraw USDa
 *   # Redeem USDT
 * @dev All admin functions are callable by the admin address only
 */

contract CDS is
    CDSInterface,
    Initializable,
    EIP712Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    IUSDa public usda; // our stablecoin
    IBorrowing private borrowing; // Borrowing contract interface
    ITreasury private treasury; // Treasury contrcat interface
    IMultiSign private multiSign; // multisign instance
    IERC20 private usdt; // USDT interface
    address public admin; // admin address
    address private treasuryAddress; // treasury address
    address private borrowLiquidation; // borrow liquidation instance
    uint128 private lastEthPrice; // Last updated ETH price
    uint64 public cdsCount; // cds depositors count
    uint64 private withdrawTimeLimit; // Fixed Time interval between deposit and withdraw
    uint256 public totalCdsDepositedAmount; // total usda and usdt deposited in cds
    uint256 private totalCdsDepositedAmountWithOptionFees;
    uint256 public totalAvailableLiquidationAmount; // total deposited usda available for liquidation
    uint8 public usdaLimit; // usda limit in percent
    uint64 public usdtLimit; // usdt limit in number
    uint256 public usdtAmountDepositedTillNow; // total usdt deposited till now
    uint256 private burnedUSDaInRedeem; // usda burned in redeem
    mapping(address => CdsDetails) public cdsDetails; // cds user deposit details
    // liquidations info based on liquidation numbers
    mapping(uint128 liquidationIndex => LiquidationInfo)
        private omniChainCDSLiqIndexToInfo; // liquidation info
    using OptionsBuilder for bytes;
    IGlobalVariables private globalVariables; // global variables instance
    uint256 public downsideProtected;
    bytes32 private hashedAdminTwo;
    BasePriceOracle private oracle; // tokenToPriceFeed

    /**
     * @dev initialize function to initialize the contract with initializer modifier
     * @param usdaAddress usda token address
     * @param mpoAddress Master Price Oracle address
     * @param usdtAddress USDT address
     * @param multiSignAddress multi sign address
     */
    function initialize(
        address usdaAddress,
        address mpoAddress,
        address usdtAddress,
        address multiSignAddress
    ) public initializer {
        // Initialize the owner of the contract
        __Ownable_init(msg.sender);
        // Initialize the proxy contracts
        __UUPSUpgradeable_init();
        __EIP712_init("Autonomint", "1");
        usda = IUSDa(usdaAddress); // usda token contract address
        usdt = IERC20(usdtAddress);
        multiSign = IMultiSign(multiSignAddress);
        oracle = BasePriceOracle(mpoAddress);
        lastEthPrice = getLatestData();
    }

    function _authorizeUpgrade(
        address implementation
    ) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the caller is an admin or not
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) revert CDS_CallerIsNotAnAdmin();
        _;
    }
    /**
     * @dev modifier to check whether the caller is an globalVariables or borrowLiquidation or not
     */
    modifier onlyGlobalOrLiquidationContract() {
        if (
            msg.sender != address(globalVariables) &&
            msg.sender != address(borrowLiquidation)
        ) revert CDS_OnlyGlobalOrLiqCanCall();
        _;
    }
    /**
     * @dev modifier to check whether the caller is an borrowing or not
     */
    modifier onlyBorrowingContract() {
        if (msg.sender != address(borrowing)) revert CDS_OnlyBorrowCancall();
        _;
    }

    /**
     * @dev modifier to check whether the fucntion is paused or not
     */
    modifier whenNotPaused(IMultiSign.Functions _function) {
        if (multiSign.functionState(_function)) revert CDS_Paused();
        _;
    }

    /**
     * @dev get the eth price from chainlink
     */
    function getLatestData() private view returns (uint128 ethPrice) {
        (, ethPrice) = oracle.price(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    /**
     * @dev update the last ETH price
     * @param priceAtEvent ETH price during event
     */
    function updateLastEthPrice(uint128 priceAtEvent) private {
        lastEthPrice = priceAtEvent;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param account address to check whether the address is an contract address or EOA
     */
    function isContract(address account) private view returns (bool) {
        return account.code.length > 0;
    }

    /**
     * @dev set admin address
     * @param adminAddress  admin address
     */
    function setAdmin(address adminAddress) external onlyOwner {
        // Check whether the input address is not a zero address and contract
        if (adminAddress == address(0) || isContract(adminAddress)) revert CDS_CantBeContractOrZeroAddress(adminAddress);
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(4))) revert CDS_RequiredApprovalsNotMetToSet();
        admin = adminAddress;
    }

    /**
     * @dev set admin two hashed address
     * @param hashedAddress  hashed admin two address
     */
    function setAdminTwo(bytes32 hashedAddress) external onlyAdmin {
        // Check whether the input address is not a zero address and contract
        if (hashedAddress == keccak256(abi.encodePacked(address(0)))) revert CDS_CantBeZeroAddress(hashedAddress);
        hashedAdminTwo = hashedAddress;
    }

    /**
     * @dev The user can deposit usda and usdt to cds.
     * The user can also opt for liquidation gains if wanted.
     * Upto $20K, the user can able to deposit usdt only after that, the user can able to deposit
     * the full amount in usda itself.
     * @param usdtAmount usdt amount to deposit
     * @param usdaAmount usda amount to deposit
     * @param liquidate whether the user opted for liquidation
     * @param liquidationAmount If opted for liquidation,the liquidation amount
     */
    function deposit(
        uint128 usdtAmount,
        uint128 usdaAmount,
        bool liquidate,
        uint128 liquidationAmount,
        uint128 lockingPeriod
    ) public payable nonReentrant whenNotPaused(IMultiSign.Functions(4)) {
        // Get eth price
        uint128 ethPrice = getLatestData();

        // Check the eth price is non zero
        if (ethPrice == 0) revert CDS_ETH_PriceFeed_Failed();

        DepositResult memory result = CDSLib.deposit(
            DepositUserParams(
                usdtAmount,
                usdaAmount,
                liquidate,
                liquidationAmount,
                ethPrice,
                lastEthPrice,
                usdaLimit,
                usdtLimit,
                usdtAmountDepositedTillNow,
                totalCdsDepositedAmount,
                totalCdsDepositedAmountWithOptionFees,
                totalAvailableLiquidationAmount,
                cdsCount,
                lockingPeriod
            ),
            cdsDetails,
            Interfaces(
                treasury,
                globalVariables,
                usda,
                usdt,
                borrowing,
                CDSInterface(address(this))
            )
        );

        usdtAmountDepositedTillNow = result.usdtAmountDepositedTillNow;
        totalCdsDepositedAmount = result.totalCdsDepositedAmount;
        totalCdsDepositedAmountWithOptionFees = result.totalCdsDepositedAmountWithOptionFees;
        totalAvailableLiquidationAmount = result.totalAvailableLiquidationAmount;
        cdsCount = result.cdsCount;

        // updating totalCdsDepositedAmount by considering downsideProtected
        _updateCurrentTotalCdsDepositedAmount();

        if (ethPrice != lastEthPrice) {
            updateLastEthPrice(ethPrice);
        }

        // getting options since,the src don't know the dst state
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);

        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            IBorrowing.AssetName(0),
            _options,
            false
        );

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            IBorrowing.AssetName(0),
            fee,
            _options,
            msg.sender
        );

        // emit Deposit event
        emit Deposit(
            msg.sender,
            cdsDetails[msg.sender].index,
            usdaAmount,
            usdtAmount,
            block.timestamp,
            ethPrice,
            60,
            liquidationAmount,
            liquidate
        );
    }

    /**
     * @dev withdraw the deposited amount in usda with options fees,
     * upsides and liquidation gains if opted for liquidation gains during deposit.
     * @param index index of the deposit to withdraw
     */
    function withdraw(
        uint64 index,
        uint256 excessProfitCumulativeValue,
        uint256 nonce,
        bytes memory signature
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(5)) {
        if (!_verify(FunctionName.CDS_WITHDRAW, excessProfitCumulativeValue, nonce, "0x", signature)) revert CDS_NotAnAdminTwo();
        // Check whether the entered index is present or not
        if (cdsDetails[msg.sender].index < index) revert CDS_InvalidIndex();

        CdsAccountDetails memory cdsDepositDetails = cdsDetails[msg.sender].cdsAccountDetails[index];
        if (cdsDepositDetails.withdrawed) revert CDS_AlreadyWithdrew();

        // Check whether the withdraw time limit is reached or not
        if (cdsDepositDetails.depositedTime + withdrawTimeLimit > uint64(block.timestamp)) revert CDS_WithdrawTimeNotYetReached();

        cdsDepositDetails.withdrawed = true;

        if (cdsDetails[msg.sender].index == 1 && index == 1) {
            --cdsCount;
        }

        // Get the exchange rate and eth price for all collaterals
        (uint128 weETH_ExchangeRate, uint128 ethPrice) = borrowing.getUSDValue(borrowing.assetAddress(IBorrowing.AssetName.WeETH));
        (uint128 rsETH_ExchangeRate, ) = borrowing.getUSDValue(borrowing.assetAddress(IBorrowing.AssetName.WrsETH));

        if (ethPrice == 0) revert CDS_ETH_PriceFeed_Failed();
        // Get the global omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();

        // Calculate current value
        CalculateValueResult memory result = _calculateCumulativeValue(
            omniChainData.totalVolumeOfBorrowersAmountinWei,
            omniChainData.totalCdsDepositedAmount,
            ethPrice
        );

        // Set the cumulative vaue
        (omniChainData.cumulativeValue, omniChainData.cumulativeValueSign) = getCumulativeValue(
            omniChainData,
            result.currentValue,
            result.gains
        );

        // updating totalCdsDepositedAmount by considering downsideProtected
        _updateCurrentTotalCdsDepositedAmount();

        // updating global data
        if (omniChainData.downsideProtected > 0) {
            omniChainData.totalCdsDepositedAmount -= omniChainData.downsideProtected;
            omniChainData.totalCdsDepositedAmountWithOptionFees -= omniChainData.downsideProtected;
            omniChainData.downsideProtected = 0;
        }

        // Calculate return amount includes eth Price difference gain or loss option fees
        uint256 optionFees = ((cdsDepositDetails.normalizedAmount * omniChainData.lastCumulativeRate) /
            (CDSLib.PRECISION * CDSLib.NORM_PRECISION)) - cdsDepositDetails.depositedAmount;

        // Calculate the options fees to get from other chains
        uint256 optionsFeesToGetFromOtherChain = getOptionsFeesProportions(optionFees);

        // Update user deposit data
        cdsDepositDetails.withdrawedTime = uint64(block.timestamp);
        cdsDepositDetails.ethPriceAtWithdraw = ethPrice;
        uint256 currentValue = cdsAmountToReturn(
            msg.sender,
            index,
            omniChainData.cumulativeValue,
            omniChainData.cumulativeValueSign,
            excessProfitCumulativeValue
        ) - 1; //? subtracted extra 1 wei

        cdsDepositDetails.depositedAmount = currentValue;
        uint256 returnAmount = cdsDepositDetails.depositedAmount + optionFees;
        cdsDepositDetails.withdrawedAmount = returnAmount;

        // getting options since,the src don't know the dst state
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);

        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(2),
            IBorrowing.AssetName(0),
            _options,
            false
        );
        WithdrawResult memory withdrawResult;

        withdrawResult = CDSLib.withdrawUser(
            WithdrawUserParams(
                cdsDepositDetails,
                omniChainData,
                optionFees,
                optionsFeesToGetFromOtherChain,
                returnAmount,
                withdrawResult.ethAmount,
                withdrawResult.usdaToTransfer,
                weETH_ExchangeRate,
                rsETH_ExchangeRate,
                fee.nativeFee
            ),
            Interfaces(
                treasury,
                globalVariables,
                usda,
                usdt,
                borrowing,
                CDSInterface(address(this))
            ),
            totalCdsDepositedAmount,
            totalCdsDepositedAmountWithOptionFees,
            omniChainCDSLiqIndexToInfo
        );

        totalCdsDepositedAmount = withdrawResult.totalCdsDepositedAmount;
        totalCdsDepositedAmountWithOptionFees = withdrawResult.totalCdsDepositedAmountWithOptionFees;
        withdrawResult.omniChainData.cdsPoolValue -= cdsDepositDetails.depositedAmount;
        // Update the user deposit data
        cdsDetails[msg.sender].cdsAccountDetails[index] = withdrawResult.cdsDepositDetails;
        // Update the global omnichain struct
        globalVariables.setOmniChainData(withdrawResult.omniChainData);
        // Check whether after withdraw cds have enough funds to protect borrower's collateral
        if (withdrawResult.omniChainData.totalVolumeOfBorrowersAmountinWei != 0) {
            if (borrowing.calculateRatio(0, ethPrice) < (2 * CDSLib.RATIO_PRECISION)) revert CDS_NotEnoughFundInCDS();
        }

        if (ethPrice != lastEthPrice) {
            updateLastEthPrice(ethPrice);
        }
        // if both optionsFeesToGetFromOtherChain & ethAmount are zero return the gas fee
        if (optionsFeesToGetFromOtherChain == 0 && withdrawResult.ethAmount == 0) {
            (bool sent, ) = payable(msg.sender).call{value: msg.value - fee.nativeFee}("");
            if (!sent) revert CDS_ETH_TransferFailed();
        }

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(2),
            IBorrowing.AssetName(0),
            fee,
            _options,
            msg.sender
        );

        emit Withdraw(
            msg.sender,
            index,
            withdrawResult.usdaToTransfer,
            block.timestamp,
            withdrawResult.ethAmount,
            ethPrice,
            withdrawResult.optionFees,
            withdrawResult.optionFees
        );
    }

    /**
     * @dev calculating Ethereum value to return to CDS owner
     * The function will deduct some amount of ether if it is borrowed
     * Deduced amount will be calculated using the percentage of CDS a user owns
     * @param _user CDS user address
     * @param index Index of the position
     */
    function cdsAmountToReturn(
        address _user,
        uint64 index,
        uint128 cumulativeValue,
        bool cumulativeValueSign,
        uint256 excessProfitCumulativeValue
    ) private view returns (uint256) {
        uint256 depositedAmount = cdsDetails[_user].cdsAccountDetails[index].depositedAmount;
        uint128 cumulativeValueAtDeposit = cdsDetails[msg.sender].cdsAccountDetails[index].depositValue;
        // Get the cumulative value sign at the time of deposit
        bool cumulativeValueSignAtDeposit = cdsDetails[msg.sender].cdsAccountDetails[index].depositValueSign;
        uint128 valDiff;
        uint128 cumulativeValueAtWithdraw = cumulativeValue;

        // If the depositVal and cumulativeValue both are in same sign
        if (cumulativeValueSignAtDeposit == cumulativeValueSign) {
            // Calculate the value difference
            if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                valDiff = cumulativeValueAtDeposit - cumulativeValueAtWithdraw;
            } else {
                valDiff = cumulativeValueAtWithdraw - cumulativeValueAtDeposit;
            }
            // If cumulative value sign at the time of deposit is positive
            if (cumulativeValueSignAtDeposit) {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    // Its loss since cumulative val is low
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                } else {
                    // Its gain since cumulative val is high
                    uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                    return (depositedAmount + profit);
                }
            } else {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    // Its gain since cumulative val is high
                    uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                    return (depositedAmount + profit);
                } else {
                    // Its loss since cumulative val is low
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                }
            }
        } else {
            valDiff = cumulativeValueAtDeposit + cumulativeValueAtWithdraw;
            if (cumulativeValueSignAtDeposit) {
                // Its loss since cumulative val at deposit is positive
                uint256 loss = (depositedAmount * valDiff) / 1e11;
                return (depositedAmount - loss);
            } else {
                // Its loss since cumulative val at deposit is negative
                uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                return (depositedAmount + profit);
            }
        }
    }

    /**
     * @dev acts as dex, where the user can swap usda for usdt.
     * @param usdaAmount usda amount to deposit
     * @param usdaPrice usda price
     * @param usdtPrice usdt price
     */
    function redeemUSDT(
        uint128 usdaAmount,
        uint64 usdaPrice,
        uint64 usdtPrice
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(6)) {
        burnedUSDaInRedeem = CDSLib.redeemUSDT(
            Interfaces(
                treasury,
                globalVariables,
                usda,
                usdt,
                borrowing,
                CDSInterface(address(this))
            ),
            burnedUSDaInRedeem,
            usdaAmount,
            usdaPrice,
            usdtPrice
        );

        // getting options since,the src don't know the dst state
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);

        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            IBorrowing.AssetName(0),
            _options,
            false
        );

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            IBorrowing.AssetName(0),
            fee,
            _options,
            msg.sender
        );
    }

    /**
     * @dev set the withdraw time limit
     * @param _timeLimit timelimit in seconds
     */
    function setWithdrawTimeLimit(uint64 _timeLimit) external onlyAdmin {
        // Check he timelimit is non zero
        if (_timeLimit == 0) revert CDS_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(2))) revert CDS_RequiredApprovalsNotMetToSet();
        withdrawTimeLimit = _timeLimit;
    }

    /**
     * @dev set the borrowing contract
     * @param _address Borrowing contract address
     */
    function setBorrowingContract(address _address) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_address == address(0) || !isContract(_address)) revert CDS_CantBeEOAOrZeroAddress(_address);
        borrowing = IBorrowing(_address);
    }

    /**
     * @dev set the treasury contract
     * @param _treasury Treasuty contract address
     */
    function setTreasury(address _treasury) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_treasury == address(0) || !isContract(_treasury)) revert CDS_CantBeEOAOrZeroAddress(_treasury);
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(6))) revert CDS_RequiredApprovalsNotMetToSet();
        treasuryAddress = _treasury;
        treasury = ITreasury(_treasury);
    }

    /**
     * @dev set the borrow liquidation address
     * @param _address Borrow Liquidation address
     */
    function setBorrowLiquidation(address _address) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_address == address(0) || !isContract(_address)) revert CDS_CantBeEOAOrZeroAddress(_address);
        borrowLiquidation = _address;
    }

    /**
     * @dev set the global variables contract
     * @param _address Global variables address
     */
    function setGlobalVariables(address _address) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_address == address(0) || !isContract(_address)) revert CDS_CantBeEOAOrZeroAddress(_address);
        globalVariables = IGlobalVariables(_address);
        // GEt the omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        omniChainData.lastCumulativeRate = CDSLib.PRECISION;
        omniChainData.cumulativeValueSign = true;
        globalVariables.setOmniChainData(omniChainData);
    }

    /**
     * @dev set usda limit in deposit
     * @param percent USDa deposit limit in percentage
     */
    function setUSDaLimit(uint8 percent) external onlyAdmin {
        // Checkt the percent is non zero
        if (percent == 0) revert CDS_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(8))) revert CDS_RequiredApprovalsNotMetToSet();
        usdaLimit = percent;
    }

    /**
     * @dev set usdt time limit in deposit
     * @param amount USDT amount in wei
     */
    function setUsdtLimit(uint64 amount) external onlyAdmin {
        // Check the amount is non zero
        if (amount == 0) revert CDS_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(9))) revert CDS_RequiredApprovalsNotMetToSet();
        usdtLimit = amount;
    }

    function calculateCumulativeValue(
        uint256 vaultBal,
        uint256 globalTotalCdsDepositedAmount,
        uint128 _price
    ) external onlyBorrowingContract returns (CalculateValueResult memory result)
    {
        return _calculateCumulativeValue(vaultBal, globalTotalCdsDepositedAmount, _price);
    }

    /**
     * @dev calculate the cumulative value
     * @param _price ETH price
     */
    function _calculateCumulativeValue(
        uint256 vaultBal,
        uint256 globalTotalCdsDepositedAmount,
        uint128 _price
    ) private returns (CalculateValueResult memory result) {
        // Call calculate value in cds library
        result = CDSLib.calculateCumulativeValue(
            _price,
            globalTotalCdsDepositedAmount,
            lastEthPrice,
            // fallbackEthPrice,
            vaultBal
        );

        // updating last and fallback eth prices
        updateLastEthPrice(_price);
    }

    /**
     * @dev calculate cumulative rate
     * @param fees fees to split
     */
    function calculateCumulativeRate(
        uint128 fees
    ) external onlyBorrowingContract returns (uint128) {
        // get omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // call calculate cumulative rate in cds library
        (
            totalCdsDepositedAmountWithOptionFees,
            omniChainData.totalCdsDepositedAmountWithOptionFees,
            omniChainData.lastCumulativeRate
        ) = CDSLib.calculateCumulativeRate(
            fees,
            getTotalCdsDepositedAmount(),
            getTotalCdsDepositedAmountWithOptionFees(),
            omniChainData.totalCdsDepositedAmountWithOptionFees - omniChainData.downsideProtected,
            omniChainData.lastCumulativeRate,
            omniChainData.noOfBorrowers
        );

        return omniChainData.lastCumulativeRate;
    }

    /**
     * @param value cumulative value to add or subtract
     * @param gains if true,add value else subtract
     */
    function getCumulativeValue(
        IGlobalVariables.OmniChainData memory omniChainData,
        uint128 value,
        bool gains
    ) public pure returns (uint128, bool) {
        // call set cumulative value in cds library
        return CDSLib.getCumulativeValue(
                    value,
                    gains,
                    omniChainData.cumulativeValueSign,
                    omniChainData.cumulativeValue
                );
    }

    /**
     * @dev get the options fees to get from  other chains
     * @param optionsFees Total Options fees
     */
    function getOptionsFeesProportions(
        uint256 optionsFees
    ) private view returns (uint256) {
        // GEt the omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Call getOptionsFeesProportions in cds library
        return CDSLib.getOptionsFeesProportions(
                    optionsFees,
                    totalCdsDepositedAmount,
                    omniChainData.totalCdsDepositedAmount - omniChainData.downsideProtected,
                    totalCdsDepositedAmountWithOptionFees,
                    omniChainData.totalCdsDepositedAmountWithOptionFees - omniChainData.downsideProtected
                );
    }

    /**
     * @dev returns the yields gained by user
     * @param user CDS user address
     * @param index Deposited index
     */
    function calculateLiquidatedETHTogiveToUser(
        address user,
        uint64 index
    ) external view returns (uint256, uint256, uint128, uint256) {
        CDSInterface.CdsAccountDetails memory cdsDepositData = cdsDetails[user].cdsAccountDetails[index];
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        uint256 ethAmount;
        uint128 profit;
        uint256 priceChangePL = CDSLib.cdsAmountToReturn(
            cdsDepositData,
            CDSLib.calculateCumulativeValue(
                uint128(getLatestData()),
                omniChainData.totalCdsDepositedAmount - omniChainData.downsideProtected,
                lastEthPrice,
                omniChainData.totalVolumeOfBorrowersAmountinWei
            ),
            omniChainData.cumulativeValue,
            omniChainData.cumulativeValueSign
        );

        uint256 returnAmount = (cdsDepositData.normalizedAmount * omniChainData.lastCumulativeRate) / CDSLib.PRECISION;
        if (cdsDepositData.optedLiquidation) {
            returnAmount -= cdsDepositData.liquidationAmount;
            uint128 currentLiquidations = omniChainData.noOfLiquidations;
            uint128 liquidationIndexAtDeposit = cdsDepositData.liquidationindex;
            if (currentLiquidations >= liquidationIndexAtDeposit) {
                // Loop through the liquidations that were done after user enters
                for (uint128 i = (liquidationIndexAtDeposit + 1); i <= currentLiquidations; i++) {
                    uint128 liquidationAmount = cdsDepositData.liquidationAmount;
                    if (liquidationAmount > 0) {
                        CDSInterface.LiquidationInfo memory liquidationData = omniChainCDSLiqIndexToInfo[i];

                        uint128 share = (liquidationAmount * 1e10) / uint128(liquidationData.availableLiquidationAmount);

                        profit += (liquidationData.profits * share) / 1e10;
                        cdsDepositData.liquidationAmount -= ((liquidationData.liquidationAmount * share) / 1e10);
                        ethAmount = (liquidationData.collateralAmount * share) / 1e10;
                    }
                }
            }
            returnAmount += cdsDepositData.liquidationAmount;
        } else {
            ethAmount = 0;
            profit = 0;
        }
        return (returnAmount, priceChangePL, profit, ethAmount);
    }

    /**
     * @dev update the liquidation info
     * @param index Liquidation index
     * @param liquidationData struct, contains liquidation details
     */
    function updateLiquidationInfo(
        uint128 index,
        LiquidationInfo memory liquidationData
    ) external onlyGlobalOrLiquidationContract {
        omniChainCDSLiqIndexToInfo[index] = liquidationData;
    }

    /**
     * @dev update Total Available Liquidation Amount
     * @param amount Liquiation amount used for liquidation
     */
    function updateTotalAvailableLiquidationAmount(
        uint256 amount
    ) external onlyGlobalOrLiquidationContract {
        // If the totalAvailableLiquidationAmount is non zero
        if (totalAvailableLiquidationAmount != 0) {
            totalAvailableLiquidationAmount -= amount;
        }
    }

    /**
     * @dev update the total cds deposited amount
     * @param _amount Liquiation amount used for liquidation
     */
    function updateTotalCdsDepositedAmount(
        uint128 _amount
    ) external onlyGlobalOrLiquidationContract {
        // If the totalCdsDepositedAmount is non zero
        if (totalCdsDepositedAmount != 0) {
            totalCdsDepositedAmount -= _amount;
        }
    }

    /**
     * @dev update the total cds deposited amount with options fees
     * @param _amount Liquiation amount used for liquidation
     */
    function updateTotalCdsDepositedAmountWithOptionFees(
        uint128 _amount
    ) external onlyGlobalOrLiquidationContract {
        // If the totalCdsDepositedAmountWithOptionFees is non zero
        if (totalCdsDepositedAmountWithOptionFees != 0) {
            totalCdsDepositedAmountWithOptionFees -= _amount;
        }
    }

    function updateDownsideProtected(uint128 downsideProtectedAmount) external {
        downsideProtected += downsideProtectedAmount;
    }

    function _updateCurrentTotalCdsDepositedAmount() private {
        if (downsideProtected > 0) {
            totalCdsDepositedAmount -= downsideProtected;
            totalCdsDepositedAmountWithOptionFees -= downsideProtected;
            downsideProtected = 0;
        }
    }

    /**
     * @dev Get the cds deposit details
     * @param depositor cds user address
     * @param index index of the deposit to get details
     */
    function getCDSDepositDetails(
        address depositor,
        uint64 index
    ) external view returns (CdsAccountDetails memory, uint64) {
        return (
            cdsDetails[depositor].cdsAccountDetails[index],
            cdsDetails[depositor].index
        );
    }

    function getTotalCdsDepositedAmount() public view returns (uint256) {
        return totalCdsDepositedAmount - downsideProtected;
    }

    function getTotalCdsDepositedAmountWithOptionFees() public view returns (uint256) {
        return totalCdsDepositedAmountWithOptionFees - downsideProtected;
    }

    function verify(
        bytes memory odosExecutionData,
        bytes memory signature
    ) external view onlyBorrowingContract returns (bool) {
        return
            _verify(
                FunctionName.BORROW_WITHDRAW,
                0,
                0,
                odosExecutionData,
                signature
            );
    }

    function _verify(
        FunctionName functionName,
        uint256 excessProfitCumulativeValue,
        uint256 nonce,
        bytes memory odosExecutionData,
        bytes memory signature
    ) private view returns (bool) {
        bytes32 digest;
        if (functionName == FunctionName.CDS_WITHDRAW) {
            digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(uint256 excessProfitCumulativeValue,uint256 nonce)"
                        ),
                        excessProfitCumulativeValue,
                        nonce
                    )
                )
            );
        } else if (functionName == FunctionName.BORROW_WITHDRAW) {
            digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256("OdosPermit(bytes odosExecutionData)"),
                        odosExecutionData
                    )
                )
            );
        }

        address signer = ECDSA.recover(digest, signature);
        bytes32 hashedSigner = keccak256(abi.encodePacked(signer));
        if (hashedSigner == hashedAdminTwo) {
            return true;
        } else {
            return false;
        }
    }
}
