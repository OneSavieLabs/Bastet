// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FixedPoint128.sol";

import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "permit2/interfaces/IPermit2.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IErrors.sol";

/// @title Revert Lend Vault for token lending / borrowing using Uniswap V3 LP positions as collateral
/// @notice The vault manages ONE ERC20 (eg. USDC) asset for lending / borrowing, but collateral positions can be composed of any 2 tokens configured each with a collateralFactor > 0
/// Vault implements IERC4626 Vault Standard and is itself a ERC20 which represent shares of total lending pool
contract V3Vault is ERC20, Multicall, Ownable, IVault, IERC721Receiver, IErrors {
    using Math for uint256;

    uint256 private constant Q32 = 2 ** 32;
    uint256 private constant Q96 = 2 ** 96;

    uint32 public constant MAX_COLLATERAL_FACTOR_X32 = uint32(Q32 * 90 / 100); // 90%

    uint32 public constant MIN_LIQUIDATION_PENALTY_X32 = uint32(Q32 * 2 / 100); // 2%
    uint32 public constant MAX_LIQUIDATION_PENALTY_X32 = uint32(Q32 * 10 / 100); // 10%

    uint32 public constant MIN_RESERVE_PROTECTION_FACTOR_X32 = uint32(Q32 / 100); //1%

    uint32 public constant MAX_DAILY_LEND_INCREASE_X32 = uint32(Q32 / 10); //10%
    uint32 public constant MAX_DAILY_DEBT_INCREASE_X32 = uint32(Q32 / 10); //10%

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Uniswap v3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice interest rate model implementation
    IInterestRateModel public immutable interestRateModel;

    /// @notice oracle implementation
    IV3Oracle public immutable oracle;

    /// @notice permit2 contract
    IPermit2 public immutable permit2;

    /// @notice underlying asset for lending / borrowing
    address public immutable override asset;

    /// @notice decimals of underlying token (are the same as ERC20 share token)
    uint8 private immutable assetDecimals;

    // events
    event ApprovedTransform(uint256 indexed tokenId, address owner, address target, bool isActive);

    event Add(uint256 indexed tokenId, address owner, uint256 oldTokenId); // when a token is added replacing another token - oldTokenId > 0
    event Remove(uint256 indexed tokenId, address recipient);

    event ExchangeRateUpdate(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96);
    // Deposit and Withdraw events are defined in IERC4626
    event WithdrawCollateral(
        uint256 indexed tokenId, address owner, address recipient, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event Borrow(uint256 indexed tokenId, address owner, uint256 assets, uint256 shares);
    event Repay(uint256 indexed tokenId, address repayer, address owner, uint256 assets, uint256 shares);
    event Liquidate(
        uint256 indexed tokenId,
        address liquidator,
        address owner,
        uint256 value,
        uint256 cost,
        uint256 amount0,
        uint256 amount1,
        uint256 reserve,
        uint256 missing
    ); // shows exactly how liquidation amounts were divided

    // admin events
    event WithdrawReserves(uint256 amount, address receiver);
    event SetTransformer(address transformer, bool active);
    event SetLimits(
        uint256 minLoanSize,
        uint256 globalLendLimit,
        uint256 globalDebtLimit,
        uint256 dailyLendIncreaseLimitMin,
        uint256 dailyDebtIncreaseLimitMin
    );
    event SetReserveFactor(uint32 reserveFactorX32);
    event SetReserveProtectionFactor(uint32 reserveProtectionFactorX32);
    event SetTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32);

    event SetEmergencyAdmin(address emergencyAdmin);

    // configured tokens
    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint32 collateralValueLimitFactorX32; // how much asset equivalent may be lent out given this collateral
        uint192 totalDebtShares; // how much debt shares are theoretically backed by this collateral
    }

    mapping(address => TokenConfig) public tokenConfigs;

    // percentage of interest which is kept in the protocol for reserves
    uint32 public reserveFactorX32 = 0;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 public reserveProtectionFactorX32 = MIN_RESERVE_PROTECTION_FACTOR_X32;

    // total of debt shares - increases when borrow - decreases when repay
    uint256 public debtSharesTotal = 0;

    // exchange rates are Q96 at the beginning - 1 share token per 1 asset token
    uint256 public lastExchangeRateUpdate = 0;
    uint256 public lastDebtExchangeRateX96 = Q96;
    uint256 public lastLendExchangeRateX96 = Q96;

    uint256 public globalDebtLimit = 0;
    uint256 public globalLendLimit = 0;

    // minimal size of loan (to protect from non-liquidatable positions because of gas-cost)
    uint256 public minLoanSize = 0;

    // daily lend increase limit handling
    uint256 public dailyLendIncreaseLimitMin = 0;
    uint256 public dailyLendIncreaseLimitLeft = 0;
    uint256 public dailyLendIncreaseLimitLastReset = 0;

    // daily debt increase limit handling
    uint256 public dailyDebtIncreaseLimitMin = 0;
    uint256 public dailyDebtIncreaseLimitLeft = 0;
    uint256 public dailyDebtIncreaseLimitLastReset = 0;

    // lender balances are handled with ERC-20 mint/burn

    // loans are handled with this struct
    struct Loan {
        uint256 debtShares;
    }

    mapping(uint256 => Loan) public loans; // tokenID -> loan mapping

    // storage variables to handle enumerable token ownership
    mapping(address => uint256[]) private ownedTokens; // Mapping from owner address to list of owned token IDs
    mapping(uint256 => uint256) private ownedTokensIndex; // Mapping from token ID to index of the owner tokens list (for removal without loop)
    mapping(uint256 => address) private tokenOwner; // Mapping from token ID to owner

    uint256 private transformedTokenId = 0; // transient storage (when available in dencun)

    mapping(address => bool) public transformerAllowList; // contracts allowed to transform positions (selected audited contracts e.g. V3Utils)
    mapping(address => mapping(uint256 => mapping(address => bool))) public transformApprovals; // owners permissions for other addresses to call transform on owners behalf (e.g. AutoRange contract)

    // address which can call special emergency actions without timelock
    address public emergencyAdmin;

    constructor(
        string memory name,
        string memory symbol,
        address _asset,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IInterestRateModel _interestRateModel,
        IV3Oracle _oracle,
        IPermit2 _permit2
    ) ERC20(name, symbol) {
        asset = _asset;
        assetDecimals = IERC20Metadata(_asset).decimals();
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        interestRateModel = _interestRateModel;
        oracle = _oracle;
        permit2 = _permit2;
    }

    ////////////////// EXTERNAL VIEW FUNCTIONS

    /// @notice Retrieves global information about the vault
    /// @return debt Total amount of debt asset tokens
    /// @return lent Total amount of lent asset tokens
    /// @return balance Balance of asset token in contract
    /// @return available Available balance of asset token in contract (balance - reserves)
    /// @return reserves Amount of reserves
    function vaultInfo()
        external
        view
        override
        returns (
            uint256 debt,
            uint256 lent,
            uint256 balance,
            uint256 available,
            uint256 reserves,
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        )
    {
        (debtExchangeRateX96, lendExchangeRateX96) = _calculateGlobalInterest();
        (balance, available, reserves) = _getAvailableBalance(debtExchangeRateX96, lendExchangeRateX96);

        debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Up);
        lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
    }

    /// @notice Retrieves lending information for a specified account.
    /// @param account The address of the account for which lending info is requested.
    /// @return amount Amount of lent assets for the account
    function lendInfo(address account) external view override returns (uint256 amount) {
        (, uint256 newLendExchangeRateX96) = _calculateGlobalInterest();
        amount = _convertToAssets(balanceOf(account), newLendExchangeRateX96, Math.Rounding.Down);
    }

    /// @notice Retrieves details of a loan identified by its token ID.
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV3 Position
    /// @return debt Amount of debt for this position
    /// @return fullValue Current value of the position priced as asset token
    /// @return collateralValue Current collateral value of the position priced as asset token
    /// @return liquidationCost If position is liquidatable - cost to liquidate position - otherwise 0
    /// @return liquidationValue If position is liquidatable - the value of the (partial) position which the liquidator recieves - otherwise 0
    function loanInfo(uint256 tokenId)
        external
        view
        override
        returns (
            uint256 debt,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 liquidationCost,
            uint256 liquidationValue
        )
    {
        (uint256 newDebtExchangeRateX96,) = _calculateGlobalInterest();

        debt = _convertToAssets(loans[tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);

        bool isHealthy;
        (isHealthy, fullValue, collateralValue,) = _checkLoanIsHealthy(tokenId, debt);

        if (!isHealthy) {
            (liquidationValue, liquidationCost,) = _calculateLiquidation(debt, fullValue, collateralValue);
        }
    }

    /// @notice Retrieves owner of a loan
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV3 Position
    /// @return owner Owner of the loan
    function ownerOf(uint256 tokenId) external view override returns (address owner) {
        return tokenOwner[tokenId];
    }

    /// @notice Retrieves count of loans for owner (for enumerating owners loans)
    /// @param owner Owner address
    function loanCount(address owner) external view override returns (uint256) {
        return ownedTokens[owner].length;
    }

    /// @notice Retrieves tokenid of loan at given index for owner (for enumerating owners loans)
    /// @param owner Owner address
    /// @param index Index
    function loanAtIndex(address owner, uint256 index) external view override returns (uint256) {
        return ownedTokens[owner][index];
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC20
    /// @inheritdoc IERC20Metadata
    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        return assetDecimals;
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
        if (value >= globalLendLimit) {
            return 0;
        } else {
            return globalLendLimit - value;
        }
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
        if (value >= globalLendLimit) {
            return 0;
        } else {
            return _convertToShares(globalLendLimit - value, lendExchangeRateX96, Math.Rounding.Down);
        }
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(balanceOf(owner), lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Up);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Down);
    }

    ////////////////// OVERRIDDEN EXTERNAL FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false, "");
        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external override returns (uint256) {
        (uint256 assets,) = _deposit(receiver, shares, true, "");
        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        (, uint256 shares) = _withdraw(receiver, owner, assets, false);
        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        (uint256 assets,) = _withdraw(receiver, owner, shares, true);
        return assets;
    }

    // deposit using permit2 data
    function deposit(uint256 assets, address receiver, bytes calldata permitData) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false, permitData);
        return shares;
    }

    // mint using permit2 data
    function mint(uint256 shares, address receiver, bytes calldata permitData) external override returns (uint256) {
        (uint256 assets,) = _deposit(receiver, shares, true, permitData);
        return assets;
    }

    ////////////////// EXTERNAL FUNCTIONS

    /// @notice Creates a new collateralized position (transfer approved position)
    /// @param tokenId The token ID associated with the new position.
    /// @param recipient Address to recieve the position in the vault
    function create(uint256 tokenId, address recipient) external override {
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Creates a new collateralized position with a permit for token spending (transfer position with permit)
    /// @param tokenId The token ID associated with the new position.
    /// @param owner Current owner of the position (signature owner)
    /// @param recipient Address to recieve the position in the vault
    /// @param deadline Timestamp until which the permit is valid.
    /// @param v, r, s Components of the signature for the permit.
    function createWithPermit(
        uint256 tokenId,
        address owner,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        nonfungiblePositionManager.permit(address(this), tokenId, deadline, v, r, s);
        nonfungiblePositionManager.safeTransferFrom(owner, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Whenever a token is recieved it either creates a new loan, or modifies an existing one when in transform mode.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        // only Uniswap v3 NFTs allowed - sent from other contract
        if (msg.sender != address(nonfungiblePositionManager) || from == address(this)) {
            revert WrongContract();
        }

        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _updateGlobalInterest();

        if (transformedTokenId == 0) {
            address owner = from;
            if (data.length > 0) {
                owner = abi.decode(data, (address));
            }
            loans[tokenId] = Loan(0);

            _addTokenToOwner(owner, tokenId);
            emit Add(tokenId, owner, 0);
        } else {
            uint256 oldTokenId = transformedTokenId;

            // if in transform mode - and a new position is sent - current position is replaced and returned
            if (tokenId != oldTokenId) {
                address owner = tokenOwner[oldTokenId];

                // set transformed token to new one
                transformedTokenId = tokenId;

                // copy debt to new token
                loans[tokenId] = Loan(loans[oldTokenId].debtShares);

                _addTokenToOwner(owner, tokenId);
                emit Add(tokenId, owner, oldTokenId);

                // clears data of old loan
                _cleanupLoan(oldTokenId, debtExchangeRateX96, lendExchangeRateX96, owner);

                // sets data of new loan
                _updateAndCheckCollateral(
                    tokenId, debtExchangeRateX96, lendExchangeRateX96, 0, loans[tokenId].debtShares
                );
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Allows another address to call transform on behalf of owner (on a given token)
    /// @param tokenId The token to be permitted
    /// @param target The address to be allowed
    /// @param isActive If it allowed or not
    function approveTransform(uint256 tokenId, address target, bool isActive) external override {
        if (tokenOwner[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = isActive;

        emit ApprovedTransform(tokenId, msg.sender, target, isActive);
    }

    /// @notice Method which allows a contract to transform a loan by changing it (and only at the end checking collateral)
    /// @param tokenId The token ID to be processed
    /// @param transformer The address of a whitelisted transformer contract
    /// @param data Encoded transformation params
    /// @return newTokenId Final token ID (may be different than input token ID when the position was replaced by transformation)
    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        returns (uint256 newTokenId)
    {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId > 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        address loanOwner = tokenOwner[tokenId];

        // only the owner of the loan, the vault itself or any approved caller can call this
        if (loanOwner != msg.sender && !transformApprovals[loanOwner][tokenId][msg.sender]) {
            revert Unauthorized();
        }

        // give access to transformer
        nonfungiblePositionManager.approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }

        // may have changed in the meantime
        tokenId = transformedTokenId;

        // check owner not changed (NEEDED because token could have been moved somewhere else in the meantime)
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != address(this)) {
            revert Unauthorized();
        }

        // remove access for transformer
        nonfungiblePositionManager.approve(address(0), tokenId);

        uint256 debt = _convertToAssets(loans[tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);
        _requireLoanIsHealthy(tokenId, debt);

        transformedTokenId = 0;

        return tokenId;
    }

    /// @notice Borrows specified amount using token as collateral
    /// @param tokenId The token ID to use as collateral
    /// @param assets How much assets to borrow
    function borrow(uint256 tokenId, uint256 assets) external override {
        bool isTransformMode =
            transformedTokenId > 0 && transformedTokenId == tokenId && transformerAllowList[msg.sender];

        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        Loan storage loan = loans[tokenId];

        // if not in transfer mode - must be called from owner or the vault itself
        if (!isTransformMode && tokenOwner[tokenId] != msg.sender && address(this) != msg.sender) {
            revert Unauthorized();
        }

        uint256 shares = _convertToShares(assets, newDebtExchangeRateX96, Math.Rounding.Up);

        uint256 loanDebtShares = loan.debtShares + shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal += shares;

        if (debtSharesTotal > _convertToShares(globalDebtLimit, newDebtExchangeRateX96, Math.Rounding.Down)) {
            revert GlobalDebtLimit();
        }
        if (assets > dailyDebtIncreaseLimitLeft) {
            revert DailyDebtIncreaseLimit();
        } else {
            dailyDebtIncreaseLimitLeft -= assets;
        }

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares - shares, loanDebtShares
        );

        uint256 debt = _convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Up);

        if (debt < minLoanSize) {
            revert MinLoanSize();
        }

        // only does check health here if not in transform mode
        if (!isTransformMode) {
            _requireLoanIsHealthy(tokenId, debt);
        }

        address owner = tokenOwner[tokenId];

        // fails if not enough asset available
        // if called from transform mode - send funds to transformer contract
        SafeERC20.safeTransfer(IERC20(asset), isTransformMode ? msg.sender : owner, assets);

        emit Borrow(tokenId, owner, assets, shares);
    }

    /// @dev Decreases the liquidity of a given position and collects the resultant assets (and possibly additional fees)
    /// This function is not allowed during transformation (if a transformer wants to decreaseLiquidity he can call the methods directly on the NonfungiblePositionManager)
    /// @param params Struct containing various parameters for the operation. Includes tokenId, liquidity amount, minimum asset amounts, and deadline.
    /// @return amount0 The amount of the first type of asset collected.
    /// @return amount1 The amount of the second type of asset collected.
    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        // this method is not allowed during transform - can be called directly on nftmanager if needed from transform contract
        if (transformedTokenId > 0) {
            revert TransformNotAllowed();
        }

        address owner = tokenOwner[params.tokenId];

        if (owner != msg.sender) {
            revert Unauthorized();
        }

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                params.tokenId, params.liquidity, params.amount0Min, params.amount1Min, params.deadline
            )
        );

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams(
            params.tokenId,
            params.recipient,
            params.feeAmount0 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount0 + params.feeAmount0),
            params.feeAmount1 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount1 + params.feeAmount1)
        );

        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);

        uint256 debt = _convertToAssets(loans[params.tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Up);
        _requireLoanIsHealthy(params.tokenId, debt);

        emit WithdrawCollateral(params.tokenId, owner, params.recipient, params.liquidity, amount0, amount1);
    }

    /// @notice Repays borrowed tokens. Can be denominated in assets or debt share amount
    /// @param tokenId The token ID to use as collateral
    /// @param amount How many assets/debt shares to repay
    /// @param isShare Is amount specified in assets or debt shares.
    function repay(uint256 tokenId, uint256 amount, bool isShare) external override {
        _repay(tokenId, amount, isShare, "");
    }

    /// @notice Repays borrowed tokens. Can be denominated in assets or debt share amount
    /// @param tokenId The token ID to use as collateral
    /// @param amount How many assets/debt shares to repay
    /// @param isShare Is amount specified in assets or debt shares.
    /// @param permitData Permit2 data and signature
    function repay(uint256 tokenId, uint256 amount, bool isShare, bytes calldata permitData) external override {
        _repay(tokenId, amount, isShare, permitData);
    }

    // state used in liquidation function to avoid stack too deep errors
    struct LiquidateState {
        uint256 newDebtExchangeRateX96;
        uint256 newLendExchangeRateX96;
        uint256 debt;
        bool isHealthy;
        uint256 liquidationValue;
        uint256 liquidatorCost;
        uint256 reserveCost;
        uint256 missing;
        uint256 fullValue;
        uint256 collateralValue;
        uint256 feeValue;
    }

    /// @notice Liquidates position - needed assets are depending on current price.
    /// Sufficient assets need to be approved to the contract for the liquidation to succeed.
    /// @param params The params defining liquidation
    /// @return amount0 The amount of the first type of asset collected.
    /// @return amount1 The amount of the second type of asset collected.
    function liquidate(LiquidateParams calldata params) external override returns (uint256 amount0, uint256 amount1) {
        // liquidation is not allowed during transformer mode
        if (transformedTokenId > 0) {
            revert TransformNotAllowed();
        }

        LiquidateState memory state;

        (state.newDebtExchangeRateX96, state.newLendExchangeRateX96) = _updateGlobalInterest();

        uint256 debtShares = loans[params.tokenId].debtShares;
        if (debtShares != params.debtShares) {
            revert DebtChanged();
        }

        state.debt = _convertToAssets(debtShares, state.newDebtExchangeRateX96, Math.Rounding.Up);

        (state.isHealthy, state.fullValue, state.collateralValue, state.feeValue) =
            _checkLoanIsHealthy(params.tokenId, state.debt);
        if (state.isHealthy) {
            revert NotLiquidatable();
        }

        (state.liquidationValue, state.liquidatorCost, state.reserveCost) =
            _calculateLiquidation(state.debt, state.fullValue, state.collateralValue);

        // calculate reserve (before transfering liquidation money - otherwise calculation is off)
        if (state.reserveCost > 0) {
            state.missing =
                _handleReserveLiquidation(state.reserveCost, state.newDebtExchangeRateX96, state.newLendExchangeRateX96);
        }

        if (params.permitData.length > 0) {
            (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
                abi.decode(params.permitData, (ISignatureTransfer.PermitTransferFrom, bytes));
            permit2.permitTransferFrom(
                permit,
                ISignatureTransfer.SignatureTransferDetails(address(this), state.liquidatorCost),
                msg.sender,
                signature
            );
        } else {
            // take value from liquidator
            SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), state.liquidatorCost);
        }

        debtSharesTotal -= debtShares;

        // send promised collateral tokens to liquidator
        (amount0, amount1) =
            _sendPositionValue(params.tokenId, state.liquidationValue, state.fullValue, state.feeValue, msg.sender);

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageError();
        }

        address owner = tokenOwner[params.tokenId];

        // disarm loan and send remaining position to owner
        _cleanupLoan(params.tokenId, state.newDebtExchangeRateX96, state.newLendExchangeRateX96, owner);

        emit Liquidate(
            params.tokenId,
            msg.sender,
            owner,
            state.fullValue,
            state.liquidatorCost,
            amount0,
            amount1,
            state.reserveCost,
            state.missing
        );
    }

    ////////////////// ADMIN FUNCTIONS only callable by owner

    /// @notice withdraw protocol reserves (onlyOwner)
    /// only allows to withdraw excess reserves (> globalLendAmount * reserveProtectionFactor)
    /// @param amount amount to withdraw
    /// @param receiver receiver address
    function withdrawReserves(uint256 amount, address receiver) external onlyOwner {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        uint256 protected =
            _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up) * reserveProtectionFactorX32 / Q32;
        (uint256 balance,, uint256 reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);
        uint256 unprotected = reserves > protected ? reserves - protected : 0;
        uint256 available = balance > unprotected ? unprotected : balance;

        if (amount > available) {
            revert InsufficientLiquidity();
        }

        if (amount > 0) {
            SafeERC20.safeTransfer(IERC20(asset), receiver, amount);
        }

        emit WithdrawReserves(amount, receiver);
    }

    /// @notice configure transformer contract (onlyOwner)
    /// @param transformer address of transformer contract
    /// @param active should the transformer be active?
    function setTransformer(address transformer, bool active) external onlyOwner {
        // protects protocol from owner trying to set dangerous transformer
        if (
            transformer == address(0) || transformer == address(this) || transformer == asset
                || transformer == address(nonfungiblePositionManager)
        ) {
            revert InvalidConfig();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    /// @notice set limits (this doesnt affect existing loans) - this method can be called by owner OR emergencyAdmin
    /// @param _minLoanSize min size of a loan - trying to create smaller loans will revert
    /// @param _globalLendLimit global limit of lent amount
    /// @param _globalDebtLimit global limit of debt amount
    /// @param _dailyLendIncreaseLimitMin min daily increasable amount of lent amount
    /// @param _dailyDebtIncreaseLimitMin min daily increasable amount of debt amount
    function setLimits(
        uint256 _minLoanSize,
        uint256 _globalLendLimit,
        uint256 _globalDebtLimit,
        uint256 _dailyLendIncreaseLimitMin,
        uint256 _dailyDebtIncreaseLimitMin
    ) external {
        if (msg.sender != emergencyAdmin && msg.sender != owner()) {
            revert Unauthorized();
        }

        minLoanSize = _minLoanSize;
        globalLendLimit = _globalLendLimit;
        globalDebtLimit = _globalDebtLimit;
        dailyLendIncreaseLimitMin = _dailyLendIncreaseLimitMin;
        dailyDebtIncreaseLimitMin = _dailyDebtIncreaseLimitMin;

        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        // force reset daily limits with new values
        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, true);
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, true);

        emit SetLimits(
            _minLoanSize, _globalLendLimit, _globalDebtLimit, _dailyLendIncreaseLimitMin, _dailyDebtIncreaseLimitMin
        );
    }

    /// @notice sets reserve factor - percentage difference between debt and lend interest (onlyOwner)
    /// @param _reserveFactorX32 reserve factor multiplied by Q32
    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {
        reserveFactorX32 = _reserveFactorX32;
        emit SetReserveFactor(_reserveFactorX32);
    }

    /// @notice sets reserve protection factor - percentage of globalLendAmount which can't be withdrawn by owner (onlyOwner)
    /// @param _reserveProtectionFactorX32 reserve protection factor multiplied by Q32
    function setReserveProtectionFactor(uint32 _reserveProtectionFactorX32) external onlyOwner {
        if (_reserveProtectionFactorX32 < MIN_RESERVE_PROTECTION_FACTOR_X32) {
            revert InvalidConfig();
        }
        reserveProtectionFactorX32 = _reserveProtectionFactorX32;
        emit SetReserveProtectionFactor(_reserveProtectionFactorX32);
    }

    /// @notice Sets or updates the configuration for a token (onlyOwner)
    /// @param token Token to configure
    /// @param collateralFactorX32 collateral factor for this token mutiplied by Q32
    /// @param collateralValueLimitFactorX32 how much of it maybe used as collateral measured as percentage of total lent assets mutiplied by Q32
    function setTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32)
        external
        onlyOwner
    {
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR_X32) {
            revert CollateralFactorExceedsMax();
        }
        tokenConfigs[token].collateralFactorX32 = collateralFactorX32;
        tokenConfigs[token].collateralValueLimitFactorX32 = collateralValueLimitFactorX32;
        emit SetTokenConfig(token, collateralFactorX32, collateralValueLimitFactorX32);
    }

    /// @notice Updates emergency admin address (onlyOwner)
    /// @param admin Emergency admin address
    function setEmergencyAdmin(address admin) external onlyOwner {
        emergencyAdmin = admin;
        emit SetEmergencyAdmin(admin);
    }

    ////////////////// INTERNAL FUNCTIONS

    function _deposit(address receiver, uint256 amount, bool isShare, bytes memory permitData)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(shares, newLendExchangeRateX96, Math.Rounding.Up);
        } else {
            assets = amount;
            shares = _convertToShares(assets, newLendExchangeRateX96, Math.Rounding.Down);
        }

        if (permitData.length > 0) {
            (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
                abi.decode(permitData, (ISignatureTransfer.PermitTransferFrom, bytes));
            permit2.permitTransferFrom(
                permit, ISignatureTransfer.SignatureTransferDetails(address(this), assets), msg.sender, signature
            );
        } else {
            // fails if not enough token approved
            SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);
        }

        _mint(receiver, shares);

        if (totalSupply() > globalLendLimit) {
            revert GlobalLendLimit();
        }

        if (assets > dailyLendIncreaseLimitLeft) {
            revert DailyLendIncreaseLimit();
        } else {
            dailyLendIncreaseLimitLeft -= assets;
        }

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // withdraws lent tokens. can be denominated in token or share amount
    function _withdraw(address receiver, address owner, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newLendExchangeRateX96, Math.Rounding.Down);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newLendExchangeRateX96, Math.Rounding.Up);
        }

        // if caller has allowance for owners shares - may call withdraw
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (, uint256 available,) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);
        if (available < assets) {
            revert InsufficientLiquidity();
        }

        // fails if not enough shares
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        // when amounts are withdrawn - they may be deposited again
        dailyLendIncreaseLimitLeft += assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _repay(uint256 tokenId, uint256 amount, bool isShare, bytes memory permitData) internal {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        Loan storage loan = loans[tokenId];

        uint256 currentShares = loan.debtShares;

        uint256 shares;
        uint256 assets;

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newDebtExchangeRateX96, Math.Rounding.Up);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newDebtExchangeRateX96, Math.Rounding.Down);
        }

        // fails if too much repayed
        if (shares > currentShares) {
            revert RepayExceedsDebt();
        }

        if (assets > 0) {
            if (permitData.length > 0) {
                (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
                    abi.decode(permitData, (ISignatureTransfer.PermitTransferFrom, bytes));
                permit2.permitTransferFrom(
                    permit, ISignatureTransfer.SignatureTransferDetails(address(this), assets), msg.sender, signature
                );
            } else {
                // fails if not enough token approved
                SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);
            }
        }

        uint256 loanDebtShares = loan.debtShares - shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal -= shares;

        // when amounts are repayed - they maybe borrowed again
        dailyDebtIncreaseLimitLeft += assets;

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares + shares, loanDebtShares
        );

        address owner = tokenOwner[tokenId];

        // if fully repayed
        if (currentShares == shares) {
            _cleanupLoan(tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, owner);
        } else {
            // if resulting loan is too small - revert
            if (_convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Up) < minLoanSize) {
                revert MinLoanSize();
            }
        }

        emit Repay(tokenId, msg.sender, owner, assets, shares);
    }

    // checks how much balance is available - excluding reserves
    function _getAvailableBalance(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96)
        internal
        view
        returns (uint256 balance, uint256 available, uint256 reserves)
    {
        balance = totalAssets();

        uint256 debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Up);
        uint256 lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Down);

        reserves = balance + debt > lent ? balance + debt - lent : 0;
        available = balance > reserves ? balance - reserves : 0;
    }

    // removes correct amount from position to send to liquidator
    function _sendPositionValue(
        uint256 tokenId,
        uint256 liquidationValue,
        uint256 fullValue,
        uint256 feeValue,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint128 liquidity;
        uint128 fees0;
        uint128 fees1;

        // if full position is liquidated - no analysis needed
        if (liquidationValue == fullValue) {
            (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
            fees0 = type(uint128).max;
            fees1 = type(uint128).max;
        } else {
            (,,, liquidity,,, fees0, fees1) = oracle.getPositionBreakdown(tokenId);

            // only take needed fees
            if (liquidationValue < feeValue) {
                liquidity = 0;
                fees0 = uint128(liquidationValue * fees0 / feeValue);
                fees1 = uint128(liquidationValue * fees1 / feeValue);
            } else {
                // take all fees and needed liquidity
                fees0 = type(uint128).max;
                fees1 = type(uint128).max;
                liquidity = uint128((liquidationValue - feeValue) * liquidity / (fullValue - feeValue));
            }
        }

        if (liquidity > 0) {
            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, block.timestamp)
            );
        }

        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, recipient, fees0, fees1)
        );
    }

    // cleans up loan when it is closed because of replacement, repayment or liquidation
    // send the position in its current state to owner
    function _cleanupLoan(uint256 tokenId, uint256 debtExchangeRateX96, uint256 lendExchangeRateX96, address owner)
        internal
    {
        _removeTokenFromOwner(owner, tokenId);
        _updateAndCheckCollateral(tokenId, debtExchangeRateX96, lendExchangeRateX96, loans[tokenId].debtShares, 0);
        delete loans[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), owner, tokenId);
        emit Remove(tokenId, owner);
    }

    // calculates amount which needs to be payed to liquidate position
    //  if position is too valuable - not all of the position is liquididated - only needed amount
    //  if position is not valuable enough - missing part is covered by reserves - if not enough reserves - collectively by other borrowers
    function _calculateLiquidation(uint256 debt, uint256 fullValue, uint256 collateralValue)
        internal
        pure
        returns (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost)
    {
        // in a standard liquidation - liquidator pays complete debt (and get part or all of position)
        // if position has less than enough value - liquidation cost maybe less - rest is payed by protocol or lenders collectively
        liquidatorCost = debt;

        // position value needed to pay debt at max penalty
        uint256 maxPenaltyValue = debt * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;

        // if position is more valuable than debt with max penalty
        if (fullValue >= maxPenaltyValue) {
            // position value when position started to be liquidatable
            uint256 startLiquidationValue = debt * fullValue / collateralValue;
            uint256 penaltyFractionX96 =
                (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (startLiquidationValue - maxPenaltyValue)));
            uint256 penaltyX32 = MIN_LIQUIDATION_PENALTY_X32
                + (MAX_LIQUIDATION_PENALTY_X32 - MIN_LIQUIDATION_PENALTY_X32) * penaltyFractionX96 / Q96;

            liquidationValue = debt * (Q32 + penaltyX32) / Q32;
        } else {
            // all position value
            liquidationValue = fullValue;

            uint256 penaltyValue = fullValue * (Q32 - MAX_LIQUIDATION_PENALTY_X32) / Q32;
            liquidatorCost = penaltyValue;
            reserveCost = debt - penaltyValue;
        }
    }

    // calculates if there are enough reserves to cover liquidaton - if not its shared between lenders
    function _handleReserveLiquidation(
        uint256 reserveCost,
        uint256 newDebtExchangeRateX96,
        uint256 newLendExchangeRateX96
    ) internal returns (uint256 missing) {
        (,, uint256 reserves) = _getAvailableBalance(newDebtExchangeRateX96, newLendExchangeRateX96);

        // if not enough - democratize debt
        if (reserveCost > reserves) {
            missing = reserveCost - reserves;

            uint256 totalLent = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up);

            // this lines distribute missing amount and remove it from all lent amount proportionally
            newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        }
    }

    function _calculateTokenCollateralFactorX32(uint256 tokenId) internal view returns (uint32) {
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint32 factor0X32 = tokenConfigs[token0].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[token1].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
    }

    function _updateGlobalInterest()
        internal
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        // only needs to be updated once per block (when needed)
        if (block.timestamp > lastExchangeRateUpdate) {
            (newDebtExchangeRateX96, newLendExchangeRateX96) = _calculateGlobalInterest();
            lastDebtExchangeRateX96 = newDebtExchangeRateX96;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            lastExchangeRateUpdate = block.timestamp;
            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        } else {
            newDebtExchangeRateX96 = lastDebtExchangeRateX96;
            newLendExchangeRateX96 = lastLendExchangeRateX96;
        }
    }

    function _calculateGlobalInterest()
        internal
        view
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        uint256 oldDebtExchangeRateX96 = lastDebtExchangeRateX96;
        uint256 oldLendExchangeRateX96 = lastLendExchangeRateX96;

        (, uint256 available,) = _getAvailableBalance(oldDebtExchangeRateX96, oldLendExchangeRateX96);

        uint256 debt = _convertToAssets(debtSharesTotal, oldDebtExchangeRateX96, Math.Rounding.Up);

        (uint256 borrowRateX96, uint256 supplyRateX96) = interestRateModel.getRatesPerSecondX96(available, debt);

        supplyRateX96 = supplyRateX96.mulDiv(Q32 - reserveFactorX32, Q32);

        // always growing or equal
        uint256 lastRateUpdate = lastExchangeRateUpdate;

        if (lastRateUpdate > 0) {
            newDebtExchangeRateX96 = oldDebtExchangeRateX96
                + oldDebtExchangeRateX96 * (block.timestamp - lastRateUpdate) * borrowRateX96 / Q96;
            newLendExchangeRateX96 = oldLendExchangeRateX96
                + oldLendExchangeRateX96 * (block.timestamp - lastRateUpdate) * supplyRateX96 / Q96;
        } else {
            newDebtExchangeRateX96 = oldDebtExchangeRateX96;
            newLendExchangeRateX96 = oldLendExchangeRateX96;
        }
    }

    function _requireLoanIsHealthy(uint256 tokenId, uint256 debt) internal view {
        (bool isHealthy,,,) = _checkLoanIsHealthy(tokenId, debt);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    // updates collateral token configs - and check if limit is not surpassed (check is only done on increasing debt shares)
    function _updateAndCheckCollateral(
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96,
        uint256 oldShares,
        uint256 newShares
    ) internal {
        if (oldShares != newShares) {
            (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

            // remove previous collateral - add new collateral
            if (oldShares > newShares) {
                tokenConfigs[token0].totalDebtShares -= SafeCast.toUint192(oldShares - newShares);
                tokenConfigs[token1].totalDebtShares -= SafeCast.toUint192(oldShares - newShares);
            } else {
                tokenConfigs[token0].totalDebtShares += SafeCast.toUint192(newShares - oldShares);
                tokenConfigs[token1].totalDebtShares += SafeCast.toUint192(newShares - oldShares);

                // check if current value of used collateral is more than allowed limit
                // if collateral is decreased - never revert
                uint256 lentAssets = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Up);
                uint256 collateralValueLimitFactorX32 = tokenConfigs[token0].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token0].totalDebtShares, debtExchangeRateX96, Math.Rounding.Up)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
                collateralValueLimitFactorX32 = tokenConfigs[token1].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token1].totalDebtShares, debtExchangeRateX96, Math.Rounding.Up)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
            }
        }
    }

    function _resetDailyLendIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        // daily lend limit reset handling
        uint256 time = block.timestamp / 1 days;
        if (force || time > dailyLendIncreaseLimitLastReset) {
            uint256 lendIncreaseLimit = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up)
                * (Q32 + MAX_DAILY_LEND_INCREASE_X32) / Q32;
            dailyLendIncreaseLimitLeft =
                dailyLendIncreaseLimitMin > lendIncreaseLimit ? dailyLendIncreaseLimitMin : lendIncreaseLimit;
            dailyLendIncreaseLimitLastReset = time;
        }
    }

    function _resetDailyDebtIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        // daily debt limit reset handling
        uint256 time = block.timestamp / 1 days;
        if (force || time > dailyDebtIncreaseLimitLastReset) {
            uint256 debtIncreaseLimit = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up)
                * (Q32 + MAX_DAILY_DEBT_INCREASE_X32) / Q32;
            dailyDebtIncreaseLimitLeft =
                dailyDebtIncreaseLimitMin > debtIncreaseLimit ? dailyDebtIncreaseLimitMin : debtIncreaseLimit;
            dailyDebtIncreaseLimitLastReset = time;
        }
    }

    function _checkLoanIsHealthy(uint256 tokenId, uint256 debt)
        internal
        view
        returns (bool isHealthy, uint256 fullValue, uint256 collateralValue, uint256 feeValue)
    {
        (fullValue, feeValue,,) = oracle.getValue(tokenId, address(asset));
        uint256 collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);
        collateralValue = fullValue.mulDiv(collateralFactorX32, Q32);
        isHealthy = collateralValue >= debt;
    }

    function _convertToShares(uint256 amount, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return amount.mulDiv(Q96, exchangeRateX96, rounding);
    }

    function _convertToAssets(uint256 shares, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(exchangeRateX96, Q96, rounding);
    }

    function _addTokenToOwner(address to, uint256 tokenId) internal {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
        tokenOwner[tokenId] = to;
    }

    function _removeTokenFromOwner(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = ownedTokens[from].length - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];
            ownedTokens[from][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        ownedTokens[from].pop();
        // Note that ownedTokensIndex[tokenId] is not deleted. There is no need to delete it - gas optimization
        delete tokenOwner[tokenId]; // Remove the token from the token owner mapping
    }
}
