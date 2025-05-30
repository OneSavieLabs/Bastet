// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                        Position Manager
//////////////////////////////////////////////////////////////*/

// types
import { Pool } from "./Pool.sol";
import { Position } from "./Position.sol";
import { Registry } from "./Registry.sol";
import { RiskEngine } from "./RiskEngine.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// libraries
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// contracts
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title DebtData
/// @notice Data struct for position debt to be repaid by the liquidator
struct DebtData {
    // poolId address for debt to be repaid
    uint256 poolId;
    // amount of debt to be repaid by the liquidator
    // position manager assumes that this amount has already been approved
    uint256 amt;
}

/// @title AssetData
/// @notice Data struct for collateral assets to be received by the liquidator
struct AssetData {
    // token address
    address asset;
    // amount of collateral to be received by liquidator
    uint256 amt;
}

/// @title Operation
/// @notice Operation type definitions that can be applied to a position
/// @dev Every operation except NewPosition requires that the caller must be an authz caller or owner
enum Operation {
    NewPosition, // create2 a new position with a given type, no auth needed
    // the following operations require msg.sender to be authorized
    Exec, // execute arbitrary calldata on a position
    Deposit, // Add collateral to a given position
    Transfer, // transfer assets from the position to a external address
    Approve, // allow a spender to transfer assets from a position
    Repay, // decrease position debt
    Borrow, // increase position debt
    AddToken, // upsert collateral asset to position storage
    RemoveToken // remove collateral asset from position storage

}

/// @title Action
/// @notice Generic data struct to create a common data container for all operation types
/// @dev target and data are interpreted in different ways based on the operation type
struct Action {
    // operation type
    Operation op;
    // dynamic bytes data, interepreted differently across operation types
    bytes data;
}

