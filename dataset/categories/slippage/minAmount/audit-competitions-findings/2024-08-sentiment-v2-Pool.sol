// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                                Pool
//////////////////////////////////////////////////////////////*/

// types
import { Registry } from "./Registry.sol";
import { RiskEngine } from "./RiskEngine.sol";
import { IOracle } from "./interfaces/IOracle.sol";
import { IRateModel } from "./interfaces/IRateModel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// libraries
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// contracts
import { ERC6909 } from "./lib/ERC6909.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Pool
/// @notice Singleton pool for all pools that superpools lend to and positions borrow from
contract Pool is OwnableUpgradeable, ERC6909 {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Timelock delay for pool rate model modification
    uint256 public constant TIMELOCK_DURATION = 24 * 60 * 60; // 24 hours
    /// @notice Timelock deadline to enforce timely updates
    uint256 public constant TIMELOCK_DEADLINE = 3 * 24 * 60 * 60; // 72 hours
    /// @notice Registry key hash for the Sentiment position manager
    /// @dev keccak(SENTIMENT_POSITION_MANAGER_KEY)
    bytes32 public constant SENTIMENT_POSITION_MANAGER_KEY =
        0xd4927490fbcbcafca716cca8e8c8b7d19cda785679d224b14f15ce2a9a93e148;
    /// @notice Sentiment risk engine registry key
    /// @dev keccak(SENTIMENT_RISK_ENGINE_KEY)
    bytes32 public constant SENTIMENT_RISK_ENGINE_KEY =
        0x5b6696788621a5d6b5e3b02a69896b9dd824ebf1631584f038a393c29b6d7555;

    /// @notice Initial interest fee for pools
    uint128 public defaultInterestFee;
    /// @notice Initial origination fee for pools
    uint128 public defaultOriginationFee;

    /// @notice Sentiment registry
    address public registry;
    /// @notice Sentiment fee receiver
    address public feeRecipient;
    /// @notice Sentiment position manager
    address public positionManager;
    /// @notice Sentiment Risk Engine
    address public riskEngine;

    /// @notice minimum amount that must be borrowed in a single operation
    uint256 public minBorrow; // in eth
    /// @notice minimum debt that a borrower must maintain
    uint256 public minDebt; // in eth

    /// @notice Fetch the owner for a given pool id
    mapping(uint256 poolId => address poolOwner) public ownerOf;
    /// @notice Fetch debt owed by a given position for a particular pool, denominated in borrow shares
    mapping(uint256 poolId => mapping(address position => uint256 borrowShares)) public borrowSharesOf;

    /// @title PoolData
    /// @notice Pool config and state container
    struct PoolData {
        bool isPaused;
        address asset;
        address rateModel;
        uint128 poolCap;
        uint128 lastUpdated;
        uint128 interestFee;
        uint128 originationFee;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 totalDepositAssets;
        uint256 totalDepositShares;
    }

    /// @notice Fetch pool config and state for a given pool id
    mapping(uint256 poolId => PoolData data) public poolDataFor;

    /// @title RateModelUpdate
    /// @notice Utility struct to store pending pool rate model updates
    struct RateModelUpdate {
        address rateModel;
        uint256 validAfter;
    }

    /// @notice Fetch pending rate model updates for a given pool id
    mapping(uint256 poolId => RateModelUpdate rateModelUpdate) public rateModelUpdateFor;

    /// @notice Minimum debt amount set
    event MinDebtSet(uint256 minDebt);
    /// @notice Minimum borrow amount set
    event MinBorrowSet(uint256 minBorrow);
    /// @notice Registry address was set
    event RegistrySet(address registry);
    /// @notice Paused state of a pool was toggled
    event PoolPauseToggled(uint256 poolId, bool paused);
    /// @notice Asset cap for a pool was set
    event PoolCapSet(uint256 indexed poolId, uint128 poolCap);
    /// @notice Owner for a pool was set
    event PoolOwnerSet(uint256 indexed poolId, address owner);
    /// @notice Rate model for a pool was updated
    event RateModelUpdated(uint256 indexed poolId, address rateModel);
    /// @notice Interest fee for a pool was updated
    event InterestFeeSet(uint256 indexed poolId, uint128 interestFee);
    /// @notice Origination fee for a pool was updated
    event OriginationFeeSet(uint256 indexed poolId, uint128 originationFee);
    /// @notice Pending rate model update for a pool was rejected
    event RateModelUpdateRejected(uint256 indexed poolId, address rateModel);
    /// @notice Rate model update for a pool was proposed
    event RateModelUpdateRequested(uint256 indexed poolId, address rateModel);
    /// @notice Default interest fee for new pools updated
    event DefaultInterestFeeSet(uint256 defaultInterestFee);
    /// @notice Default origination fee for new pools updated
    event DefaultOriginationFeeSet(uint256 defaultOriginationFee);
    /// @notice New pool was initialized
    event PoolInitialized(uint256 indexed poolId, address indexed owner, address indexed asset);
    /// @notice Assets were deposited to a pool
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    /// @notice Debt was repaid from a position to a pool
    event Repay(address indexed position, uint256 indexed poolId, address indexed asset, uint256 amount);
    /// @notice Assets were borrowed from a position to a pool
    event Borrow(address indexed position, uint256 indexed poolId, address indexed asset, uint256 amount);
    /// @notice Assets were withdrawn from a pool
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Given fee value is greater than 100%
    error Pool_FeeTooHigh();
    /// @notice Zero address cannot be the pool owner
    error Pool_ZeroAddressOwner();
    /// @notice Pool is paused
    error Pool_PoolPaused(uint256 poolId);
    /// @notice Pool deposits exceed asset cap
    error Pool_PoolCapExceeded(uint256 poolId);
    /// @notice No pending rate model update for the pool
    error Pool_NoRateModelUpdate(uint256 poolId);
    /// @notice Attempt to initialize an already existing pool
    error Pool_PoolAlreadyInitialized(uint256 poolId);
    /// @notice Attempt to redeem zero shares worth of assets from the pool
    error Pool_ZeroShareRedeem(uint256 poolId, uint256 assets);
    /// @notice Attempt to repay zero shares worth of assets to the pool
    error Pool_ZeroSharesRepay(uint256 poolId, uint256 amt);
    /// @notice Attempt to borrow zero shares worth of assets from the pool
    error Pool_ZeroSharesBorrow(uint256 poolId, uint256 amt);
    /// @notice Attempt to deposit zero shares worth of assets to the pool
    error Pool_ZeroSharesDeposit(uint256 poolId, uint256 amt);
    /// @notice Function access restricted only to the pool owner
    error Pool_OnlyPoolOwner(uint256 poolId, address sender);
    /// @notice Function access restricted only to Sentiment Position Manager
    error Pool_OnlyPositionManager(uint256 poolId, address sender);
    /// @notice Insufficient pool liquidity to service borrow
    error Pool_InsufficientBorrowLiquidity(uint256 poolId, uint256 assetsInPool, uint256 assets);
    /// @notice Insufficient pool liquidity to service withdrawal
    error Pool_InsufficientWithdrawLiquidity(uint256 poolId, uint256 assetsInPool, uint256 assets);
    /// @notice Rate model timelock delay has not been completed
    error Pool_TimelockPending(uint256 poolId, uint256 currentTimestamp, uint256 validAfter);
    /// @notice Rate model timelock deadline has passed
    error Pool_TimelockExpired(uint256 poolId, uint256 currentTimestamp, uint256 validAfter);
    /// @notice Rate model was not found in the Sentiment registry
    error Pool_RateModelNotFound(bytes32 rateModelKey);
    /// @notice Borrowed amount is lower than minimum borrow amount
    error Pool_BorrowAmountTooLow(uint256 poolId, address asset, uint256 amt);
    /// @notice Debt is below min debt amount
    error Pool_DebtTooLow(uint256 poolId, address asset, uint256 amt);
    /// @notice No oracle found for pool asset
    error Pool_OracleNotFound(address asset);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for TransparentUpgradeableProxy
    /// @param owner_ Pool owner
    /// @param registry_ Sentiment Registry
    /// @param feeRecipient_ Sentiment fee receiver
    function initialize(
        address owner_,
        uint128 defaultInterestFee_,
        uint128 defaultOriginationFee_,
        address registry_,
        address feeRecipient_,
        uint256 minBorrow_,
        uint256 minDebt_
    ) public initializer {
        _transferOwnership(owner_);

        defaultInterestFee = defaultInterestFee_;
        defaultOriginationFee = defaultOriginationFee_;
        registry = registry_;
        feeRecipient = feeRecipient_;
        minBorrow = minBorrow_;
        minDebt = minDebt_;
        updateFromRegistry();
    }

    /// @notice Fetch and update module addreses from the registry
    function updateFromRegistry() public {
        positionManager = Registry(registry).addressFor(SENTIMENT_POSITION_MANAGER_KEY);
        riskEngine = Registry(registry).addressFor(SENTIMENT_RISK_ENGINE_KEY);
    }

    /// @notice Fetch amount of liquid assets currently held in a given pool
    function getLiquidityOf(uint256 poolId) public view returns (uint256) {
        PoolData storage pool = poolDataFor[poolId];
        uint256 assetsInPool = pool.totalDepositAssets - pool.totalBorrowAssets;
        uint256 totalBalance = IERC20(pool.asset).balanceOf(address(this));
        return (totalBalance > assetsInPool) ? assetsInPool : totalBalance;
    }

    /// @notice Fetch pool asset balance for depositor to a pool
    function getAssetsOf(uint256 poolId, address guy) public view returns (uint256) {
        PoolData storage pool = poolDataFor[poolId];
        (uint256 accruedInterest, uint256 feeShares) = simulateAccrue(pool);
        return _convertToAssets(
            balanceOf[guy][poolId],
            pool.totalDepositAssets + accruedInterest,
            pool.totalDepositShares + feeShares,
            Math.Rounding.Down
        );
    }

    /// @notice Fetch debt owed by a position to a given pool
    function getBorrowsOf(uint256 poolId, address position) public view returns (uint256) {
        PoolData storage pool = poolDataFor[poolId];
        (uint256 accruedInterest,) = simulateAccrue(pool);
        // [ROUND] round up to enable enable complete debt repayment
        return _convertToAssets(
            borrowSharesOf[poolId][position],
            pool.totalBorrowAssets + accruedInterest,
            pool.totalBorrowShares,
            Math.Rounding.Up
        );
    }

    /// @notice Fetch the total amount of assets currently deposited in a pool
    function getTotalAssets(uint256 poolId) public view returns (uint256) {
        PoolData storage pool = poolDataFor[poolId];
        (uint256 accruedInterest,) = simulateAccrue(pool);
        return pool.totalDepositAssets + accruedInterest;
    }

    /// @notice Fetch total amount of debt owed to a given pool id
    function getTotalBorrows(uint256 poolId) public view returns (uint256) {
        PoolData storage pool = poolDataFor[poolId];
        (uint256 accruedInterest,) = simulateAccrue(pool);
        return pool.totalBorrowAssets + accruedInterest;
    }

    /// @notice Fetch current rate model for a given pool id
    function getRateModelFor(uint256 poolId) public view returns (address rateModel) {
        return poolDataFor[poolId].rateModel;
    }

    /// @notice Fetch the debt asset address for a given pool
    function getPoolAssetFor(uint256 poolId) public view returns (address) {
        return poolDataFor[poolId].asset;
    }

    /// @notice Fetch equivalent shares amount for given assets
    function convertToShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) external pure returns (uint256 shares) {
        shares = _convertToShares(assets, totalAssets, totalShares, Math.Rounding.Down);
    }

    function _convertToShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares,
        Math.Rounding rounding
    ) internal pure returns (uint256 shares) {
        if (totalAssets == 0) return assets;
        shares = assets.mulDiv(totalShares, totalAssets, rounding);
    }

    /// @notice Fetch equivalent asset amount for given shares
    function convertToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) external pure returns (uint256 assets) {
        assets = _convertToAssets(shares, totalAssets, totalShares, Math.Rounding.Down);
    }

    function _convertToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares,
        Math.Rounding rounding
    ) internal pure returns (uint256 assets) {
        if (totalShares == 0) return shares;
        assets = shares.mulDiv(totalAssets, totalShares, rounding);
    }

    /// @notice Deposit assets to a pool
    /// @param poolId Pool id
    /// @param assets Amount of assets to be deposited
    /// @param receiver Address to deposit assets on behalf of
    /// @return shares Amount of pool deposit shares minted
    function deposit(uint256 poolId, uint256 assets, address receiver) public returns (uint256 shares) {
        PoolData storage pool = poolDataFor[poolId];

        if (pool.isPaused) revert Pool_PoolPaused(poolId);

        // update state to accrue interest since the last time accrue() was called
        accrue(pool, poolId);

        // Need to transfer before or ERC777s could reenter, or bypass the pool cap
        IERC20(pool.asset).safeTransferFrom(msg.sender, address(this), assets);

        if (pool.totalDepositAssets + assets > pool.poolCap) revert Pool_PoolCapExceeded(poolId);

        shares = _convertToShares(assets, pool.totalDepositAssets, pool.totalDepositShares, Math.Rounding.Down);
        if (shares == 0) revert Pool_ZeroSharesDeposit(poolId, assets);

        pool.totalDepositAssets += assets;
        pool.totalDepositShares += shares;

        _mint(receiver, poolId, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraw assets from a pool
    /// @param poolId Pool id
    /// @param assets Amount of assets to be redeemed
    /// @param receiver Address that receives redeemed assets
    /// @param owner Address to redeem on behalf of
    /// @return shares Amount of shares redeemed from the pool
    function withdraw(
        uint256 poolId,
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
        PoolData storage pool = poolDataFor[poolId];

        // update state to accrue interest since the last time accrue() was called
        accrue(pool, poolId);

        shares = _convertToShares(assets, pool.totalDepositAssets, pool.totalDepositShares, Math.Rounding.Up);
        // check for rounding error since convertToShares rounds down
        if (shares == 0) revert Pool_ZeroShareRedeem(poolId, assets);

        if (msg.sender != owner && !isOperator[owner][msg.sender]) {
            uint256 allowed = allowance[owner][msg.sender][poolId];
            if (allowed != type(uint256).max) allowance[owner][msg.sender][poolId] = allowed - shares;
        }

        uint256 maxWithdrawAssets = pool.totalDepositAssets - pool.totalBorrowAssets;
        uint256 totalBalance = IERC20(pool.asset).balanceOf(address(this));
        maxWithdrawAssets = (totalBalance > maxWithdrawAssets) ? maxWithdrawAssets : totalBalance;
        if (maxWithdrawAssets < assets) revert Pool_InsufficientWithdrawLiquidity(poolId, maxWithdrawAssets, assets);

        pool.totalDepositAssets -= assets;
        pool.totalDepositShares -= shares;

        _burn(owner, poolId, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        IERC20(pool.asset).safeTransfer(receiver, assets);
    }

    /// @notice Accrue interest and fees for a given pool
    function accrue(uint256 id) external {
        PoolData storage pool = poolDataFor[id];
        accrue(pool, id);
    }

    function simulateAccrue(PoolData storage pool) internal view returns (uint256, uint256) {
        uint256 interestAccrued = IRateModel(pool.rateModel).getInterestAccrued(
            pool.lastUpdated, pool.totalBorrowAssets, pool.totalDepositAssets
        );

        uint256 interestFee = pool.interestFee;
        if (interestFee == 0) return (interestAccrued, 0);
        // [ROUND] floor fees in favor of pool lenders
        uint256 feeAssets = interestAccrued.mulDiv(pool.interestFee, 1e18);
        // [ROUND] round down in favor of pool lenders
        uint256 feeShares = _convertToShares(
            feeAssets,
            pool.totalDepositAssets + interestAccrued - feeAssets,
            pool.totalDepositShares,
            Math.Rounding.Down
        );

        return (interestAccrued, feeShares);
    }

    /// @dev update pool state to accrue interest since the last time accrue() was called
    function accrue(PoolData storage pool, uint256 id) internal {
        (uint256 interestAccrued, uint256 feeShares) = simulateAccrue(pool);

        if (feeShares != 0) _mint(feeRecipient, id, feeShares);

        // update pool state
        pool.totalDepositShares += feeShares;
        pool.totalBorrowAssets += interestAccrued;
        pool.totalDepositAssets += interestAccrued;

        // store a timestamp for this accrue() call
        // used to compute the pending interest next time accrue() is called
        pool.lastUpdated = uint128(block.timestamp);
    }

    /// @notice Mint borrow shares and send borrowed assets to the borrowing position
    /// @param position the position to mint shares to
    /// @param amt the amount of assets to borrow, denominated in notional asset units
    /// @return borrowShares the amount of shares minted
    function borrow(uint256 poolId, address position, uint256 amt) external returns (uint256 borrowShares) {
        PoolData storage pool = poolDataFor[poolId];

        if (pool.isPaused) revert Pool_PoolPaused(poolId);

        // revert if the caller is not the position manager
        if (msg.sender != positionManager) revert Pool_OnlyPositionManager(poolId, msg.sender);

        // revert if borrow amount is too low
        if (_getValueOf(pool.asset, amt) < minBorrow) revert Pool_BorrowAmountTooLow(poolId, pool.asset, amt);

        // update state to accrue interest since the last time accrue() was called
        accrue(pool, poolId);

        // pools cannot share liquidity among themselves, revert if borrow amt exceeds pool liquidity
        uint256 assetsInPool = pool.totalDepositAssets - pool.totalBorrowAssets;
        if (assetsInPool < amt) revert Pool_InsufficientBorrowLiquidity(poolId, assetsInPool, amt);

        // compute borrow shares equivalant for notional borrow amt
        // [ROUND] round up shares minted, to ensure they capture the borrowed amount
        borrowShares = _convertToShares(amt, pool.totalBorrowAssets, pool.totalBorrowShares, Math.Rounding.Up);

        // revert if borrow amt is too small
        if (borrowShares == 0) revert Pool_ZeroSharesBorrow(poolId, amt);

        // check that final debt amount is greater than min debt
        uint256 newBorrowAssets = _convertToAssets(
            borrowSharesOf[poolId][position] + borrowShares,
            pool.totalBorrowAssets + amt,
            pool.totalBorrowShares + borrowShares,
            Math.Rounding.Down
        );
        if (_getValueOf(pool.asset, newBorrowAssets) < minDebt) {
            revert Pool_DebtTooLow(poolId, pool.asset, newBorrowAssets);
        }

        // update total pool debt, denominated in notional asset units and shares
        pool.totalBorrowAssets += amt;
        pool.totalBorrowShares += borrowShares;

        // update position debt, denominated in borrow shares
        borrowSharesOf[poolId][position] += borrowShares;

        // compute origination fee amt
        // [ROUND] origination fee is rounded down, in favor of the borrower
        uint256 fee = amt.mulDiv(pool.originationFee, 1e18);

        address asset = pool.asset;
        // send origination fee to owner
        if (fee > 0) IERC20(asset).safeTransfer(feeRecipient, fee);

        // send borrowed assets to position
        IERC20(asset).safeTransfer(position, amt - fee);

        emit Borrow(position, poolId, asset, amt);
    }

    /// @notice Decrease position debt via repayment of debt and burn borrow shares
    /// @dev Assumes assets have already been sent to the pool
    /// @param position the position for which debt is being repaid
    /// @param amt the notional amount of debt asset repaid
    /// @return remainingShares remaining debt in borrow shares owed by the position
    function repay(uint256 poolId, address position, uint256 amt) external returns (uint256 remainingShares) {
        PoolData storage pool = poolDataFor[poolId];

        // the only way to call repay() is through the position manager
        // PositionManager.repay() MUST transfer the assets to be repaid before calling Pool.repay()
        // this function assumes the transfer of assets was completed successfully

        // there is an implicit assumption that assets were transferred in the same txn lest
        // the call to Pool.repay() is not frontrun allowing debt repayment for another position

        // revert if the caller is not the position manager
        if (msg.sender != positionManager) revert Pool_OnlyPositionManager(poolId, msg.sender);

        // update state to accrue interest since the last time accrue() was called
        accrue(pool, poolId);

        // compute borrow shares equivalent to notional asset amt
        // [ROUND] burn fewer borrow shares, to ensure excess debt isn't pushed to others
        uint256 borrowShares = _convertToShares(amt, pool.totalBorrowAssets, pool.totalBorrowShares, Math.Rounding.Down);

        // revert if repaid amt is too small
        if (borrowShares == 0) revert Pool_ZeroSharesRepay(poolId, amt);

        // check that final debt amount is greater than min debt
        remainingShares = borrowSharesOf[poolId][position] - borrowShares;
        if (remainingShares > 0) {
            uint256 newBorrowAssets = _convertToAssets(
                remainingShares, pool.totalBorrowAssets - amt, pool.totalBorrowShares - borrowShares, Math.Rounding.Down
            );
            if (_getValueOf(pool.asset, newBorrowAssets) < minDebt) {
                revert Pool_DebtTooLow(poolId, pool.asset, newBorrowAssets);
            }
        }

        // update total pool debt, denominated in notional asset units, and shares
        pool.totalBorrowAssets -= amt;
        pool.totalBorrowShares -= borrowShares;

        // update and return remaining position debt, denominated in borrow shares
        borrowSharesOf[poolId][position] = remainingShares;

        emit Repay(position, poolId, pool.asset, amt);

        return remainingShares;
    }

    function rebalanceBadDebt(uint256 poolId, address position) external {
        PoolData storage pool = poolDataFor[poolId];
        accrue(pool, poolId);

        // revert if the caller is not the position manager
        if (msg.sender != positionManager) revert Pool_OnlyPositionManager(poolId, msg.sender);

        // compute pool and position debt in shares and assets
        uint256 totalBorrowShares = pool.totalBorrowShares;
        uint256 totalBorrowAssets = pool.totalBorrowAssets;
        uint256 borrowShares = borrowSharesOf[poolId][position];
        // [ROUND] round up against lenders
        uint256 borrowAssets = _convertToAssets(borrowShares, totalBorrowAssets, totalBorrowShares, Math.Rounding.Up);

        // rebalance bad debt across lenders
        pool.totalBorrowShares = totalBorrowShares - borrowShares;
        // handle borrowAssets being rounded up to be greater than totalBorrowAssets
        pool.totalBorrowAssets = (totalBorrowAssets > borrowAssets) ? totalBorrowAssets - borrowAssets : 0;
        uint256 totalDepositAssets = pool.totalDepositAssets;
        pool.totalDepositAssets = (totalDepositAssets > borrowAssets) ? totalDepositAssets - borrowAssets : 0;
        borrowSharesOf[poolId][position] = 0;
    }

    function _getValueOf(address asset, uint256 amt) internal view returns (uint256) {
        address oracle = RiskEngine(riskEngine).getOracleFor(asset);
        return IOracle(oracle).getValueInEth(asset, amt);
    }

    /// @notice Initialize a new pool
    /// @param owner Pool owner
    /// @param asset Pool debt asset
    /// @param poolCap Pool asset cap
    /// @param rateModelKey Registry key for interest rate model
    /// @return poolId Pool id for initialized pool
    function initializePool(
        address owner,
        address asset,
        uint128 poolCap,
        bytes32 rateModelKey
    ) external returns (uint256 poolId) {
        if (owner == address(0)) revert Pool_ZeroAddressOwner();

        if (RiskEngine(riskEngine).getOracleFor(asset) == address(0)) revert Pool_OracleNotFound(asset);

        address rateModel = Registry(registry).rateModelFor(rateModelKey);
        if (rateModel == address(0)) revert Pool_RateModelNotFound(rateModelKey);

        poolId = uint256(keccak256(abi.encodePacked(owner, asset, rateModelKey)));
        if (ownerOf[poolId] != address(0)) revert Pool_PoolAlreadyInitialized(poolId);
        ownerOf[poolId] = owner;

        PoolData memory poolData = PoolData({
            isPaused: false,
            asset: asset,
            rateModel: rateModel,
            poolCap: poolCap,
            lastUpdated: uint128(block.timestamp),
            interestFee: defaultInterestFee,
            originationFee: defaultOriginationFee,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            totalDepositAssets: 0,
            totalDepositShares: 0
        });

        poolDataFor[poolId] = poolData;

        emit PoolInitialized(poolId, owner, asset);
        emit RateModelUpdated(poolId, rateModel);
        emit PoolCapSet(poolId, poolCap);
    }

    /// @notice Toggle paused state for a pool to restrict deposit and borrows
    function togglePause(uint256 poolId) external {
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);
        PoolData storage pool = poolDataFor[poolId];
        pool.isPaused = !pool.isPaused;
        emit PoolPauseToggled(poolId, pool.isPaused);
    }

    /// @notice Update pool asset cap to restrict total amount of assets deposited
    function setPoolCap(uint256 poolId, uint128 poolCap) external {
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);
        poolDataFor[poolId].poolCap = poolCap;
        emit PoolCapSet(poolId, poolCap);
    }

    /// @notice Update base pool owner
    function setPoolOwner(uint256 poolId, address newOwner) external {
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);
        // address(0) cannot own pools since it is used to denote uninitalized pools
        if (newOwner == address(0)) revert Pool_ZeroAddressOwner();
        ownerOf[poolId] = newOwner;
        emit PoolOwnerSet(poolId, newOwner);
    }

    /// @notice Propose a interest rate model update for a pool
    /// @dev overwrites any pending or expired updates
    function requestRateModelUpdate(uint256 poolId, bytes32 rateModelKey) external {
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);

        // store the rateModel instead of the registry key to mitigate issues
        // arising from registry changes taking place between request/accept
        // to pull registry update, call this function with the same key again
        address rateModel = Registry(registry).rateModelFor(rateModelKey);
        if (rateModel == address(0)) revert Pool_RateModelNotFound(rateModelKey);

        RateModelUpdate memory rateModelUpdate =
            RateModelUpdate({ rateModel: rateModel, validAfter: block.timestamp + TIMELOCK_DURATION });

        rateModelUpdateFor[poolId] = rateModelUpdate;

        emit RateModelUpdateRequested(poolId, rateModel);
    }

    /// @notice Apply a pending interest rate model change for a pool
    function acceptRateModelUpdate(uint256 poolId) external {
        accrue(poolDataFor[poolId], poolId); // accrue pending interest using previous rate model
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);
        RateModelUpdate memory rateModelUpdate = rateModelUpdateFor[poolId];

        // revert if there is no update to apply
        if (rateModelUpdate.validAfter == 0) revert Pool_NoRateModelUpdate(poolId);

        // revert if called before timelock delay has passed
        if (block.timestamp < rateModelUpdate.validAfter) {
            revert Pool_TimelockPending(poolId, block.timestamp, rateModelUpdate.validAfter);
        }

        // revert if timelock deadline has passed
        if (block.timestamp > rateModelUpdate.validAfter + TIMELOCK_DEADLINE) {
            revert Pool_TimelockExpired(poolId, block.timestamp, rateModelUpdate.validAfter);
        }

        // apply update
        poolDataFor[poolId].rateModel = rateModelUpdate.rateModel;
        delete rateModelUpdateFor[poolId];
        emit RateModelUpdated(poolId, rateModelUpdate.rateModel);
    }

    /// @notice Reject pending interest rate model update
    function rejectRateModelUpdate(uint256 poolId) external {
        if (msg.sender != ownerOf[poolId]) revert Pool_OnlyPoolOwner(poolId, msg.sender);
        emit RateModelUpdateRejected(poolId, rateModelUpdateFor[poolId].rateModel);
        delete rateModelUpdateFor[poolId];
    }

    /// @notice Set protocol registry address
    /// @param _registry Registry address
    function setRegistry(address _registry) external onlyOwner {
        registry = _registry;
        updateFromRegistry();
        emit RegistrySet(_registry);
    }

    /// @notice Set interest fee for given pool
    /// @param poolId Pool id
    /// @param interestFee New interest fee
    function setInterestFee(uint256 poolId, uint128 interestFee) external onlyOwner {
        PoolData storage pool = poolDataFor[poolId];
        accrue(pool, poolId);
        if (interestFee > 1e18) revert Pool_FeeTooHigh();
        pool.interestFee = interestFee;
        emit InterestFeeSet(poolId, interestFee);
    }

    /// @notice Set origination fee for given pool
    /// @param poolId Pool id
    /// @param originationFee New origination fee
    function setOriginationFee(uint256 poolId, uint128 originationFee) external onlyOwner {
        if (originationFee > 1e18) revert Pool_FeeTooHigh();
        poolDataFor[poolId].originationFee = originationFee;
        emit OriginationFeeSet(poolId, originationFee);
    }

    /// @notice Update the minimum borrow amount
    function setMinBorrow(uint256 newMinBorrow) external onlyOwner {
        minBorrow = newMinBorrow;
        emit MinBorrowSet(newMinBorrow);
    }

    /// @notice Update the min debt amount
    function setMinDebt(uint256 newMinDebt) external onlyOwner {
        minDebt = newMinDebt;
        emit MinDebtSet(newMinDebt);
    }

    function setDefaultOriginationFee(uint128 newDefaultOriginationFee) external onlyOwner {
        defaultOriginationFee = newDefaultOriginationFee;
        emit DefaultOriginationFeeSet(newDefaultOriginationFee);
    }

    function setDefaultInterestFee(uint128 newDefaultInterestFee) external onlyOwner {
        defaultInterestFee = newDefaultInterestFee;
        emit DefaultInterestFeeSet(newDefaultInterestFee);
    }
}