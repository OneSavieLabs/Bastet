// SPDX-License-Identifier: ISC
pragma solidity ^0.8.15;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================= FraxlendPairCore =========================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author
// Drake Evans: https://github.com/DrakeEvans

// Reviewers
// Dennis: https://github.com/denett
// Sam Kazemian: https://github.com/samkazemian
// Travis Moore: https://github.com/FortisFortuna
// Jack Corddry: https://github.com/corddry
// Rich Gee: https://github.com/zer0blockchain

// ====================================================================

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./FraxlendPairConstants.sol";
import "./libraries/VaultAccount.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IERC4626.sol";
import "./interfaces/IFraxlendWhitelist.sol";
import "./interfaces/IRateCalculator.sol";
import "./interfaces/ISwapper.sol";

/// @title FraxlendPairCore
/// @author Drake Evans (Frax Finance) https://github.com/drakeevans
/// @notice  An abstract contract which contains the core logic and storage for the FraxlendPair
abstract contract FraxlendPairCore is FraxlendPairConstants, IERC4626, ERC20, Ownable, Pausable, ReentrancyGuard {
    using VaultAccountingLibrary for VaultAccount;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    string public version = "1.0.0";

    // ============================================================================================
    // Settings set by constructor() & initialize()
    // ============================================================================================

    // Asset and collateral contracts
    IERC20 internal immutable assetContract;
    IERC20 public immutable collateralContract;

    // Oracle wrapper contract and oracleData
    address public immutable oracleMultiply;
    address public immutable oracleDivide;
    uint256 public immutable oracleNormalization;

    // LTV Settings
    uint256 public immutable maxLTV;

    // Liquidation Fee
    uint256 public immutable cleanLiquidationFee;
    uint256 public immutable dirtyLiquidationFee;

    // Interest Rate Calculator Contract
    IRateCalculator public immutable rateContract; // For complex rate calculations
    bytes public rateInitCallData; // Optional extra data from init function to be passed to rate calculator

    // Swapper
    mapping(address => bool) public swappers; // approved swapper addresses

    // Deployer
    address public immutable DEPLOYER_ADDRESS;

    // Admin contracts
    address public immutable CIRCUIT_BREAKER_ADDRESS;
    address public immutable COMPTROLLER_ADDRESS;
    address public TIME_LOCK_ADDRESS;

    // Dependencies
    address public immutable FRAXLEND_WHITELIST_ADDRESS;

    // ERC20 token name, accessible via name()
    string internal nameOfContract;

    // Maturity Date & Penalty Interest Rate (per Sec)
    uint256 public immutable maturityDate;
    uint256 public immutable penaltyRate;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Stores information about the current interest rate
    /// @dev struct is packed to reduce SLOADs. feeToProtocolRate is 1e5 precision, ratePerSec is 1e18 precision
    CurrentRateInfo public currentRateInfo;
    struct CurrentRateInfo {
        uint64 lastBlock;
        uint64 feeToProtocolRate; // Fee amount 1e5 precision
        uint64 lastTimestamp;
        uint64 ratePerSec;
    }

    /// @notice Stores information about the current exchange rate. Collateral:Asset ratio
    /// @dev Struct packed to save SLOADs. Amount of Collateral Token to buy 1e18 Asset Token
    ExchangeRateInfo public exchangeRateInfo;
    struct ExchangeRateInfo {
        uint32 lastTimestamp;
        uint224 exchangeRate; // collateral:asset ratio. i.e. how much collateral to buy 1e18 asset
    }

    // Contract Level Accounting
    VaultAccount public totalAsset; // amount = total amount of assets, shares = total shares outstanding
    VaultAccount public totalBorrow; // amount = total borrow amount with interest accrued, shares = total shares outstanding
    uint256 public totalCollateral; // total amount of collateral in contract

    // User Level Accounting
    /// @notice Stores the balance of collateral for each user
    mapping(address => uint256) public userCollateralBalance; // amount of collateral each user is backed
    /// @notice Stores the balance of borrow shares for each user
    mapping(address => uint256) public userBorrowShares; // represents the shares held by individuals
    // NOTE: user shares of assets are represented as ERC-20 tokens and accessible via balanceOf()

    // Internal Whitelists
    bool public immutable borrowerWhitelistActive;
    mapping(address => bool) public approvedBorrowers;

    bool public immutable lenderWhitelistActive;
    mapping(address => bool) public approvedLenders;

    // ============================================================================================
    // Initialize
    // ============================================================================================

    /// @notice The ```constructor``` function is called on deployment
    /// @param _configData abi.encode(address _asset, address _collateral, address _oracleMultiply, address _oracleDivide, uint256 _oracleNormalization, address _rateContract, bytes memory _rateInitData)
    /// @param _maxLTV The Maximum Loan-To-Value for a borrower to be considered solvent (1e5 precision)
    /// @param _liquidationFee The fee paid to liquidators given as a % of the repayment (1e5 precision)
    /// @param _maturityDate The maturityDate date of the Pair
    /// @param _penaltyRate The interest rate after maturity date
    /// @param _isBorrowerWhitelistActive Enables borrower whitelist
    /// @param _isLenderWhitelistActive Enables lender whitelist
    constructor(
        bytes memory _configData,
        bytes memory _immutables,
        uint256 _maxLTV,
        uint256 _liquidationFee,
        uint256 _maturityDate,
        uint256 _penaltyRate,
        bool _isBorrowerWhitelistActive,
        bool _isLenderWhitelistActive
    ) {
        // Handle Immutables Configuration
        {
            (
                address _circuitBreaker,
                address _comptrollerAddress,
                address _timeLockAddress,
                address _fraxlendWhitelistAddress
            ) = abi.decode(_immutables, (address, address, address, address));

            // Deployer contract
            DEPLOYER_ADDRESS = msg.sender;
            CIRCUIT_BREAKER_ADDRESS = _circuitBreaker;
            COMPTROLLER_ADDRESS = _comptrollerAddress;
            TIME_LOCK_ADDRESS = _timeLockAddress;
            FRAXLEND_WHITELIST_ADDRESS = _fraxlendWhitelistAddress;
        }

        {
            (
                address _asset,
                address _collateral,
                address _oracleMultiply,
                address _oracleDivide,
                uint256 _oracleNormalization,
                address _rateContract,

            ) = abi.decode(_configData, (address, address, address, address, uint256, address, bytes));

            // Pair Settings
            assetContract = IERC20(_asset);
            collateralContract = IERC20(_collateral);
            currentRateInfo.feeToProtocolRate = DEFAULT_PROTOCOL_FEE;
            cleanLiquidationFee = _liquidationFee;
            dirtyLiquidationFee = (_liquidationFee * 9000) / LIQ_PRECISION; // 90% of clean fee

            if (_maxLTV >= LTV_PRECISION && !_isBorrowerWhitelistActive) revert BorrowerWhitelistRequired();
            maxLTV = _maxLTV;

            // Swapper Settings
            swappers[FRAXSWAP_ROUTER_ADDRESS] = true;

            // Oracle Settings
            {
                IFraxlendWhitelist _fraxlendWhitelist = IFraxlendWhitelist(FRAXLEND_WHITELIST_ADDRESS);
                // Check that oracles are on the whitelist
                if (_oracleMultiply != address(0) && !_fraxlendWhitelist.oracleContractWhitelist(_oracleMultiply)) {
                    revert NotOnWhitelist(_oracleMultiply);
                }

                if (_oracleDivide != address(0) && !_fraxlendWhitelist.oracleContractWhitelist(_oracleDivide)) {
                    revert NotOnWhitelist(_oracleDivide);
                }

                // Write oracleData to storage
                oracleMultiply = _oracleMultiply;
                oracleDivide = _oracleDivide;
                oracleNormalization = _oracleNormalization;

                // Rate Settings
                if (!_fraxlendWhitelist.rateContractWhitelist(_rateContract)) {
                    revert NotOnWhitelist(_rateContract);
                }
            }

            rateContract = IRateCalculator(_rateContract);
        }

        // Set approved borrowers whitelist
        borrowerWhitelistActive = _isBorrowerWhitelistActive;

        // Set approved lenders whitlist active
        lenderWhitelistActive = _isLenderWhitelistActive;

        // Set maturity date & penalty interest rate
        maturityDate = _maturityDate;
        penaltyRate = _penaltyRate;
    }

    /// @notice The ```initialize``` function is called immediately after deployment
    /// @dev This function can only be called by the deployer
    /// @param _name The name of the contract
    /// @param _approvedBorrowers An array of approved borrower addresses
    /// @param _approvedLenders An array of approved lender addresses
    /// @param _rateInitCallData The configuration data for the Rate Calculator contract
    function initialize(
        string calldata _name,
        address[] calldata _approvedBorrowers,
        address[] calldata _approvedLenders,
        bytes calldata _rateInitCallData
    ) external {
        if (msg.sender != DEPLOYER_ADDRESS) {
            revert NotDeployer();
        }
        if (bytes(_name).length == 0) {
            revert NameEmpty();
        }
        if (bytes(nameOfContract).length != 0) {
            revert AlreadyInitialized();
        }

        // Set name
        nameOfContract = _name;

        // Set approved borrowers
        for (uint256 i = 0; i < _approvedBorrowers.length; ++i) {
            approvedBorrowers[_approvedBorrowers[i]] = true;
        }

        // Set approved lenders
        for (uint256 i = 0; i < _approvedLenders.length; ++i) {
            approvedLenders[_approvedLenders[i]] = true;
        }

        // Reverts if init data is not valid
        IRateCalculator(rateContract).requireValidInitData(_rateInitCallData);

        // Set rate init Data
        rateInitCallData = _rateInitCallData;

        // Instantiate Interest
        _addInterest();

        // Instantiate Exchange Rate
        _updateExchangeRate();
    }

    // ============================================================================================
    // Internal Helpers
    // ============================================================================================

    /// @notice The ```_totalAssetAvailable``` function returns the total balance of Asset Tokens in the contract
    /// @param _totalAsset VaultAccount struct which stores total amount and shares for assets
    /// @param _totalBorrow VaultAccount struct which stores total amount and shares for borrows
    /// @return The balance of Asset Tokens held by contract
    function _totalAssetAvailable(VaultAccount memory _totalAsset, VaultAccount memory _totalBorrow)
        internal
        pure
        returns (uint256)
    {
        return _totalAsset.amount - _totalBorrow.amount;
    }

    /// @notice The ```_isSolvent``` function determines if a given borrower is solvent given an exchange rate
    /// @param _borrower The borrower address to check
    /// @param _exchangeRate The exchange rate, i.e. the amount of collateral to buy 1e18 asset
    /// @return Whether borrower is solvent
    function _isSolvent(address _borrower, uint256 _exchangeRate) internal view returns (bool) {
        if (maxLTV == 0) return true;
        uint256 _borrowerAmount = totalBorrow.toAmount(userBorrowShares[_borrower], true);
        if (_borrowerAmount == 0) return true;
        uint256 _collateralAmount = userCollateralBalance[_borrower];
        if (_collateralAmount == 0) return false;

        uint256 _ltv = (((_borrowerAmount * _exchangeRate) / EXCHANGE_PRECISION) * LTV_PRECISION) / _collateralAmount;
        return _ltv <= maxLTV;
    }

    /// @notice The ```_isPastMaturity``` function determines if the current block timestamp is past the maturityDate date
    /// @return Whether or not the debt is past maturity
    function _isPastMaturity() internal view returns (bool) {
        return maturityDate != 0 && block.timestamp > maturityDate;
    }

    // ============================================================================================
    // Modifiers
    // ============================================================================================

    /// @notice Checks for solvency AFTER executing contract code
    /// @param _borrower The borrower whose solvency we will check
    modifier isSolvent(address _borrower) {
        _;
        if (!_isSolvent(_borrower, exchangeRateInfo.exchangeRate)) {
            revert Insolvent(
                totalBorrow.toAmount(userBorrowShares[_borrower], true),
                userCollateralBalance[_borrower],
                exchangeRateInfo.exchangeRate
            );
        }
    }

    /// @notice Checks if msg.sender is an approved Borrower
    modifier approvedBorrower() {
        if (borrowerWhitelistActive && !approvedBorrowers[msg.sender]) {
            revert OnlyApprovedBorrowers();
        }
        _;
    }

    /// @notice Checks if msg.sender and _receiver are both an approved Lender
    /// @param _receiver An additional receiver address to check
    modifier approvedLender(address _receiver) {
        if (lenderWhitelistActive && (!approvedLenders[msg.sender] || !approvedLenders[_receiver])) {
            revert OnlyApprovedLenders();
        }
        _;
    }

    /// @notice Ensure function is not called when passed maturity
    modifier isNotPastMaturity() {
        if (_isPastMaturity()) {
            revert PastMaturity();
        }
        _;
    }

    // ============================================================================================
    // Functions: Interest Accumulation and Adjustment
    // ============================================================================================

    /// @notice The ```AddInterest``` event is emitted when interest is accrued by borrowers
    /// @param _interestEarned The total interest accrued by all borrowers
    /// @param _rate The interest rate used to calculate accrued interest
    /// @param _deltaTime The time elapsed since last interest accrual
    /// @param _feesAmount The amount of fees paid to protocol
    /// @param _feesShare The amount of shares distributed to protocol
    event AddInterest(
        uint256 _interestEarned,
        uint256 _rate,
        uint256 _deltaTime,
        uint256 _feesAmount,
        uint256 _feesShare
    );

    /// @notice The ```UpdateRate``` event is emitted when the interest rate is updated
    /// @param _ratePerSec The old interest rate (per second)
    /// @param _deltaTime The time elapsed since last update
    /// @param _utilizationRate The utilization of assets in the Pair
    /// @param _newRatePerSec The new interest rate (per second)
    event UpdateRate(uint256 _ratePerSec, uint256 _deltaTime, uint256 _utilizationRate, uint256 _newRatePerSec);

    /// @notice The ```addInterest``` function is a public implementation of _addInterest and allows 3rd parties to trigger interest accrual
    /// @return _interestEarned The amount of interest accrued by all borrowers
    function addInterest()
        external
        nonReentrant
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        return _addInterest();
    }

    /// @notice The ```_addInterest``` function is invoked prior to every external function and is used to accrue interest and update interest rate
    /// @dev Can only called once per block
    /// @return _interestEarned The amount of interest accrued by all borrowers
    function _addInterest()
        internal
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        // Add interest only once per block
        CurrentRateInfo memory _currentRateInfo = currentRateInfo;
        if (_currentRateInfo.lastTimestamp == block.timestamp) {
            _newRate = _currentRateInfo.ratePerSec;
            return (_interestEarned, _feesAmount, _feesShare, _newRate);
        }

        // Pull some data from storage to save gas
        VaultAccount memory _totalAsset = totalAsset;
        VaultAccount memory _totalBorrow = totalBorrow;

        // If there are no borrows or contract is paused, no interest accrues and we reset interest rate
        if (_totalBorrow.shares == 0 || paused()) {
            if (!paused()) {
                _currentRateInfo.ratePerSec = DEFAULT_INT;
            }
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Effects: write to storage
            currentRateInfo = _currentRateInfo;
        } else {
            // We know totalBorrow.shares > 0
            uint256 _deltaTime = block.timestamp - _currentRateInfo.lastTimestamp;

            // NOTE: Violates Checks-Effects-Interactions pattern
            // Be sure to mark external version NONREENTRANT (even though rateContract is trusted)
            // Calc new rate
            uint256 _utilizationRate = (UTIL_PREC * _totalBorrow.amount) / _totalAsset.amount;
            if (_isPastMaturity()) {
                _newRate = uint64(penaltyRate);
            } else {
                bytes memory _rateData = abi.encode(
                    _currentRateInfo.ratePerSec,
                    _deltaTime,
                    _utilizationRate,
                    block.number - _currentRateInfo.lastBlock
                );
                _newRate = IRateCalculator(rateContract).getNewRate(_rateData, rateInitCallData);
            }

            // Event must be here to use non-mutated values
            emit UpdateRate(_currentRateInfo.ratePerSec, _deltaTime, _utilizationRate, _newRate);

            // Effects: bookkeeping
            _currentRateInfo.ratePerSec = _newRate;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Calculate interest accrued
            _interestEarned = (_deltaTime * _totalBorrow.amount * _currentRateInfo.ratePerSec) / 1e18;

            // Accumulate interest and fees, only if no overflow upon casting
            if (
                _interestEarned + _totalBorrow.amount <= type(uint128).max &&
                _interestEarned + _totalAsset.amount <= type(uint128).max
            ) {
                _totalBorrow.amount += uint128(_interestEarned);
                _totalAsset.amount += uint128(_interestEarned);
                if (_currentRateInfo.feeToProtocolRate > 0) {
                    _feesAmount = (_interestEarned * _currentRateInfo.feeToProtocolRate) / FEE_PRECISION;

                    _feesShare = (_feesAmount * _totalAsset.shares) / (_totalAsset.amount - _feesAmount);

                    // Effects: Give new shares to this contract, effectively diluting lenders an amount equal to the fees
                    // We can safely cast because _feesShare < _feesAmount < interestEarned which is always less than uint128
                    _totalAsset.shares += uint128(_feesShare);

                    // Effects: write to storage
                    _mint(address(this), _feesShare);
                }
                emit AddInterest(_interestEarned, _currentRateInfo.ratePerSec, _deltaTime, _feesAmount, _feesShare);
            }

            // Effects: write to storage
            totalAsset = _totalAsset;
            currentRateInfo = _currentRateInfo;
            totalBorrow = _totalBorrow;
        }
    }

    // ============================================================================================
    // Functions: ExchangeRate
    // ============================================================================================
    /// @notice The ```UpdateExchangeRate``` event is emitted when the Collateral:Asset exchange rate is updated
    /// @param _rate The new rate given as the amount of Collateral Token to buy 1e18 Asset Token
    event UpdateExchangeRate(uint256 _rate);

    /// @notice The ```updateExchangeRate``` function is the external implementation of _updateExchangeRate.
    /// @dev This function is invoked at most once per block as these queries can be expensive
    /// @return _exchangeRate The new exchange rate
    function updateExchangeRate() external nonReentrant returns (uint256 _exchangeRate) {
        _exchangeRate = _updateExchangeRate();
    }

    /// @notice The ```_updateExchangeRate``` function retrieves the latest exchange rate. i.e how much collateral to buy 1e18 asset.
    /// @dev This function is invoked at most once per block as these queries can be expensive
    /// @return _exchangeRate The new exchange rate
    function _updateExchangeRate() internal returns (uint256 _exchangeRate) {
        ExchangeRateInfo memory _exchangeRateInfo = exchangeRateInfo;
        if (_exchangeRateInfo.lastTimestamp == block.timestamp) {
            return _exchangeRate = _exchangeRateInfo.exchangeRate;
        }

        uint256 _price = uint256(1e36);
        if (oracleMultiply != address(0)) {
            (, int256 _answer, , , ) = AggregatorV3Interface(oracleMultiply).latestRoundData();
            if (_answer <= 0) {
                revert OracleLTEZero(oracleMultiply);
            }
            _price = _price * uint256(_answer);
        }

        if (oracleDivide != address(0)) {
            (, int256 _answer, , , ) = AggregatorV3Interface(oracleDivide).latestRoundData();
            if (_answer <= 0) {
                revert OracleLTEZero(oracleDivide);
            }
            _price = _price / uint256(_answer);
        }

        _exchangeRate = _price / oracleNormalization;

        // write to storage, if no overflow
        if (_exchangeRate > type(uint224).max) revert PriceTooLarge();
        _exchangeRateInfo.exchangeRate = uint224(_exchangeRate);
        _exchangeRateInfo.lastTimestamp = uint32(block.timestamp);
        exchangeRateInfo = _exchangeRateInfo;
        emit UpdateExchangeRate(_exchangeRate);
    }

    // ============================================================================================
    // Functions: Lending
    // ============================================================================================

    /// @notice The ```_deposit``` function is the internal implementation for lending assets
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling function
    /// @param _totalAsset An in memory VaultAccount struct representing the total amounts and shares for the Asset Token
    /// @param _amount The amount of Asset Token to be transferred
    /// @param _shares The amount of Asset Shares (fTokens) to be minted
    /// @param _receiver The address to receive the Asset Shares (fTokens)
    function _deposit(
        VaultAccount memory _totalAsset,
        uint128 _amount,
        uint128 _shares,
        address _receiver
    ) internal {
        // Effects: bookkeeping
        _totalAsset.amount += _amount;
        _totalAsset.shares += _shares;

        // Effects: write back to storage
        _mint(_receiver, _shares);
        totalAsset = _totalAsset;

        // Interactions
        assetContract.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _receiver, _amount, _shares);
    }

    /// @notice The ```deposit``` function allows a user to Lend Assets by specifying the amount of Asset Tokens to lend
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling function
    /// @param _amount The amount of Asset Token to transfer to Pair
    /// @param _receiver The address to receive the Asset Shares (fTokens)
    /// @return _sharesReceived The number of fTokens received for the deposit
    function deposit(uint256 _amount, address _receiver)
        external
        nonReentrant
        isNotPastMaturity
        whenNotPaused
        approvedLender(_receiver)
        returns (uint256 _sharesReceived)
    {
        _addInterest();
        VaultAccount memory _totalAsset = totalAsset;
        _sharesReceived = _totalAsset.toShares(_amount, false);
        _deposit(_totalAsset, _amount.toUint128(), _sharesReceived.toUint128(), _receiver);
    }

    /// @notice The ```mint``` function allows a user to Lend assets by specifying the number of Assets Shares (fTokens) to mint
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling function
    /// @param _shares The number of Asset Shares (fTokens) that a user wants to mint
    /// @param _receiver The address to receive the Asset Shares (fTokens)
    /// @return _amountReceived The amount of Asset Tokens transferred to the Pair
    function mint(uint256 _shares, address _receiver)
        external
        nonReentrant
        isNotPastMaturity
        whenNotPaused
        approvedLender(_receiver)
        returns (uint256 _amountReceived)
    {
        _addInterest();
        VaultAccount memory _totalAsset = totalAsset;
        _amountReceived = _totalAsset.toAmount(_shares, true);
        _deposit(_totalAsset, _amountReceived.toUint128(), _shares.toUint128(), _receiver);
    }

    /// @notice The ```_redeem``` function is an internal implementation which allows a Lender to pull their Asset Tokens out of the Pair
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling function
    /// @param _totalAsset An in-memory VaultAccount struct which holds the total amount of Asset Tokens and the total number of Asset Shares (fTokens)
    /// @param _amountToReturn The number of Asset Tokens to return
    /// @param _shares The number of Asset Shares (fTokens) to burn
    /// @param _receiver The address to which the Asset Tokens will be transferred
    /// @param _owner The owner of the Asset Shares (fTokens)
    function _redeem(
        VaultAccount memory _totalAsset,
        uint128 _amountToReturn,
        uint128 _shares,
        address _receiver,
        address _owner
    ) internal {
        if (msg.sender != _owner) {
            uint256 allowed = allowance(_owner, msg.sender);
            // NOTE: This will revert on underflow ensuring that allowance > shares
            if (allowed != type(uint256).max) _approve(_owner, msg.sender, allowed - _shares);
        }

        // Check for sufficient withdraw liquidity
        uint256 _assetsAvailable = _totalAssetAvailable(_totalAsset, totalBorrow);
        if (_assetsAvailable < _amountToReturn) {
            revert InsufficientAssetsInContract(_assetsAvailable, _amountToReturn);
        }

        // Effects: bookkeeping
        _totalAsset.amount -= _amountToReturn;
        _totalAsset.shares -= _shares;

        // Effects: write to storage
        totalAsset = _totalAsset;
        _burn(_owner, _shares);

        // Interactions
        assetContract.safeTransfer(_receiver, _amountToReturn);
        emit Withdraw(msg.sender, _receiver, _owner, _amountToReturn, _shares);
    }

    /// @notice The ```redeem``` function allows the caller to redeem their Asset Shares for Asset Tokens
    /// @param _shares The number of Asset Shares (fTokens) to burn for Asset Tokens
    /// @param _receiver The address to which the Asset Tokens will be transferred
    /// @param _owner The owner of the Asset Shares (fTokens)
    /// @return _amountToReturn The amount of Asset Tokens to be transferred
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) external nonReentrant returns (uint256 _amountToReturn) {
        _addInterest();
        VaultAccount memory _totalAsset = totalAsset;
        _amountToReturn = _totalAsset.toAmount(_shares, false);
        _redeem(_totalAsset, _amountToReturn.toUint128(), _shares.toUint128(), _receiver, _owner);
    }

    /// @notice The ```withdraw``` function allows a user to redeem their Asset Shares for a specified amount of Asset Tokens
    /// @param _amount The amount of Asset Tokens to be transferred in exchange for burning Asset Shares
    /// @param _receiver The address to which the Asset Tokens will be transferred
    /// @param _owner The owner of the Asset Shares (fTokens)
    /// @return _shares The number of Asset Shares (fTokens) burned
    function withdraw(
        uint256 _amount,
        address _receiver,
        address _owner
    ) external nonReentrant returns (uint256 _shares) {
        _addInterest();
        VaultAccount memory _totalAsset = totalAsset;
        _shares = _totalAsset.toShares(_amount, true);
        _redeem(_totalAsset, _amount.toUint128(), _shares.toUint128(), _receiver, _owner);
    }

    // ============================================================================================
    // Functions: Borrowing
    // ============================================================================================

    /// @notice The ```BorrowAsset``` event is emitted when a borrower increases their position
    /// @param _borrower The borrower whose account was debited
    /// @param _receiver The address to which the Asset Tokens were transferred
    /// @param _borrowAmount The amount of Asset Tokens transferred
    /// @param _sharesAdded The number of Borrow Shares the borrower was debited
    event BorrowAsset(
        address indexed _borrower,
        address indexed _receiver,
        uint256 _borrowAmount,
        uint256 _sharesAdded
    );

    /// @notice The ```_borrowAsset``` function is the internal implementation for borrowing assets
    /// @param _borrowAmount The amount of the Asset Token to borrow
    /// @param _receiver The address to receive the Asset Tokens
    /// @return _sharesAdded The amount of borrow shares the msg.sender will be debited
    function _borrowAsset(uint128 _borrowAmount, address _receiver) internal returns (uint256 _sharesAdded) {
        VaultAccount memory _totalBorrow = totalBorrow;

        // Check available capital
        uint256 _assetsAvailable = _totalAssetAvailable(totalAsset, _totalBorrow);
        if (_assetsAvailable < _borrowAmount) {
            revert InsufficientAssetsInContract(_assetsAvailable, _borrowAmount);
        }

        // Effects: Bookkeeping to add shares & amounts to total Borrow accounting
        _sharesAdded = _totalBorrow.toShares(_borrowAmount, true);
        _totalBorrow.amount += _borrowAmount;
        _totalBorrow.shares += uint128(_sharesAdded);
        // NOTE: we can safely cast here because shares are always less than amount and _borrowAmount is uint128

        // Effects: write back to storage
        totalBorrow = _totalBorrow;
        userBorrowShares[msg.sender] += _sharesAdded;

        // Interactions
        if (_receiver != address(this)) {
            assetContract.safeTransfer(_receiver, _borrowAmount);
        }
        emit BorrowAsset(msg.sender, _receiver, _borrowAmount, _sharesAdded);
    }

    /// @notice The ```borrowAsset``` function allows a user to open/increase a borrow position
    /// @dev Borrower must call ```ERC20.approve``` on the Collateral Token contract if applicable
    /// @param _borrowAmount The amount of Asset Token to borrow
    /// @param _collateralAmount The amount of Collateral Token to transfer to Pair
    /// @param _receiver The address which will receive the Asset Tokens
    /// @return _shares The number of borrow Shares the msg.sender will be debited
    function borrowAsset(
        uint256 _borrowAmount,
        uint256 _collateralAmount,
        address _receiver
    )
        external
        isNotPastMaturity
        whenNotPaused
        nonReentrant
        isSolvent(msg.sender)
        approvedBorrower
        returns (uint256 _shares)
    {
        _addInterest();
        _updateExchangeRate();
        if (_collateralAmount > 0) {
            _addCollateral(msg.sender, _collateralAmount, msg.sender);
        }
        _shares = _borrowAsset(_borrowAmount.toUint128(), _receiver);
    }

    event AddCollateral(address indexed _sender, address indexed _borrower, uint256 _collateralAmount);

    /// @notice The ```_addCollateral``` function is an internal implementation for adding collateral to a borrowers position
    /// @param _sender The source of funds for the new collateral
    /// @param _collateralAmount The amount of Collateral Token to be transferred
    /// @param _borrower The borrower account for which the collateral should be credited
    function _addCollateral(
        address _sender,
        uint256 _collateralAmount,
        address _borrower
    ) internal {
        // Effects: write to state
        userCollateralBalance[_borrower] += _collateralAmount;
        totalCollateral += _collateralAmount;

        // Interactions
        if (_sender != address(this)) {
            collateralContract.safeTransferFrom(_sender, address(this), _collateralAmount);
        }
        emit AddCollateral(_sender, _borrower, _collateralAmount);
    }

    /// @notice The ```addCollateral``` function allows the caller to add Collateral Token to a borrowers position
    /// @dev msg.sender must call ERC20.approve() on the Collateral Token contract prior to invocation
    /// @param _collateralAmount The amount of Collateral Token to be added to borrower's position
    /// @param _borrower The account to be credited
    function addCollateral(uint256 _collateralAmount, address _borrower) external nonReentrant isNotPastMaturity {
        _addInterest();
        _addCollateral(msg.sender, _collateralAmount, _borrower);
    }

    /// @notice The ```RemoveCollateral``` event is emitted when collateral is removed from a borrower's position
    /// @param _sender The account from which funds are transferred
    /// @param _collateralAmount The amount of Collateral Token to be transferred
    /// @param _receiver The address to which Collateral Tokens will be transferred
    event RemoveCollateral(
        address indexed _sender,
        uint256 _collateralAmount,
        address indexed _receiver,
        address indexed _borrower
    );

    /// @notice The ```_removeCollateral``` function is the internal implementation for removing collateral from a borrower's position
    /// @param _collateralAmount The amount of Collateral Token to remove from the borrower's position
    /// @param _receiver The address to receive the Collateral Token transferred
    /// @param _borrower The borrower whose account will be debited the Collateral amount
    function _removeCollateral(
        uint256 _collateralAmount,
        address _receiver,
        address _borrower
    ) internal {
        // Effects: write to state
        // Following line will revert on underflow if _collateralAmount > userCollateralBalance
        userCollateralBalance[_borrower] -= _collateralAmount;
        // Following line will revert on underflow if totalCollateral < _collateralAmount
        totalCollateral -= _collateralAmount;

        // Interactions
        if (_receiver != address(this)) {
            collateralContract.safeTransfer(_receiver, _collateralAmount);
        }
        emit RemoveCollateral(msg.sender, _collateralAmount, _receiver, _borrower);
    }

    /// @notice The ```removeCollateral``` function is used to remove collateral from msg.sender's borrow position
    /// @dev msg.sender must be solvent after invocation or transaction will revert
    /// @param _collateralAmount The amount of Collateral Token to transfer
    /// @param _receiver The address to receive the transferred funds
    function removeCollateral(uint256 _collateralAmount, address _receiver)
        external
        nonReentrant
        isSolvent(msg.sender)
    {
        _addInterest();
        // Note: exchange rate is irrelevant when borrower has no debt shares
        if (userBorrowShares[msg.sender] > 0) {
            _updateExchangeRate();
        }
        _removeCollateral(_collateralAmount, _receiver, msg.sender);
    }

    /// @notice The ```RepayAsset``` event is emitted whenever a debt position is repaid
    /// @param _sender The msg.sender of the transaction
    /// @param _borrower The borrower whose account will be credited
    /// @param _amountToRepay The amount of Asset token to be transferred
    /// @param _shares The amount of Borrow Shares which will be debited from the borrower after repayment
    event RepayAsset(address indexed _sender, address indexed _borrower, uint256 _amountToRepay, uint256 _shares);

    /// @notice The ```_repayAsset``` function is the internal implementation for repaying a borrow position
    /// @dev The payer must have called ERC20.approve() on the Asset Token contract prior to invocation
    /// @param _totalBorrow An in memory copy of the totalBorrow VaultAccount struct
    /// @param _amountToRepay The amount of Asset Token to transfer
    /// @param _shares The number of Borrow Shares the sender is repaying
    /// @param _payer The address from which funds will be transferred
    /// @param _borrower The borrower account which will be credited
    function _repayAsset(
        VaultAccount memory _totalBorrow,
        uint128 _amountToRepay,
        uint128 _shares,
        address _payer,
        address _borrower
    ) internal {
        // Effects: Bookkeeping
        _totalBorrow.amount -= _amountToRepay;
        _totalBorrow.shares -= _shares;

        // Effects: write to state
        userBorrowShares[_borrower] -= _shares;
        totalBorrow = _totalBorrow;

        // Interactions
        if (_payer != address(this)) {
            assetContract.safeTransferFrom(_payer, address(this), _amountToRepay);
        }
        emit RepayAsset(msg.sender, _borrower, _amountToRepay, _shares);
    }

    /// @notice The ```repayAsset``` function allows the caller to pay down the debt for a given borrower.
    /// @dev Caller must first invoke ```ERC20.approve()``` for the Asset Token contract
    /// @param _shares The number of Borrow Shares which will be repaid by the call
    /// @param _borrower The account for which the debt will be reduced
    /// @return _amountToRepay The amount of Asset Tokens which were transferred in order to repay the Borrow Shares
    function repayAsset(uint256 _shares, address _borrower) external nonReentrant returns (uint256 _amountToRepay) {
        _addInterest();
        VaultAccount memory _totalBorrow = totalBorrow;
        _amountToRepay = _totalBorrow.toAmount(_shares, true);
        _repayAsset(_totalBorrow, _amountToRepay.toUint128(), _shares.toUint128(), msg.sender, _borrower);
    }

    // ============================================================================================
    // Functions: Liquidations
    // ============================================================================================
    /// @notice The ```Liquidate``` event is emitted when a liquidation occurs
    /// @param _borrower The borrower account for which the liquidation occured
    /// @param _collateralForLiquidator The amount of Collateral Token transferred to the liquidator
    /// @param _sharesToLiquidate The number of Borrow Shares the liquidator repaid on behalf of the borrower
    /// @param _sharesToAdjust The number of Borrow Shares that were adjusted on liabilites and assets (a writeoff)
    event Liquidate(
        address indexed _borrower,
        uint256 _collateralForLiquidator,
        uint256 _sharesToLiquidate,
        uint256 _amountLiquidatorToRepay,
        uint256 _sharesToAdjust,
        uint256 _amountToAdjust
    );

    /// @notice The ```liquidate``` function allows a third party to repay a borrower's debt if they have become insolvent
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling ```Liquidate()```
    /// @param _shares The number of Borrow Shares repaid by the liquidator
    /// @param _borrower The account for which the repayment is credited and from whom collateral will be taken
    /// @return _collateralForLiquidator The amount of Collateral Token transferred to the liquidator
    function liquidate(uint256 _shares, address _borrower)
        external
        whenNotPaused
        nonReentrant
        approvedLender(msg.sender)
        returns (uint256 _collateralForLiquidator)
    {
        _addInterest();

        // Get best available exchange rate
        uint256 _exchangeRate = _updateExchangeRate();
        if (_isSolvent(_borrower, _exchangeRate)) {
            revert BorrowerSolvent();
        }

        VaultAccount memory _totalBorrow = totalBorrow;

        // Determine how much of the borrow and collateral will be repaid
        _collateralForLiquidator =
            (((_totalBorrow.toAmount(_shares, false) * _exchangeRate) / EXCHANGE_PRECISION) *
                (LIQ_PRECISION + cleanLiquidationFee)) /
            LIQ_PRECISION;

        // Effects & Interactions
        // NOTE: reverts if _shares > userBorrowShares
        uint256 _amountToRepay = _totalBorrow.toAmount(_shares, true);
        _repayAsset(_totalBorrow, _amountToRepay.toUint128(), _shares.toUint128(), msg.sender, _borrower); // liquidator repays shares on behalf of borrower
        // NOTE: reverts if _collateralForLiquidator > userCollateralBalance
        // Collateral is removed on behalf of borrower and sent to liquidator
        _removeCollateral(_collateralForLiquidator, msg.sender, _borrower);
        emit Liquidate(_borrower, _collateralForLiquidator, _shares, 0, 0, 0);
    }

    /// @notice The ```liquidateClean``` function allows a third party to repay a borrower's debt if they have become insolvent
    /// @dev Caller must invoke ```ERC20.approve``` on the Asset Token contract prior to calling ```Liquidate()```
    /// @param _sharesToLiquidate The number of Borrow Shares repaid by the liquidator
    /// @param _deadline The timestamp after which tx will revert
    /// @param _borrower The account for which the repayment is credited and from whom collateral will be taken
    /// @return _collateralForLiquidator The amount of Collateral Token transferred to the liquidator
    function liquidateClean(
        uint128 _sharesToLiquidate,
        uint256 _deadline,
        address _borrower
    ) external whenNotPaused nonReentrant approvedLender(msg.sender) returns (uint256 _collateralForLiquidator) {
        if (block.timestamp > _deadline) revert PastDeadline(block.timestamp, _deadline);

        _addInterest();
        uint256 _exchangeRate = _updateExchangeRate();

        if (_isSolvent(_borrower, _exchangeRate)) {
            revert BorrowerSolvent();
        }

        // Read from state
        VaultAccount memory _totalBorrow = totalBorrow;
        uint256 _userCollateralBalance = userCollateralBalance[_borrower];
        uint128 _borrowerShares = userBorrowShares[_borrower].toUint128();

        // Prevent stack-too-deep
        int256 _leftoverCollateral;
        {
            // Checks & Calculations
            // Determine the liquidation amount in collateral units (i.e. how much debt is liquidator going to repay)
            uint256 _liquidationAmountInCollateralUnits = ((_totalBorrow.toAmount(_sharesToLiquidate, false) *
                _exchangeRate) / EXCHANGE_PRECISION);

            // We first optimistically calculate the amount of collateral to give the liquidator based on the higher clean liquidation fee
            // This fee only applies if the liquidator does a full liquidation
            uint256 _optimisticCollateralForLiquidator = (_liquidationAmountInCollateralUnits *
                (LIQ_PRECISION + cleanLiquidationFee)) / LIQ_PRECISION;

            // Because interest accrues every block, _liquidationAmountInCollateralUnits from a few lines up is an ever increasing value
            // This means that leftoverCollateral can occasionally go negative by a few hundred wei (cleanLiqFee premium covers this for liquidator)
            _leftoverCollateral = (_userCollateralBalance.toInt256() - _optimisticCollateralForLiquidator.toInt256());

            // If cleanLiquidation fee results in no leftover collateral, give liquidator all the collateral
            // This will only be true when there liquidator is cleaning out the position
            _collateralForLiquidator = _leftoverCollateral <= 0
                ? _userCollateralBalance
                : (_liquidationAmountInCollateralUnits * (LIQ_PRECISION + dirtyLiquidationFee)) / LIQ_PRECISION;
        }
        // Calced here for use during repayment, grouped with other calcs before effects start
        uint128 _amountLiquidatorToRepay = (_totalBorrow.toAmount(_sharesToLiquidate, true)).toUint128();

        // Determine if and how much debt to writeoff
        // Note: ensures that sharesToLiquidate is never larger than borrowerShares
        uint128 _sharesToAdjust;
        uint128 _amountToAdjust;
        {
            if (_leftoverCollateral <= 0) {
                uint128 _leftoverBorrowShares = _borrowerShares - _sharesToLiquidate;
                if (_leftoverBorrowShares > 0) {
                    // Write off bad debt
                    _sharesToAdjust = _leftoverBorrowShares;
                    _amountToAdjust = (_totalBorrow.toAmount(_sharesToAdjust, false)).toUint128();

                    // Effects: write to state
                    totalAsset.amount -= _amountToAdjust;

                    // Note: Ensure this memory stuct will be passed to _repayAsset for write to state
                    _totalBorrow.amount -= _amountToAdjust;
                    _totalBorrow.shares -= _sharesToAdjust;
                }
            }
        }

        // Effects & Interactions
        // NOTE: reverts if _shares > userBorrowShares
        _repayAsset(_totalBorrow, _amountLiquidatorToRepay, _sharesToLiquidate, msg.sender, _borrower); // liquidator repays shares on behalf of borrower
        // NOTE: reverts if _collateralForLiquidator > userCollateralBalance
        // Collateral is removed on behalf of borrower and sent to liquidator
        // NOTE: reverts if _collateralForLiquidator > userCollateralBalance
        _removeCollateral(_collateralForLiquidator, msg.sender, _borrower);
        emit Liquidate(
            _borrower,
            _collateralForLiquidator,
            _sharesToLiquidate,
            _amountLiquidatorToRepay,
            _sharesToAdjust,
            _amountToAdjust
        );
    }

    // ============================================================================================
    // Functions: Leverage
    // ============================================================================================

    /// @notice The ```LeveragedPosition``` event is emitted when a borrower takes out a new leveraged position
    /// @param _borrower The account for which the debt is debited
    /// @param _swapperAddress The address of the swapper which conforms the FraxSwap interface
    /// @param _borrowAmount The amount of Asset Token to be borrowed to be borrowed
    /// @param _borrowShares The number of Borrow Shares the borrower is credited
    /// @param _initialCollateralAmount The amount of initial Collateral Tokens supplied by the borrower
    /// @param _amountCollateralOut The amount of Collateral Token which was received for the Asset Tokens
    event LeveragedPosition(
        address indexed _borrower,
        address _swapperAddress,
        uint256 _borrowAmount,
        uint256 _borrowShares,
        uint256 _initialCollateralAmount,
        uint256 _amountCollateralOut
    );

    /// @notice The ```leveragedPosition``` function allows a user to enter a leveraged borrow position with minimal upfront Collateral
    /// @dev Caller must invoke ```ERC20.approve()``` on the Collateral Token contract prior to calling function
    /// @param _swapperAddress The address of the whitelisted swapper to use to swap borrowed Asset Tokens for Collateral Tokens
    /// @param _borrowAmount The amount of Asset Tokens borrowed
    /// @param _initialCollateralAmount The initial amount of Collateral Tokens supplied by the borrower
    /// @param _amountCollateralOutMin The minimum amount of Collateral Tokens to be received in exchange for the borrowed Asset Tokens
    /// @param _path An array containing the addresses of ERC20 tokens to swap.  Adheres to UniV2 style path params.
    /// @return _totalCollateralBalance The total amount of Collateral Tokens added to a users account (initial + swap)
    function leveragedPosition(
        address _swapperAddress,
        uint256 _borrowAmount,
        uint256 _initialCollateralAmount,
        uint256 _amountCollateralOutMin,
        address[] memory _path
    )
        external
        isNotPastMaturity
        nonReentrant
        whenNotPaused
        approvedBorrower
        isSolvent(msg.sender)
        returns (uint256 _totalCollateralBalance)
    {
        _addInterest();
        _updateExchangeRate();

        IERC20 _assetContract = assetContract;
        IERC20 _collateralContract = collateralContract;

        if (!swappers[_swapperAddress]) {
            revert BadSwapper();
        }
        if (_path[0] != address(_assetContract)) {
            revert InvalidPath(address(_assetContract), _path[0]);
        }
        if (_path[_path.length - 1] != address(_collateralContract)) {
            revert InvalidPath(address(_collateralContract), _path[_path.length - 1]);
        }

        // Add initial collateral
        if (_initialCollateralAmount > 0) {
            _addCollateral(msg.sender, _initialCollateralAmount, msg.sender);
        }

        // Debit borrowers account
        // setting recipient to address(this) means no transfer will happen
        uint256 _borrowShares = _borrowAsset(_borrowAmount.toUint128(), address(this));

        // Interactions
        _assetContract.approve(_swapperAddress, _borrowAmount);

        // Even though swappers are trusted, we verify the balance before and after swap
        uint256 _initialCollateralBalance = _collateralContract.balanceOf(address(this));
        ISwapper(_swapperAddress).swapExactTokensForTokens(
            _borrowAmount,
            _amountCollateralOutMin,
            _path,
            address(this),
            block.timestamp
        );
        uint256 _finalCollateralBalance = _collateralContract.balanceOf(address(this));

        // Note: VIOLATES CHECKS-EFFECTS-INTERACTION pattern, make sure function is NONREENTRANT
        // Effects: bookkeeping & write to state
        uint256 _amountCollateralOut = _finalCollateralBalance - _initialCollateralBalance;
        if (_amountCollateralOut < _amountCollateralOutMin) {
            revert SlippageTooHigh(_amountCollateralOutMin, _amountCollateralOut);
        }

        // address(this) as _sender means no transfer occurs as the pair has already received the collateral during swap
        _addCollateral(address(this), _amountCollateralOut, msg.sender);

        _totalCollateralBalance = _initialCollateralAmount + _amountCollateralOut;
        emit LeveragedPosition(
            msg.sender,
            _swapperAddress,
            _borrowAmount,
            _borrowShares,
            _initialCollateralAmount,
            _amountCollateralOut
        );
    }

    /// @notice The ```RepayAssetWithCollateral``` event is emitted whenever ```repayAssetWithCollateral()``` is invoked
    /// @param _borrower The borrower account for which the repayment is taking place
    /// @param _swapperAddress The address of the whitelisted swapper to use for token swaps
    /// @param _collateralToSwap The amount of Collateral Token to swap and use for repayment
    /// @param _amountAssetOut The amount of Asset Token which was repaid
    /// @param _sharesRepaid The number of Borrow Shares which were repaid
    event RepayAssetWithCollateral(
        address indexed _borrower,
        address _swapperAddress,
        uint256 _collateralToSwap,
        uint256 _amountAssetOut,
        uint256 _sharesRepaid
    );

    /// @notice The ```repayAssetWithCollateral``` function allows a borrower to repay their debt using existing collateral in contract
    /// @param _swapperAddress The address of the whitelisted swapper to use for token swaps
    /// @param _collateralToSwap The amount of Collateral Tokens to swap for Asset Tokens
    /// @param _amountAssetOutMin The minimum amount of Asset Tokens to receive during the swap
    /// @param _path An array containing the addresses of ERC20 tokens to swap.  Adheres to UniV2 style path params.
    /// @return _amountAssetOut The amount of Asset Tokens received for the Collateral Tokens, the amount the borrowers account was credited
    function repayAssetWithCollateral(
        address _swapperAddress,
        uint256 _collateralToSwap,
        uint256 _amountAssetOutMin,
        address[] calldata _path
    ) external nonReentrant isSolvent(msg.sender) returns (uint256 _amountAssetOut) {
        _addInterest();
        _updateExchangeRate();

        IERC20 _assetContract = assetContract;
        IERC20 _collateralContract = collateralContract;

        if (!swappers[_swapperAddress]) {
            revert BadSwapper();
        }
        if (_path[0] != address(_collateralContract)) {
            revert InvalidPath(address(_collateralContract), _path[0]);
        }
        if (_path[_path.length - 1] != address(_assetContract)) {
            revert InvalidPath(address(_assetContract), _path[_path.length - 1]);
        }

        // Effects: bookkeeping & write to state
        // Debit users collateral balance in preparation for swap, setting _recipient to address(this) means no transfer occurs
        _removeCollateral(_collateralToSwap, address(this), msg.sender);

        // Interactions
        _collateralContract.approve(_swapperAddress, _collateralToSwap);

        // Even though swappers are trusted, we verify the balance before and after swap
        uint256 _initialAssetBalance = _assetContract.balanceOf(address(this));
        ISwapper(_swapperAddress).swapExactTokensForTokens(
            _collateralToSwap,
            _amountAssetOutMin,
            _path,
            address(this),
            block.timestamp
        );
        uint256 _finalAssetBalance = _assetContract.balanceOf(address(this));

        // Note: VIOLATES CHECKS-EFFECTS-INTERACTION pattern, make sure function is NONREENTRANT
        // Effects: bookkeeping
        _amountAssetOut = _finalAssetBalance - _initialAssetBalance;
        if (_amountAssetOut < _amountAssetOutMin) {
            revert SlippageTooHigh(_amountAssetOutMin, _amountAssetOut);
        }

        VaultAccount memory _totalBorrow = totalBorrow;
        uint256 _sharesToRepay = _totalBorrow.toShares(_amountAssetOut, false);

        // Effects: write to state
        // Note: setting _payer to address(this) means no actual transfer will occur.  Contract already has funds
        _repayAsset(_totalBorrow, _amountAssetOut.toUint128(), _sharesToRepay.toUint128(), address(this), msg.sender);

        emit RepayAssetWithCollateral(msg.sender, _swapperAddress, _collateralToSwap, _amountAssetOut, _sharesToRepay);
    }
}