/// @title PositionManager
/// @notice Handles the deployment and use of Positions against the Singleton Pool Contract
contract PositionManager is ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // keccak(SENTIMENT_POOL_KEY)
    bytes32 public constant SENTIMENT_POOL_KEY = 0x1a99cbf6006db18a0e08427ff11db78f3ea1054bc5b9d48122aae8d206c09728;
    // keccak(SENTIMENT_RISK_ENGINE_KEY)
    bytes32 public constant SENTIMENT_RISK_ENGINE_KEY =
        0x5b6696788621a5d6b5e3b02a69896b9dd824ebf1631584f038a393c29b6d7555;
    // keccak(SENTIMENT_POSITION_BEACON_KEY)
    bytes32 public constant SENTIMENT_POSITION_BEACON_KEY =
        0x6e7384c78b0e09fb848f35d00a7b14fc1ad10ae9b10117368146c0e09b6f2fa2;

    /// @notice Sentiment Singleton Pool
    Pool public pool;
    /// @notice Sentiment Registry
    Registry public registry;
    /// @notice Sentiment Risk Engine
    RiskEngine public riskEngine;
    /// @notice Position Beacon
    address public positionBeacon;

    /// @notice Liquidation fee in percentage, scaled by 18 decimals
    /// @dev accrued to the protocol on every liquidation
    uint256 public liquidationFee;

    /// @notice Fetch owner for given position
    mapping(address position => address owner) public ownerOf;

    /// @notice Check if a given address is allowed to operate on a particular position
    /// @dev [caller][position] => [isAuthorized] stores if caller is authorized to operate on position
    mapping(address position => mapping(address caller => bool isAuthz)) public isAuth;

    // universe mappings:
    // the following two mappings define the universe of the protocol. this is used to define a
    // subset of the network that a position can freely interact with. isKnownAddress defines
    // recognized addresses. these include assets that a position interacts with and addresses that
    // can approved as spenders' for assets in a position. isKnownFunc defines the exec universe
    // for a function by creating a mapping of particular target-function pairs that can be called
    // by a position.

    /// @notice Check if a given address is recognized by the protocol
    mapping(address asset => bool isAllowed) public isKnownAsset;
    /// @notice Check if a given spender is recognized by the protocol
    mapping(address spender => bool isKnown) public isKnownSpender;
    /// @notice Check if a position can interact with a given target-function pair
    mapping(address target => mapping(bytes4 method => bool isAllowed)) public isKnownFunc;

    /// @notice Position Beacon address was updated
    event BeaconSet(address beacon);
    /// @notice Protocol registry address was updated
    event RegistrySet(address registry);
    /// @notice Protocol liquidation fee was updated
    event LiquidationFeeSet(uint256 liquidationFee);
    /// @notice Known state of an address was toggled
    event ToggleKnownAsset(address indexed asset, bool isAllowed);
    /// @notice Known state of an address was toggled
    event ToggleKnownSpender(address indexed spender, bool isAllowed);
    /// @notice Token was added to a position's asset list
    event AddToken(address indexed position, address indexed caller, address asset);
    /// @notice Known state of a target-function pair was toggled
    event ToggleKnownFunc(address indexed target, bytes4 indexed method, bool isAllowed);
    /// @notice Token was removed from a position's asset list
    event RemoveToken(address indexed position, address indexed caller, address asset);
    /// @notice Position was successfully liquidated
    event Liquidation(address indexed position, address indexed liquidator, address indexed owner);
    /// @notice New position was deployed
    event PositionDeployed(address indexed position, address indexed caller, address indexed owner);
    /// @notice Assets were deposited to a position
    event Deposit(address indexed position, address indexed depositor, address asset, uint256 amount);
    /// @notice Debt was repaid from a position to a pool
    event Repay(address indexed position, address indexed caller, uint256 indexed poolId, uint256 amount);
    /// @notice Assets were borrowed from a pool to a position
    event Borrow(address indexed position, address indexed caller, uint256 indexed poolId, uint256 amount);
    /// @notice An external operation was executed on a position
    event Exec(address indexed position, address indexed caller, address indexed target, bytes4 functionSelector);
    /// @notice Assets were transferred out of a position
    event Transfer(
        address indexed position, address indexed caller, address indexed target, address asset, uint256 amount
    );
    /// @notice Approval was granted for assets belonging to a position
    event Approve(
        address indexed position, address indexed caller, address indexed spender, address asset, uint256 amount
    );

    /// @notice The pool a position is trying to borrow from does not exist
    error PositionManager_UnknownPool(uint256 poolId);
    /// @notice Unknown spenders cannot be granted approval to position assets
    error PositionManager_UnknownSpender(address spender);
    /// @notice Position health check failed
    error PositionManager_HealthCheckFailed(address position);
    /// @notice Attempt to add unrecognized asset to a position's asset list
    error PositionManager_AddUnknownToken(address asset);
    /// @notice Attempt to approve unknown asset
    error PositionManager_ApproveUnknownAsset(address asset);
    /// @notice Attempt to deposit unrecognized asset to position
    error PositionManager_DepositUnknownAsset(address asset);
    /// @notice Attempt to transfer unrecognized asset out of position
    error PositionManager_TransferUnknownAsset(address asset);
    /// @notice Cannot liquidate healthy position
    error PositionManager_LiquidateHealthyPosition(address position);
    /// @notice Function access restricted to position owner only
    error PositionManager_OnlyPositionOwner(address position, address sender);
    /// @notice Unknown target-function selector pair
    error PositionManager_UnknownFuncSelector(address target, bytes4 selector);
    /// @notice Function access restricted to authorozied addresses
    error PositionManager_OnlyPositionAuthorized(address position, address sender);
    /// @notice Predicted position address does not match with deployed address
    error PositionManager_PredictedPositionMismatch(address position, address predicted);
    /// @notice Seized asset does not belong to to the position's asset list
    error PositionManager_SeizeInvalidAsset(address position, address asset);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for TransparentUpgradeableProxy
    /// @param owner_ PositionManager Owner
    /// @param registry_ Sentiment Registry
    /// @param liquidationFee_ Protocol liquidation fee
    function initialize(address owner_, address registry_, uint256 liquidationFee_) public initializer {
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        OwnableUpgradeable.__Ownable_init();
        PausableUpgradeable.__Pausable_init();
        _transferOwnership(owner_);

        registry = Registry(registry_);
        liquidationFee = liquidationFee_;
    }

    /// @notice Fetch and update module addreses from the registry
    function updateFromRegistry() public {
        pool = Pool(registry.addressFor(SENTIMENT_POOL_KEY));
        riskEngine = RiskEngine(registry.addressFor(SENTIMENT_RISK_ENGINE_KEY));
        positionBeacon = registry.addressFor(SENTIMENT_POSITION_BEACON_KEY);
    }

    /// @notice Toggle pause state of the PositionManager
    function togglePause() external onlyOwner {
        if (PausableUpgradeable.paused()) PausableUpgradeable._unpause();
        else PausableUpgradeable._pause();
    }

    /// @notice Authorize a caller other than the owner to operate on a position
    function toggleAuth(address user, address position) external {
        // only account owners are allowed to modify authorizations
        // disables transitive auth operations
        if (msg.sender != ownerOf[position]) revert PositionManager_OnlyPositionOwner(position, msg.sender);

        // update authz status in storage
        isAuth[position][user] = !isAuth[position][user];
    }

    /// @notice Process a single action on a given position
    /// @param position Position address
    /// @param action Action config
    function process(address position, Action calldata action) external nonReentrant whenNotPaused {
        _process(position, action);
        if (!riskEngine.isPositionHealthy(position)) revert PositionManager_HealthCheckFailed(position);
    }

    /// @notice Procces a batch of actions on a given position
    /// @dev only one position can be operated on in one txn, including creation
    /// @param position Position address
    /// @param actions List of actions to process
    function processBatch(address position, Action[] calldata actions) external nonReentrant whenNotPaused {
        // loop over actions and process them sequentially based on operation
        uint256 actionsLength = actions.length;
        for (uint256 i; i < actionsLength; ++i) {
            _process(position, actions[i]);
        }
        // after all the actions are processed, the position should be within risk thresholds
        if (!riskEngine.isPositionHealthy(position)) revert PositionManager_HealthCheckFailed(position);
    }

    function _process(address position, Action calldata action) internal {
        if (action.op == Operation.NewPosition) {
            newPosition(position, action.data);
            return;
        }

        if (!isAuth[position][msg.sender]) revert PositionManager_OnlyPositionAuthorized(position, msg.sender);

        if (action.op == Operation.Exec) exec(position, action.data);
        else if (action.op == Operation.Transfer) transfer(position, action.data);
        else if (action.op == Operation.Deposit) deposit(position, action.data);
        else if (action.op == Operation.Approve) approve(position, action.data);
        else if (action.op == Operation.Repay) repay(position, action.data);
        else if (action.op == Operation.Borrow) borrow(position, action.data);
        else if (action.op == Operation.AddToken) addToken(position, action.data);
        else if (action.op == Operation.RemoveToken) removeToken(position, action.data);
    }

    /// @dev deterministically deploy a new beacon proxy representing a position
    /// @dev the target field in the action is the new owner of the position
    function newPosition(address predictedAddress, bytes calldata data) internal {
        // data -> abi.encodePacked(address, bytes32)
        // owner -> [:20] owner to create the position on behalf of
        // salt -> [20:52] create2 salt for position
        address owner = address(bytes20(data[0:20]));
        bytes32 salt = bytes32(data[20:52]);

        // hash salt with owner to mitigate positions being frontrun
        salt = keccak256(abi.encodePacked(owner, salt));
        // create2 a new position as a beacon proxy
        address position = address(new BeaconProxy{ salt: salt }(positionBeacon, ""));
        // update position owner
        ownerOf[position] = owner;
        // owner is authzd by default
        isAuth[position][owner] = true;
        // revert if predicted position address does not match deployed address
        if (position != predictedAddress) revert PositionManager_PredictedPositionMismatch(position, predictedAddress);
        emit PositionDeployed(position, msg.sender, owner);
    }

    /// @dev Operate on a position by interaction with external contracts using arbitrary calldata
    function exec(address position, bytes calldata data) internal {
        // exec data is encodePacked (address, uint256, bytes)
        // target -> [0:20] contract address to be called by the position
        // value -> [20:52] the ether amount to be sent with the call
        // function selector -> [52:56] function selector to be called on the target
        // calldata -> [52:] represents the calldata including the func selector

        address target = address(bytes20(data[:20]));
        uint256 value = uint256(bytes32(data[20:52]));
        bytes4 funcSelector = bytes4(data[52:56]);

        if (!isKnownFunc[target][funcSelector]) revert PositionManager_UnknownFuncSelector(target, funcSelector);

        Position(payable(position)).exec(target, value, data[52:]);
        emit Exec(position, msg.sender, target, funcSelector);
    }

    /// @dev Transfer assets out of a position
    function transfer(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(address, address, uint256)
        // recipient -> [0:20] address that will receive the transferred tokens
        // asset -> [20:40] address of token to be transferred
        // amt -> [40:72] amount of asset to be transferred
        address recipient = address(bytes20(data[0:20]));
        address asset = address(bytes20(data[20:40]));
        uint256 amt = uint256(bytes32(data[40:72]));

        if (!isKnownAsset[asset]) revert PositionManager_TransferUnknownAsset(asset);

        // if the passed amt is type(uint).max assume transfer of the entire balance
        if (amt == type(uint256).max) amt = IERC20(asset).balanceOf(position);

        Position(payable(position)).transfer(recipient, asset, amt);
        emit Transfer(position, msg.sender, recipient, asset, amt);
    }

    /// @dev Deposit assets from msg.sender to a position
    function deposit(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(address, uint256)
        // asset -> [0:20] address of token to be deposited
        // amt -> [20: 52] amount of asset to be deposited
        address asset = address(bytes20(data[0:20]));
        uint256 amt = uint256(bytes32(data[20:52]));

        // mitigate unknown assets being locked in positions
        if (!isKnownAsset[asset]) revert PositionManager_DepositUnknownAsset(asset);

        IERC20(asset).safeTransferFrom(msg.sender, position, amt);
        emit Deposit(position, msg.sender, asset, amt);
    }

    /// @dev Approve a spender to use assets from a position
    function approve(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(address, address, uint256)
        // spender -> [0:20] address to be approved
        // asset -> [20:40] address of token to be approves
        // amt -> [40:72] amount of asset to be approved
        address spender = address(bytes20(data[0:20]));
        address asset = address(bytes20(data[20:40]));
        uint256 amt = uint256(bytes32(data[40:72]));

        if (!isKnownAsset[asset]) revert PositionManager_ApproveUnknownAsset(asset);
        if (!isKnownSpender[spender]) revert PositionManager_UnknownSpender(spender);

        // if the passed amt is type(uint).max assume approval of the entire balance
        if (amt == type(uint256).max) amt = IERC20(asset).balanceOf(position);

        Position(payable(position)).approve(asset, spender, amt);
        emit Approve(position, msg.sender, spender, asset, amt);
    }

    /// @dev Decrease position debt via repayment. To repay the entire debt set `_amt` to uint.max
    function repay(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(uint256, uint256)
        // poolId -> [0:32] pool that recieves the repaid debt
        // amt -> [32: 64] notional amount to be repaid
        uint256 poolId = uint256(bytes32(data[0:32]));
        uint256 amt = uint256(bytes32(data[32:64]));

        // if the passed amt is type(uint).max assume repayment of the entire debt
        if (amt == type(uint256).max) amt = pool.getBorrowsOf(poolId, position);

        // transfer assets to be repaid from the position to the given pool
        Position(payable(position)).transfer(address(pool), pool.getPoolAssetFor(poolId), amt);

        // trigger pool repayment which assumes successful transfer of repaid assets
        pool.repay(poolId, position, amt);

        // signals repayment to the position and removes the debt pool if completely paid off
        // any checks needed to validate repayment must be implemented in the position
        Position(payable(position)).repay(poolId, amt);
        emit Repay(position, msg.sender, poolId, amt);
    }

    /// @dev Increase position debt via borrowing
    function borrow(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(uint256, uint256)
        // poolId -> [0:32] pool to borrow from
        // amt -> [32:64] notional amount to be borrowed
        uint256 poolId = uint256(bytes32(data[0:32]));
        uint256 amt = uint256(bytes32(data[32:64]));

        // revert if the given pool does not exist
        if (pool.ownerOf(poolId) == address(0)) revert PositionManager_UnknownPool(poolId);

        // transfer borrowed assets from given pool to position
        // trigger pool borrow and increase debt owed by the position
        pool.borrow(poolId, position, amt);

        // signals a borrow operation without any actual transfer of borrowed assets
        // any checks needed to validate the borrow must be implemented in the position
        Position(payable(position)).borrow(poolId, amt);
        emit Borrow(position, msg.sender, poolId, amt);
    }

    /// @dev Add a token address to the set of position assets
    function addToken(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(address)
        // asset -> [0:20] address of asset to be registered as collateral
        address asset = address(bytes20(data[0:20]));

        // avoid interactions with unknown assets
        if (!isKnownAsset[asset]) revert PositionManager_AddUnknownToken(asset);

        Position(payable(position)).addToken(asset); // validation should be in the position contract
        emit AddToken(position, msg.sender, asset);
    }

    /// @dev Remove a token address from the set of position assets
    function removeToken(address position, bytes calldata data) internal {
        // data -> abi.encodePacked(address)
        // asset -> address of asset to be deregistered as collateral
        address asset = address(bytes20(data[0:20]));
        Position(payable(position)).removeToken(asset);
        emit RemoveToken(position, msg.sender, asset);
    }

    /// @notice Liquidate an unhealthy position
    /// @param position Position address
    /// @param debtData DebtData object for debts to be repaid
    /// @param assetData AssetData object for assets to be seized
    function liquidate(
        address position,
        DebtData[] calldata debtData,
        AssetData[] calldata assetData
    ) external nonReentrant {
        riskEngine.validateLiquidation(position, debtData, assetData);

        // liquidate
        _transferAssetsToLiquidator(position, assetData);
        _repayPositionDebt(position, debtData);

        // position should be within risk thresholds after liquidation
        if (!riskEngine.isPositionHealthy(position)) revert PositionManager_HealthCheckFailed(position);
        emit Liquidation(position, msg.sender, ownerOf[position]);
    }

    function liquidateBadDebt(address position) external onlyOwner {
        riskEngine.validateBadDebt(position);

        // transfer any remaining position assets to the PositionManager owner
        address[] memory positionAssets = Position(payable(position)).getPositionAssets();
        uint256 positionAssetsLength = positionAssets.length;
        for (uint256 i; i < positionAssetsLength; ++i) {
            uint256 amt = IERC20(positionAssets[i]).balanceOf(position);
            try Position(payable(position)).transfer(owner(), positionAssets[i], amt) { } catch { }
        }

        // clear all debt associated with the given position
        uint256[] memory debtPools = Position(payable(position)).getDebtPools();
        uint256 debtPoolsLength = debtPools.length;
        for (uint256 i; i < debtPoolsLength; ++i) {
            pool.rebalanceBadDebt(debtPools[i], position);
            Position(payable(position)).repay(debtPools[i], type(uint256).max);
        }
    }

    function _transferAssetsToLiquidator(address position, AssetData[] calldata assetData) internal {
        // transfer position assets to the liquidator and accrue protocol liquidation fees
        uint256 assetDataLength = assetData.length;
        for (uint256 i; i < assetDataLength; ++i) {
            // ensure assetData[i] is in the position asset list
            if (Position(payable(position)).hasAsset(assetData[i].asset) == false) {
                revert PositionManager_SeizeInvalidAsset(position, assetData[i].asset);
            }
            // compute fee amt
            // [ROUND] liquidation fee is rounded down, in favor of the liquidator
            uint256 fee = liquidationFee.mulDiv(assetData[i].amt, 1e18);
            // transfer fee amt to protocol
            Position(payable(position)).transfer(owner(), assetData[i].asset, fee);
            // transfer difference to the liquidator
            Position(payable(position)).transfer(msg.sender, assetData[i].asset, assetData[i].amt - fee);
        }
    }

    function _repayPositionDebt(address position, DebtData[] calldata debtData) internal {
        // sequentially repay position debts
        // assumes the position manager is approved to pull assets from the liquidator
        uint256 debtDataLength = debtData.length;
        for (uint256 i; i < debtDataLength; ++i) {
            uint256 poolId = debtData[i].poolId;
            address poolAsset = pool.getPoolAssetFor(poolId);
            uint256 amt = debtData[i].amt;
            if (amt == type(uint256).max) amt = pool.getBorrowsOf(poolId, position);
            // transfer debt asset from the liquidator to the pool
            IERC20(poolAsset).safeTransferFrom(msg.sender, address(pool), amt);
            // trigger pool repayment which assumes successful transfer of repaid assets
            pool.repay(poolId, position, amt);
            // update position to reflect repayment of debt by liquidator
            Position(payable(position)).repay(poolId, amt);
        }
    }

    /// @notice Set the position beacon used to point to the position implementation
    function setBeacon(address _positionBeacon) external onlyOwner {
        positionBeacon = _positionBeacon;
        emit BeaconSet(_positionBeacon);
    }

    /// @notice Set the protocol registry address
    function setRegistry(address _registry) external onlyOwner {
        registry = Registry(_registry);
        updateFromRegistry();
        emit RegistrySet(_registry);
    }

    /// @notice Update the protocol liquidation fee
    function setLiquidationFee(uint256 _liquidationFee) external onlyOwner {
        liquidationFee = _liquidationFee;
        emit LiquidationFeeSet(_liquidationFee);
    }

    /// @notice Toggle asset inclusion in the known asset universe
    function toggleKnownAsset(address asset) external onlyOwner {
        isKnownAsset[asset] = !isKnownAsset[asset];
        emit ToggleKnownAsset(asset, isKnownAsset[asset]);
    }

    /// @notice Toggle spender inclusion in the known spender universe
    function toggleKnownSpender(address spender) external onlyOwner {
        isKnownSpender[spender] = !isKnownSpender[spender];
        emit ToggleKnownSpender(spender, isKnownSpender[spender]);
    }

    /// @notice Toggle target-function pair inclusion in the known function universe
    function toggleKnownFunc(address target, bytes4 method) external onlyOwner {
        isKnownFunc[target][method] = !isKnownFunc[target][method];
        emit ToggleKnownFunc(target, method, isKnownFunc[target][method]);
    }
}
