pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

interface IAggregator {
    function isSenderALoan(address _sender) external view returns (bool);
}

interface IDLOFactory {
    function emitUpdate(address lendOrder) external;
    function emitDelete(address lendOrder) external;
    function deleteOrder(address lendOrder) external;
}

contract DLOImplementation is ReentrancyGuard, Initializable {
    address aggregatorContract;
    address factoryContract;
    bool public isActive;
    uint lastUpdate;

    using SafeERC20 for IERC20;

    struct LendInfo {
        address lendOrderAddress; // address of the lend order
        bool perpetual; // if the loan is perpetual --> every time the loan is paid back, the amount is available again here
        bool lonelyLender; // if the loan is only for one lender, if true, the loan is not available for other lenders
        bool[] oraclesPerPairActivated; // oracles activated for each pair
        uint[] maxLTVs; // max LTV for each collateral
        uint apr; // annual percentage rate you want to lend the tokens for
        uint maxDuration; // max duration of the loan
        uint minDuration; // min duration of the loan
        address owner; // owner of the lend order
        address principle; // address of the principle token
        address[] acceptedCollaterals; // address of the accepted collaterals
        address[] oracle_Collaterals; // address of the oracles for each collateral
        uint[] maxRatio; // max ratio for each collateral
        address oracle_Principle; // address of the oracle for the principle token
        uint startedLendingAmount; // initial amount of the principle token that is available for lending
        uint availableAmount; // amount of the principle token that is available for lending
    }

    LendInfo public lendInformation;

    modifier onlyOwner() {
        require(msg.sender == lendInformation.owner, "Only owner");
        _;
    }

    modifier onlyAggregator() {
        require(msg.sender == aggregatorContract, "Only aggregator");
        _;
    }

    modifier onlyAfterTimeOut() {
        require(
            lastUpdate == 0 || (block.timestamp - lastUpdate) > 1 minutes,
            "Offer has been updated in the last minute"
        );
        _;
    }

    function initialize(
        address _aggregatorContract,
        bool _perpetual,
        bool[] memory _oraclesActivated,
        bool _lonelyLender,
        uint[] memory _maxLTVs,
        uint _apr,
        uint _maxDuration,
        uint _minDuration,
        address _owner,
        address _principle,
        address[] memory _acceptedCollaterals,
        address[] memory _oracleIDS_Collateral,
        uint[] memory _ratio,
        address _oracleID_Principle,
        uint _startedLendingAmount
    ) public initializer {
        aggregatorContract = _aggregatorContract;
        isActive = true;
        // update lendInformation
        lendInformation = LendInfo({
            lendOrderAddress: address(this),
            perpetual: _perpetual,
            oraclesPerPairActivated: _oraclesActivated,
            lonelyLender: _lonelyLender,
            maxLTVs: _maxLTVs,
            apr: _apr,
            maxDuration: _maxDuration,
            minDuration: _minDuration,
            owner: _owner,
            principle: _principle,
            acceptedCollaterals: _acceptedCollaterals,
            oracle_Collaterals: _oracleIDS_Collateral,
            maxRatio: _ratio,
            oracle_Principle: _oracleID_Principle,
            startedLendingAmount: _startedLendingAmount,
            availableAmount: _startedLendingAmount
        });

        factoryContract = msg.sender;
    }

    // function to accept the lending offer
    // only aggregator can call this function
    function acceptLendingOffer(
        uint amount
    ) public onlyAggregator nonReentrant onlyAfterTimeOut {
        LendInfo memory m_lendInformation = lendInformation;
        uint previousAvailableAmount = m_lendInformation.availableAmount;
        require(
            amount <= m_lendInformation.availableAmount,
            "Amount exceeds available amount"
        );
        require(amount > 0, "Amount must be greater than 0");

        lendInformation.availableAmount -= amount;
        SafeERC20.safeTransfer(
            IERC20(m_lendInformation.principle),
            msg.sender,
            amount
        );

        // offer has to be accepted 100% in order to be deleted
        if (
            lendInformation.availableAmount == 0 && !m_lendInformation.perpetual
        ) {
            isActive = false;
            IDLOFactory(factoryContract).emitDelete(address(this));
            IDLOFactory(factoryContract).deleteOrder(address(this));
        } else {
            IDLOFactory(factoryContract).emitUpdate(address(this));
        }

        // emit accepted event on factory
    }

    // function to cancel the lending offer
    // only callable once by the owner
    // in case of perpetual, the funds won't come back here and lender will need to claim it from the lend orders
    function cancelOffer() public onlyOwner nonReentrant {
        uint availableAmount = lendInformation.availableAmount;
        lendInformation.perpetual = false;
        lendInformation.availableAmount = 0;
        require(availableAmount > 0, "No funds to cancel");
        isActive = false;

        SafeERC20.safeTransfer(
            IERC20(lendInformation.principle),
            msg.sender,
            availableAmount
        );
        IDLOFactory(factoryContract).emitDelete(address(this));
        IDLOFactory(factoryContract).deleteOrder(address(this));
        // emit canceled event on factory
    }

    // only loans or owner can call this functions --> add more funds to the offer
    function addFunds(uint amount) public nonReentrant {
        require(
            msg.sender == lendInformation.owner ||
                IAggregator(aggregatorContract).isSenderALoan(msg.sender),
            "Only owner or loan"
        );
        SafeERC20.safeTransferFrom(
            IERC20(lendInformation.principle),
            msg.sender,
            address(this),
            amount
        );
        lendInformation.availableAmount += amount;
        IDLOFactory(factoryContract).emitUpdate(address(this));
    }

    function changePerpetual(bool _perpetual) public onlyOwner nonReentrant {
        require(isActive, "Offer is not active");

        lendInformation.perpetual = _perpetual;
        if (_perpetual == false && lendInformation.availableAmount == 0) {
            IDLOFactory(factoryContract).emitDelete(address(this));
            IDLOFactory(factoryContract).deleteOrder(address(this));
        } else {
            IDLOFactory(factoryContract).emitUpdate(address(this));
        }
    }

    function getLendInfo() public view returns (LendInfo memory) {
        return lendInformation;
    }

    // update lend order information and add a cooldown period of 1 minute to avoid overtaking the tx
    function updateLendOrder(
        uint newApr,
        uint newMaxDuration,
        uint newMinDuration,
        uint[] memory newLTVs,
        uint[] memory newRatios
    ) public onlyOwner {
        require(isActive, "Offer is not active");
        LendInfo memory m_lendInformation = lendInformation;
        require(
            newLTVs.length == m_lendInformation.acceptedCollaterals.length &&
                newLTVs.length == m_lendInformation.maxLTVs.length &&
                newRatios.length ==
                m_lendInformation.acceptedCollaterals.length,
            "Invalid lengths"
        );
        lastUpdate = block.timestamp;
        m_lendInformation.apr = newApr;
        m_lendInformation.maxDuration = newMaxDuration;
        m_lendInformation.minDuration = newMinDuration;
        m_lendInformation.maxLTVs = newLTVs;
        m_lendInformation.maxRatio = newRatios;

        // update to storage
        lendInformation = m_lendInformation;
        IDLOFactory(factoryContract).emitUpdate(address(this));
    }
}
