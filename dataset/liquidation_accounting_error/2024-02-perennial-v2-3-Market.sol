// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@equilibria/root/attribute/Instance.sol";
import "@equilibria/root/attribute/ReentrancyGuard.sol";
import "./interfaces/IMarket.sol";
import "./interfaces/IMarketFactory.sol";
import "./libs/InvariantLib.sol";

/// @title Market
/// @notice Manages logic and state for a single market.
/// @dev Cloned by the Factory contract to launch new markets.
contract Market is IMarket, Instance, ReentrancyGuard {
    Fixed6 private constant MAGIC_VALUE_WITHDRAW_ALL_COLLATERAL = Fixed6.wrap(type(int256).min);
    UFixed6 private constant MAGIC_VALUE_UNCHANGED_POSITION = UFixed6.wrap(type(uint256).max);
    UFixed6 private constant MAGIC_VALUE_FULLY_CLOSED_POSITION = UFixed6.wrap(type(uint256).max - 1);

    /// @dev The underlying token that the market settles in
    Token18 public token;

    /// @dev DEPRECATED SLOT -- previously the reward token
    bytes32 private __unused0__;

    /// @dev The oracle that provides the market price
    IOracleProvider public oracle;

    /// @dev DEPRECATED SLOT -- previously the payoff provider
    bytes32 private __unused1__;

    /// @dev Beneficiary of the market, receives donations
    address private beneficiary;

    /// @dev Risk coordinator of the market
    address private coordinator;

    /// @dev Risk parameters of the market
    RiskParameterStorage private _riskParameter;

    /// @dev Parameters of the market
    MarketParameterStorage private _parameter;

    /// @dev Current global state of the market
    GlobalStorage private _global;

    /// @dev Current global position of the market
    PositionStorageGlobal private _position;

    /// @dev DEPRECATED SLOT -- previously the global pending positions
    bytes32 private __unused2__;

    /// @dev Current local state of each account
    mapping(address => LocalStorage) private _locals;

    /// @dev Current local position of each account
    mapping(address => PositionStorageLocal) private _positions;

    /// @dev DEPRECATED SLOT -- previously the local pending positions
    bytes32 private __unused3__;

    /// @dev The historical version accumulator data for each accessed version
    mapping(uint256 => VersionStorage) private _versions;

    /// @dev The global pending order for each id
    mapping(uint256 => OrderStorageGlobal) private _pendingOrder;

    /// @dev The local pending order for each id for each account
    mapping(address => mapping(uint256 => OrderStorageLocal)) private _pendingOrders;

    /// @dev The global aggregate pending order
    OrderStorageGlobal private _pending;

    /// @dev The local aggregate pending order for each account
    mapping(address => OrderStorageLocal) private _pendings;

    /// @dev The local checkpoint for each id for each account
    mapping(address => mapping(uint256 => CheckpointStorage)) private _checkpoints;

    /// @dev The liquidator for each id for each account
    mapping(address => mapping(uint256 => address)) public liquidators;

    /// @dev The referrer for each id for each account
    mapping(address => mapping(uint256 => address)) public referrers;

    /// @notice Initializes the contract state
    /// @param definition_ The market definition
    function initialize(IMarket.MarketDefinition calldata definition_) external initializer(1) {
        __Instance__initialize();
        __ReentrancyGuard__initialize();

        token = definition_.token;
        oracle = definition_.oracle;
    }

    /// @notice Settles the account's position and collateral
    /// @param account The account to operate on
    function settle(address account) external nonReentrant whenNotPaused {
        Context memory context = _loadContext(account);

        _settle(context, account);

        _storeContext(context, account);
    }

    /// @notice Updates the account's position and collateral
    /// @param account The account to operate on
    /// @param newMaker The new maker position for the account
    /// @param newMaker The new long position for the account
    /// @param newMaker The new short position for the account
    /// @param collateral The collateral amount to add or remove from the account
    /// @param protect Whether to put the account into a protected status for liquidations
    function update(
        address account,
        UFixed6 newMaker,
        UFixed6 newLong,
        UFixed6 newShort,
        Fixed6 collateral,
        bool protect
    ) external {
        update(account, newMaker, newLong, newShort, collateral, protect, address(0));
    }

    /// @notice Updates the account's position and collateral
    /// @param account The account to operate on
    /// @param newMaker The new maker position for the account
    /// @param newMaker The new long position for the account
    /// @param newMaker The new short position for the account
    /// @param collateral The collateral amount to add or remove from the account
    /// @param protect Whether to put the account into a protected status for liquidations
    /// @param referrer The referrer of the order
    function update(
        address account,
        UFixed6 newMaker,
        UFixed6 newLong,
        UFixed6 newShort,
        Fixed6 collateral,
        bool protect,
        address referrer
    ) public nonReentrant whenNotPaused {
        Context memory context = _loadContext(account);

        _settle(context, account);
        _update(context, account, newMaker, newLong, newShort, collateral, protect, referrer);

        _storeContext(context, account);
    }

    /// @notice Updates the oracle of the market
    /// @dev For the v2.1.1 -> v2.2 migration process, not to be used otherwise
    /// @param newOracle The new oracle address
    function updateOracle(IOracleProvider newOracle) external onlyOwner {
        oracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    /// @notice Updates the beneficiary, coordinator, and parameter set of the market
    /// @param newBeneficiary The new beneficiary address
    /// @param newCoordinator The new coordinator address
    /// @param newParameter The new parameter set
    function updateParameter(
        address newBeneficiary,
        address newCoordinator,
        MarketParameter memory newParameter
    ) external onlyOwner {
        beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(newBeneficiary);

        coordinator = newCoordinator;
        emit CoordinatorUpdated(newCoordinator);

        _parameter.validateAndStore(newParameter, IMarketFactory(address(factory())).parameter());
        emit ParameterUpdated(newParameter);
    }

    /// @notice Updates the risk parameter set of the market
    /// @param newRiskParameter The new risk parameter set
    function updateRiskParameter(RiskParameter memory newRiskParameter) external onlyCoordinator {

        // credit impact update fee to the protocol account
        Global memory newGlobal = _global.read();
        Position memory latestPosition = _position.read();
        RiskParameter memory latestRiskParameter = _riskParameter.read();
        OracleVersion memory latestVersion = oracle.at(latestPosition.timestamp);

        Fixed6 updateFee = latestRiskParameter.makerFee
            .update(newRiskParameter.makerFee, latestPosition.maker, latestVersion.price.abs())
            .add(latestRiskParameter.takerFee
                .update(newRiskParameter.takerFee, latestPosition.skew(), latestVersion.price.abs()));

        newGlobal.exposure = newGlobal.exposure.sub(updateFee);
        _global.store(newGlobal);

        // update
        _riskParameter.validateAndStore(newRiskParameter, IMarketFactory(address(factory())).parameter());
        emit RiskParameterUpdated(newRiskParameter);
    }

    /// @notice Claims any available fee that the sender has accrued
    /// @dev Applicable fees include: protocol, oracle, risk, donation, and claimable
    function claimFee() external {
        Global memory newGlobal = _global.read();
        Local memory newLocal = _locals[msg.sender].read();

        if (_claimFee(factory().owner(), newGlobal.protocolFee)) newGlobal.protocolFee = UFixed6Lib.ZERO;
        if (_claimFee(address(IMarketFactory(address(factory())).oracleFactory()), newGlobal.oracleFee))
            newGlobal.oracleFee = UFixed6Lib.ZERO;
        if (_claimFee(coordinator, newGlobal.riskFee)) newGlobal.riskFee = UFixed6Lib.ZERO;
        if (_claimFee(beneficiary, newGlobal.donation)) newGlobal.donation = UFixed6Lib.ZERO;
        if (_claimFee(msg.sender, newLocal.claimable)) newLocal.claimable = UFixed6Lib.ZERO;

        _global.store(newGlobal);
        _locals[msg.sender].store(newLocal);
    }

    /// @notice Settles any exposure that has accrued to the market
    /// @dev Resets exposure to zero, caller pays or receives to net out the exposure
    function claimExposure() external onlyOwner {
        Global memory newGlobal = _global.read();

        if (newGlobal.exposure.sign() == 1) token.push(msg.sender, UFixed18Lib.from(newGlobal.exposure.abs()));
        if (newGlobal.exposure.sign() == -1) token.pull(msg.sender, UFixed18Lib.from(newGlobal.exposure.abs()));

        emit ExposureClaimed(msg.sender, newGlobal.exposure);

        newGlobal.exposure = Fixed6Lib.ZERO;
        _global.store(newGlobal);
    }

    /// @notice Helper function to handle a singular fee claim.
    /// @param receiver The address to receive the fee
    /// @param fee The amount of the fee to claim
    function _claimFee(address receiver, UFixed6 fee) private returns (bool) {
        if (msg.sender != receiver || fee.isZero()) return false;

        token.push(receiver, UFixed18Lib.from(fee));
        emit FeeClaimed(receiver, fee);
        return true;
    }

    /// @notice Returns the payoff provider
    /// @dev For backwards compatibility
    function payoff() external pure returns (address) {
        return address(0);
    }

    /// @notice Returns the current parameter set
    function parameter() external view returns (MarketParameter memory) {
        return _parameter.read();
    }

    /// @notice Returns the current risk parameter set
    function riskParameter() external view returns (RiskParameter memory) {
        return _riskParameter.read();
    }

    /// @notice Returns the current global position
    function position() external view returns (Position memory) {
        return _position.read();
    }

    /// @notice Returns the current local position for the account
    /// @param account The account to query
    function positions(address account) external view returns (Position memory) {
        return _positions[account].read();
    }

    /// @notice Returns the current global state
    function global() external view returns (Global memory) {
        return _global.read();
    }

    /// @notice Returns the historical version snapshot at the given timestamp
    /// @param timestamp The timestamp to query
    function versions(uint256 timestamp) external view returns (Version memory) {
        return _versions[timestamp].read();
    }

    /// @notice Returns the local state for the given account
    /// @param account The account to query
    function locals(address account) external view returns (Local memory) {
        return _locals[account].read();
    }

    /// @notice Returns the global pending order for the given id
    /// @param id The id to query
    function pendingOrder(uint256 id) external view returns (Order memory) {
        return _pendingOrder[id].read();
    }

    /// @notice Returns the local pending order for the given account and id
    /// @param account The account to query
    /// @param id The id to query
    function pendingOrders(address account, uint256 id) external view returns (Order memory) {
        return _pendingOrders[account][id].read();
    }

    /// @notice Returns the aggregate global pending order
    function pending() external view returns (Order memory) {
        return _pending.read();
    }

    /// @notice Returns the aggregate local pending order for the given account
    /// @param account The account to query
    function pendings(address account) external view returns (Order memory) {
        return _pendings[account].read();
    }

    /// @notice Returns the local checkpoint for the given account and version
    /// @param account The account to query
    /// @param version The version to query
    function checkpoints(address account, uint256 version) external view returns (Checkpoint memory) {
        return _checkpoints[account][version].read();
    }

    /// @notice Loads the transaction context
    /// @param account The account to load for
    /// @return context The transaction context
    function _loadContext(address account) private view returns (Context memory context) {
        // parameters
        context.marketParameter = _parameter.read();
        context.riskParameter = _riskParameter.read();
        context.protocolParameter = IMarketFactory(address(factory())).parameter();

        // oracle
        (context.latestOracleVersion, context.currentTimestamp) = oracle.status();

        // state
        context.global = _global.read();
        context.local = _locals[account].read();

        // latest positions
        context.latestPosition.global = _position.read();
        context.latestPosition.local = _positions[account].read();

        // aggregate pending orders
        context.pending.global = _pending.read();
        context.pending.local = _pendings[account].read();
    }

    /// @notice Stores the context for the transaction
    /// @param context The context to store
    /// @param account The account to store for
    function _storeContext(Context memory context, address account) private {
        // state
        _global.store(context.global);
        _locals[account].store(context.local);

        // latest positions
        _position.store(context.latestPosition.global);
        _positions[account].store(context.latestPosition.local);

        // aggregate pending orders
        _pending.store(context.pending.global);
        _pendings[account].store(context.pending.local);
    }

    /// @notice Loads the context for the update process
    /// @param context The context to load to
    /// @param account The account to load for
    /// @param referrer The referrer to load for
    /// @return updateContext The update context
    function _loadUpdateContext(
        Context memory context,
        address account,
        address referrer
    ) private view returns (UpdateContext memory updateContext) {
        // load current position
        updateContext.currentPosition.global = context.latestPosition.global.clone();
        updateContext.currentPosition.global.update(context.pending.global);
        updateContext.currentPosition.local = context.latestPosition.local.clone();
        updateContext.currentPosition.local.update(context.pending.local);

        // load current order
        updateContext.order.global = _pendingOrder[context.global.currentId].read();
        updateContext.order.local = _pendingOrders[account][context.local.currentId].read();

        // load external actors
        updateContext.operator = IMarketFactory(address(factory())).operators(account, msg.sender);
        updateContext.liquidator = liquidators[account][context.local.currentId];
        updateContext.referrer = referrers[account][context.local.currentId];
        updateContext.referralFee = IMarketFactory(address(factory())).referralFee(referrer);
    }

    /// @notice Stores the context for the update process
    /// @param context The transaction context
    /// @param updateContext The update context to store
    /// @param account The account to store for
    function _storeUpdateContext(Context memory context, UpdateContext memory updateContext, address account) private {
        // current orders
        _pendingOrder[context.global.currentId].store(updateContext.order.global);
        _pendingOrders[account][context.local.currentId].store(updateContext.order.local);

        // external actors
        liquidators[account][context.local.currentId] = updateContext.liquidator;
        referrers[account][context.local.currentId] = updateContext.referrer;
    }

    /// @notice Updates the current position
    /// @param context The context to use
    /// @param account The account to update
    /// @param newMaker The new maker position size
    /// @param newLong The new long position size
    /// @param newShort The new short position size
    /// @param collateral The change in collateral
    /// @param protect Whether to protect the position for liquidation
    function _update(
        Context memory context,
        address account,
        UFixed6 newMaker,
        UFixed6 newLong,
        UFixed6 newShort,
        Fixed6 collateral,
        bool protect,
        address referrer
    ) private notSettleOnly(context) {
        // load
        UpdateContext memory updateContext = _loadUpdateContext(context, account, referrer);

        // magic values
        collateral = _processCollateralMagicValue(context, collateral);
        newMaker = _processPositionMagicValue(context, updateContext.currentPosition.local.maker, newMaker);
        newLong = _processPositionMagicValue(context, updateContext.currentPosition.local.long, newLong);
        newShort = _processPositionMagicValue(context, updateContext.currentPosition.local.short, newShort);

        // referral fee
        UFixed6 referralFee = _processReferralFee(context, updateContext, referrer);

        // advance to next id if applicable
        if (context.currentTimestamp > updateContext.order.local.timestamp) {
            updateContext.order.local.next(context.currentTimestamp);
            context.local.currentId++;
        }
        if (context.currentTimestamp > updateContext.order.global.timestamp) {
            updateContext.order.global.next(context.currentTimestamp);
            context.global.currentId++;
        }

        // update current position
        Order memory newOrder = OrderLib.from(
            context.currentTimestamp,
            updateContext.currentPosition.local,
            collateral,
            newMaker,
            newLong,
            newShort,
            protect,
            referralFee
        );
        updateContext.currentPosition.global.update(newOrder);
        updateContext.currentPosition.local.update(newOrder);

        // apply new order
        updateContext.order.local.add(newOrder);
        updateContext.order.global.add(newOrder);
        context.pending.global.add(newOrder);
        context.pending.local.add(newOrder);

        // update collateral
        context.local.update(collateral);

        // protect account
        if (newOrder.protected()) updateContext.liquidator = msg.sender;

        // apply referrer
        _processReferrer(updateContext, newOrder, referrer);

        // request version
        if (!newOrder.isEmpty()) oracle.request(IMarket(this), account);

        // after
        InvariantLib.validate(context, updateContext, msg.sender, account, newOrder, collateral);

        // store
        _storeUpdateContext(context, updateContext, account);

        // fund
        if (collateral.sign() == 1) token.pull(msg.sender, UFixed18Lib.from(collateral.abs()));
        if (collateral.sign() == -1) token.push(msg.sender, UFixed18Lib.from(collateral.abs()));

        // events
        emit Updated(msg.sender, account, context.currentTimestamp, newMaker, newLong, newShort, collateral, protect, referrer);
        emit OrderCreated(account, newOrder);
    }

    /// @notice Processes the referral fee for the given order
    /// @param context The context to use
    /// @param updateContext The update context to use
    /// @param referrer The referrer of the order
    /// @return The referral fee to apply
    function _processReferralFee(
        Context memory context,
        UpdateContext memory updateContext,
        address referrer
    ) private pure returns (UFixed6) {
        if (referrer == address(0)) return UFixed6Lib.ZERO;
        if (!updateContext.referralFee.isZero()) return updateContext.referralFee;
        return context.protocolParameter.referralFee;
    }

    /// @notice Processes the referrer for the given order
    /// @param updateContext The update context to use
    /// @param newOrder The order to process
    /// @param referrer The referrer of the order
    function _processReferrer(
        UpdateContext memory updateContext,
        Order memory newOrder,
        address referrer
    ) private pure {
        if (newOrder.makerReferral.isZero() && newOrder.takerReferral.isZero()) return;
        if (updateContext.referrer == address(0)) updateContext.referrer = referrer;
        if (updateContext.referrer == referrer) return;

        revert MarketInvalidReferrerError();
    }

    /// @notice Loads the settlement context
    /// @param context The transaction context
    /// @param account The account to load for
    /// @return settlementContext The settlement context
    function _loadSettlementContext(
        Context memory context,
        address account
    ) private view returns (SettlementContext memory settlementContext) {
        // processing accumulators
        settlementContext.latestVersion = _versions[context.latestPosition.global.timestamp].read();
        settlementContext.latestCheckpoint = _checkpoints[account][context.latestPosition.local.timestamp].read();
        settlementContext.orderOracleVersion = oracle.at(context.latestPosition.global.timestamp);

        // v2.2 migration (if latest checkpoint is empty, initialize with latest local collateral)
        if (
            settlementContext.latestCheckpoint.tradeFee.isZero() &&
            settlementContext.latestCheckpoint.settlementFee.isZero() &&
            settlementContext.latestCheckpoint.transfer.isZero() &&
            settlementContext.latestCheckpoint.collateral.isZero() &&
            context.pending.local.collateral.isZero()
        ) settlementContext.latestCheckpoint.collateral = context.local.collateral;
    }

    /// @notice Settles the account position up to the latest version
    /// @param context The context to use
    /// @param account The account to settle
    function _settle(Context memory context, address account) private {
        SettlementContext memory settlementContext = _loadSettlementContext(context, account);

        Order memory nextOrder;

        // settle
        while (
            context.global.currentId != context.global.latestId &&
            (nextOrder = _pendingOrder[context.global.latestId + 1].read()).ready(context.latestOracleVersion)
        ) _processOrderGlobal(context, settlementContext, context.global.latestId + 1, nextOrder);

        while (
            context.local.currentId != context.local.latestId &&
            (nextOrder = _pendingOrders[account][context.local.latestId + 1].read()).ready(context.latestOracleVersion)
        ) _processOrderLocal(context, settlementContext, account, context.local.latestId + 1, nextOrder);

        // sync
        if (context.latestOracleVersion.timestamp > context.latestPosition.global.timestamp) {
            nextOrder = _pendingOrder[context.global.latestId].read();
            nextOrder.next(context.latestOracleVersion.timestamp);
            _processOrderGlobal(context, settlementContext, context.global.latestId, nextOrder);
        }

        if (context.latestOracleVersion.timestamp > context.latestPosition.local.timestamp) {
            nextOrder = _pendingOrders[account][context.local.latestId].read();
            nextOrder.next(context.latestOracleVersion.timestamp);
            _processOrderLocal(context, settlementContext, account, context.local.latestId, nextOrder);
        }
    }

    /// @notice Modifies the collateral input per magic values
    /// @param context The context to use
    /// @param collateral The collateral to process
    /// @return The resulting collateral value
    function _processCollateralMagicValue(Context memory context, Fixed6 collateral) private pure returns (Fixed6) {
        return collateral.eq(MAGIC_VALUE_WITHDRAW_ALL_COLLATERAL) ?
            context.local.collateral.mul(Fixed6Lib.NEG_ONE) :
            collateral;
    }

    /// @notice Modifies the position input per magic values
    /// @param context The context to use
    /// @param currentPosition The current position prior to update
    /// @param newPosition The position to process
    /// @return The resulting position value
    function _processPositionMagicValue(
        Context memory context,
        UFixed6 currentPosition,
        UFixed6 newPosition
    ) private pure returns (UFixed6) {
        if (newPosition.eq(MAGIC_VALUE_UNCHANGED_POSITION))
            return currentPosition;
        if (newPosition.eq(MAGIC_VALUE_FULLY_CLOSED_POSITION)) {
            if (currentPosition.isZero()) return currentPosition;
            return currentPosition.sub(context.latestPosition.local.magnitude().sub(context.pending.local.neg()));
        }
        return newPosition;
    }

    /// @notice Processes the given global pending position into the latest position
    /// @param context The context to use
    /// @param newOrderId The id of the pending position to process
    /// @param newOrder The pending position to process
    function _processOrderGlobal(
        Context memory context,
        SettlementContext memory settlementContext,
        uint256 newOrderId,
        Order memory newOrder
    ) private {
        OracleVersion memory oracleVersion = oracle.at(newOrder.timestamp);

        context.pending.global.sub(newOrder);
        if (!oracleVersion.valid) newOrder.invalidate();

        VersionAccumulationResult memory accumulationResult;
        (settlementContext.latestVersion, context.global, accumulationResult) = VersionLib.accumulate(
            settlementContext.latestVersion,
            context.global,
            context.latestPosition.global,
            newOrder,
            settlementContext.orderOracleVersion,
            oracleVersion,
            context.marketParameter,
            context.riskParameter
        );

        context.global.update(newOrderId, accumulationResult, context.marketParameter, context.protocolParameter);
        context.latestPosition.global.update(newOrder);

        settlementContext.orderOracleVersion = oracleVersion;
        _versions[newOrder.timestamp].store(settlementContext.latestVersion);

        emit PositionProcessed(newOrderId, newOrder, accumulationResult);
    }

    /// @notice Processes the given local pending position into the latest position
    /// @param context The context to use
    /// @param account The account to process for
    /// @param newOrderId The id of the pending position to process
    /// @param newOrder The pending order to process
    function _processOrderLocal(
        Context memory context,
        SettlementContext memory settlementContext,
        address account,
        uint256 newOrderId,
        Order memory newOrder
    ) private {
        Version memory versionFrom = _versions[context.latestPosition.local.timestamp].read();
        Version memory versionTo = _versions[newOrder.timestamp].read();

        context.pending.local.sub(newOrder);
        if (!versionTo.valid) newOrder.invalidate();

        CheckpointAccumulationResult memory accumulationResult;
        (settlementContext.latestCheckpoint, accumulationResult) = CheckpointLib.accumulate(
            settlementContext.latestCheckpoint,
            newOrder,
            context.latestPosition.local,
            versionFrom,
            versionTo
        );

        context.local.update(newOrderId, accumulationResult);
        context.latestPosition.local.update(newOrder);

        _checkpoints[account][newOrder.timestamp].store(settlementContext.latestCheckpoint);

        _credit(liquidators[account][newOrderId], accumulationResult.liquidationFee);
        _credit(referrers[account][newOrderId], accumulationResult.subtractiveFee);

        emit AccountPositionProcessed(account, newOrderId, newOrder, accumulationResult);
    }

    /// @notice Credits an account's claimable that is out-of-context
    /// @dev The amount must have already come from a corresponing debit in the settlement flow
    /// @param account The account to credit
    /// @param amount The amount to credit
    function _credit(address account, UFixed6 amount) private {
        if (amount.isZero()) return;

        Local memory newLocal = _locals[account].read();
        newLocal.credit(amount);
        _locals[account].store(newLocal);
    }

    /// @notice Only the coordinator or the owner can call
    modifier onlyCoordinator {
        if (msg.sender != coordinator && msg.sender != factory().owner()) revert MarketNotCoordinatorError();
        _;
    }

    /// @notice Only when the market is not in settle-only mode
    modifier notSettleOnly(Context memory context) {
        if (context.marketParameter.settle) revert MarketSettleOnlyError();
        _;
    }
}
