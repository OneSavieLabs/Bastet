// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC4626 } from "openzeppelin/interfaces/IERC4626.sol";
import { SafeERC20, IERC20Permit } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { ERC20, IERC20, IERC20Metadata } from "openzeppelin/token/ERC20/ERC20.sol";
import { Math } from "openzeppelin/utils/math/Math.sol";
import { Ownable } from "owner-manager-contracts/Ownable.sol";

import { Claimable } from "./abstract/Claimable.sol";
import { TwabERC20 } from "./TwabERC20.sol";

import { ILiquidationSource } from "pt-v5-liquidator-interfaces/ILiquidationSource.sol";
import { PrizePool } from "pt-v5-prize-pool/PrizePool.sol";
import { TwabController, SPONSORSHIP_ADDRESS } from "pt-v5-twab-controller/TwabController.sol";

/// @title  PoolTogether V5 Prize Vault
/// @author G9 Software Inc.
/// @notice The prize vault takes deposits of an asset and earns yield with the deposits through an underlying yield
///         vault. The yield is then expected to be liquidated and contributed to the prize pool as prize tokens. The
///         depositors of the prize vault will then be eligible to win prizes from the pool. If a prize is won, The 
///         permitted claimer contract for the prize vault will claim the prize on behalf of the winner. Depositors
///         can also set custom hooks that are called directly before and after their prize is claimed.
/// @dev    Share balances are stored in the TwabController contract.
/// @dev    Depositors should always expect to be able to withdraw their full deposit amount and no more as long as
///         global withdrawal limits meet or exceed their balance. However, if the underlying yield source loses
///         assets, depositors will only be able to withdraw a proportional amount of remaining assets based on their
///         share balance and the total debt balance.
/// @dev    The prize vault is designed to embody the "no loss" spirit of PoolTogether, down to the last wei. Most 
///         ERC4626 yield vaults incur small, necessary rounding errors on deposit and withdrawal to ensure the
///         internal accounting cannot be taken advantage of. The prize vault employs two strategies in an attempt
///         to cover these rounding errors with yield to ensure that depositors can withdraw every last wei of their
///         initial deposit:
///
///             1. The "dust collection strategy":
///
///                Rounding errors are directly related to the exchange rate of the underlying yield vault; the more
///                assets a single yield vault share is worth, the more severe the rounding errors can become. For
///                example, if the exchange rate is 100 assets for 1 yield vault share and we assume 0 decimal
///                precision; if alice deposits 199 assets, the yield vault will round down on the conversion and mint
///                alice 1 share, essentially donating the remaining 99 assets to the yield vault. This behavior can
///                open pathways for exploits in the prize vault since a bad actor could repeatedly make deposits and
///                withdrawals that result in large rounding errors and since the prize vault covers rounding errors
///                with yield, the attacker could withdraw without loss while essentially donating the yield back to
///                the yield vault.
///
///                To mitigate this issue, the prize vault calculates the amount of yield vault shares that would be
///                minted during a deposit, but mints those shares directly instead, ensuring that only the exact
///                amount of assets needed are sent to the yield vault while keeping the remainder as a latent balance
///                in the prize vault until it can be used in the next deposit or withdraw. An inverse strategy is also
///                used when withdrawing assets from the yield vault. This reduces the possible rounding errors to just
///                1 wei per deposit or withdraw.
///
///             2. The "yield buffer":
///
///                Since the prize vault can still incur minimal rounding errors from the yield vault, a yield buffer
///                is required to ensure that there is always enough yield reserved to cover the rounding errors on 
///                deposits and withdrawals. This buffer should never run dry during normal operating conditions and
///                expected yield rates. If the yield buffer is ever depleted, new deposits will be prevented and the
///                prize vault will enter a lossy withdrawal state where depositors will incur the rounding errors on
///                withdraw.
///
/// @dev    The prize vault does not support underlying yield vaults that take a fee on deposit or withdraw.
///
contract PrizeVault is TwabERC20, Claimable, IERC4626, ILiquidationSource, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    // Public Constants and Variables
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice The yield fee decimal precision.
    uint32 public constant FEE_PRECISION = 1e9;
    
    /// @notice The max yield fee that can be set.
    /// @dev Decimal precision is defined by `FEE_PRECISION`.
    /// @dev If the yield fee is set too high, liquidations won't occur on a regular basis. If a use case requires
    /// a yield fee higher than this max, a custom liquidation pair can be set to manipulate the yield as required.
    uint32 public constant MAX_YIELD_FEE = 9e8;

    /// @notice The yield buffer that is reserved for covering rounding errors on withdrawals and deposits.
    /// @dev The buffer prevents the entire yield balance from being liquidated, which would leave the vault
    /// in a state where a single rounding error could reduce the totalAssets to less than the totalSupply.
    /// 
    /// The yield buffer is expected to be of insignificant value and is used to cover rounding
    /// errors on deposits and withdrawals. Yield is expected to accrue faster than the yield buffer
    /// can be reasonably depleted.
    ///
    /// IT IS RECOMMENDED TO DONATE ASSETS DIRECTLY TO THE PRIZE VAULT AFTER DEPLOYMENT TO FILL THE YIELD
    /// BUFFER AND COVER ROUNDING ERRORS UNTIL THE DEPOSITS CAN GENERATE ENOUGH YIELD TO KEEP THE BUFFER 
    /// FULL WITHOUT ASSISTANCE.
    ///
    /// The yield buffer should be set as high as possible while still being considered insignificant
    /// for the underlying asset. For example, a reasonable yield buffer for USDC with 6 decimals might be
    /// 1e5 ($0.10), which will cover up to 100k rounding errors while still being an insignificant value.
    /// Some assets may be considered incompatible with the prize vault if the yield vault incurs rounding
    /// errors and the underlying asset has a low precision per dollar ratio.
    /// 
    /// Precision per dollar (PPD) can be calculated by: (10 ^ DECIMALS) / ($ value of 1 asset).
    /// For example, USDC has a PPD of (10 ^ 6) / ($1) = 10e6 p/$.
    /// 
    /// As a rule of thumb, assets with lower PPD than USDC should not be assumed to be compatible since
    /// the potential loss of a single unit rounding error is likely too high to be made up by yield at 
    /// a reasonable rate. Actual results may vary based on expected gas costs, asset fluctuation, and yield
    /// accrual rates. If the underlying yield vault does not incur any rounding errors, then the yield buffer
    /// can be set to zero.
    ///
    /// If the yield buffer is depleted on the prize vault, new deposits will be prevented if it would result in
    /// a rounding error and any rounding errors incurred by withdrawals will not be covered by yield. The yield
    /// buffer will be replenished automatically as yield accrues.
    uint256 public immutable yieldBuffer;

    /// @notice Address of the underlying ERC4626 vault generating yield.
    IERC4626 public immutable yieldVault;

    /// @notice Yield fee percentage represented in integer format with decimal precision defined by `FEE_PRECISION`.
    /// @dev For example, if `FEE_PRECISION` were 1e9 a value of 1e7 = 0.01 = 1%.
    uint32 public yieldFeePercentage;

    /// @notice Address of the yield fee recipient.
    address public yieldFeeRecipient;

    /// @notice The accrued yield fee balance that the fee recipient can claim as vault shares.
    uint256 public yieldFeeBalance;

    /// @notice Address of the liquidation pair used to liquidate yield for prize token.
    address public liquidationPair;

    ////////////////////////////////////////////////////////////////////////////////
    // Private Variables
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Address of the underlying asset used by the Vault.
    IERC20 private immutable _asset;

    /// @notice Underlying asset decimals.
    uint8 private immutable _underlyingDecimals;

    ////////////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new yield fee recipient has been set.
    /// @param yieldFeeRecipient Address of the new yield fee recipient
    event YieldFeeRecipientSet(address indexed yieldFeeRecipient);

    /// @notice Emitted when a new yield fee percentage has been set.
    /// @param yieldFeePercentage New yield fee percentage
    event YieldFeePercentageSet(uint256 yieldFeePercentage);

    /// @notice Emitted when a user sponsors the Vault.
    /// @param caller Address that called the function
    /// @param assets Amount of assets deposited into the Vault
    /// @param shares Amount of shares minted to the caller address
    event Sponsor(address indexed caller, uint256 assets, uint256 shares);

    /// @notice Emitted when yield is transferred out by the liquidation pair address.
    /// @param liquidationPair The liquidation pair address that initiated the transfer
    /// @param tokenOut The token that was transferred out
    /// @param recipient The recipient of the tokens
    /// @param amountOut The amount of tokens sent to the recipient
    /// @param yieldFee The amount of shares accrued on the yield fee balance
    event TransferYieldOut(
        address indexed liquidationPair,
        address indexed tokenOut,
        address indexed recipient,
        uint256 amountOut,
        uint256 yieldFee
    );

    /// @notice Emitted when yield fee shares are claimed by the yield fee recipient.
    /// @param recipient Address receiving the fee shares
    /// @param shares Amount of shares claimed
    event ClaimYieldFeeShares(address indexed recipient, uint256 shares);

    ////////////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when the Yield Vault is set to the zero address.
    error YieldVaultZeroAddress();

    /// @notice Thrown when the Owner is set to the zero address.
    error OwnerZeroAddress();

    /// @notice Thrown when a withdrawal of zero assets on the yield vault is attempted
    error WithdrawZeroAssets();

    /// @notice Thrown when no shares are being burnt during a withdrawal of assets
    error BurnZeroShares();

    /// @notice Thrown when zero assets are being deposited
    error DepositZeroAssets();

    /// @notice Thrown when zero shares are being minted
    error MintZeroShares();

    /// @notice Thrown if `totalAssets` is zero during a withdraw
    error ZeroTotalAssets();

    /// @notice Thrown when the Liquidation Pair being set is the zero address.
    error LPZeroAddress();

    /// @notice Thrown when `sweep` is called but no underlying assets are currently held by the Vault.
    error SweepZeroAssets();

    /// @notice Thrown during the liquidation process when the liquidation amount out is zero.
    error LiquidationAmountOutZero();

    /// @notice Thrown during the liquidation process when the caller is not the liquidation pair contract.
    /// @param caller The caller address
    /// @param liquidationPair The LP address
    error CallerNotLP(address caller, address liquidationPair);

    /// @notice Thrown if the caller is not the yield fee recipient when withdrawing yield fee shares.
    /// @param caller The caller address
    /// @param yieldFeeRecipient The yield fee recipient address
    error CallerNotYieldFeeRecipient(address caller, address yieldFeeRecipient);

    /// @notice Thrown when the caller of a permit function is not the owner of the assets being permitted.
    /// @param caller The address of the caller
    /// @param owner The address of the owner
    error PermitCallerNotOwner(address caller, address owner);

    /// @notice Thrown when the yield fee percentage being set exceeds the max yield fee allowed.
    /// @param yieldFeePercentage The yield fee percentage in integer format
    /// @param maxYieldFeePercentage The max yield fee percentage in integer format
    error YieldFeePercentageExceedsMax(uint256 yieldFeePercentage, uint256 maxYieldFeePercentage);

    /// @notice Thrown when the yield fee shares being withdrawn exceeds the available yieldFee Balance.
    /// @param shares The shares being withdrawn
    /// @param yieldFeeBalance The available yield fee shares
    error SharesExceedsYieldFeeBalance(uint256 shares, uint256 yieldFeeBalance);

    /// @notice Thrown during the liquidation process when the token in is not the prize token.
    /// @param tokenIn The provided tokenIn address
    /// @param prizeToken The prize token address
    error LiquidationTokenInNotPrizeToken(address tokenIn, address prizeToken);

    /// @notice Thrown during the liquidation process when the token out is not supported.
    /// @param tokenOut The provided tokenOut address
    error LiquidationTokenOutNotSupported(address tokenOut);

    /// @notice Thrown during the liquidation process if the total to withdraw is greater than the available yield.
    /// @param totalToWithdraw The total yield to withdraw
    /// @param availableYield The available yield
    error LiquidationExceedsAvailable(uint256 totalToWithdraw, uint256 availableYield);

    /// @notice Thrown when a deposit results in a state where the total assets are less than the total share supply.
    /// @param totalAssets The total assets controlled by the vault
    /// @param totalSupply The total shares minted and internally accounted for by the vault
    error LossyDeposit(uint256 totalAssets, uint256 totalSupply);

    ////////////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Requires the caller to be the liquidation pair.
    modifier onlyLiquidationPair() {
        if (msg.sender != liquidationPair) {
            revert CallerNotLP(msg.sender, liquidationPair);
        }
        _;
    }

    /// @notice Requires the caller to be the yield fee recipient.
    modifier onlyYieldFeeRecipient() {
        if (msg.sender != yieldFeeRecipient) {
            revert CallerNotYieldFeeRecipient(msg.sender, yieldFeeRecipient);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Vault constructor
    /// @param name_ Name of the ERC20 share minted by the vault
    /// @param symbol_ Symbol of the ERC20 share minted by the vault
    /// @param yieldVault_ Address of the underlying ERC4626 vault in which assets are deposited to generate yield
    /// @param prizePool_ Address of the PrizePool that computes prizes
    /// @param claimer_ Address of the claimer
    /// @param yieldFeeRecipient_ Address of the yield fee recipient
    /// @param yieldFeePercentage_ Yield fee percentage
    /// @param yieldBuffer_ Amount of yield to keep as a buffer
    /// @param owner_ Address that will gain ownership of this contract
    constructor(
        string memory name_,
        string memory symbol_,
        IERC4626 yieldVault_,
        PrizePool prizePool_,
        address claimer_,
        address yieldFeeRecipient_,
        uint32 yieldFeePercentage_,
        uint256 yieldBuffer_,
        address owner_
    ) TwabERC20(name_, symbol_, prizePool_.twabController()) Claimable(prizePool_, claimer_) Ownable(owner_) {
        if (address(yieldVault_) == address(0)) revert YieldVaultZeroAddress();
        if (owner_ == address(0)) revert OwnerZeroAddress();

        IERC20 asset_ = IERC20(yieldVault_.asset());
        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(asset_);
        _underlyingDecimals = success ? assetDecimals : 18;
        _asset = asset_;

        yieldVault = yieldVault_;
        yieldBuffer = yieldBuffer_;

        _setYieldFeeRecipient(yieldFeeRecipient_);
        _setYieldFeePercentage(yieldFeePercentage_);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // ERC20 Overrides
    ////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _underlyingDecimals;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // ERC4626 Implementation
    ////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC4626
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IERC4626
    /// @dev The latent asset balance is included in the total asset count to account for the "dust collection
    /// strategy".
    function totalAssets() public view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.balanceOf(address(this))) + _asset.balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 _assets) public view returns (uint256) {
        uint256 totalDebt_ = totalDebt();
        uint256 _totalAssets = totalAssets();
        if (_totalAssets >= totalDebt_) {
            return _assets;
        } else {
            // If the vault controls less assets than what has been deposited a share will be worth a
            // proportional amount of the total assets. This can happen due to fees, slippage, or loss
            // of funds in the underlying yield vault.
            return _assets.mulDiv(totalDebt_, _totalAssets, Math.Rounding.Down);
        }
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 _shares) public view returns (uint256) {
        uint256 totalDebt_ = totalDebt();
        uint256 _totalAssets = totalAssets();
        if (_totalAssets >= totalDebt_) {
            return _shares;
        } else {
            // If the vault controls less assets than what has been deposited a share will be worth a
            // proportional amount of the total assets. This can happen due to fees, slippage, or loss
            // of funds in the underlying yield vault.
            return _shares.mulDiv(_totalAssets, totalDebt_, Math.Rounding.Down);
        }
    }

    /// @inheritdoc IERC4626
    /// @dev Considers the uint96 limit on total share supply in the TwabController
    /// @dev Returns zero if any deposit would result in a loss of assets
    /// @dev Any latent balance of assets in the prize vault will be swept in with the deposit as a part of
    /// the "dust collection strategy". This means that the max deposit must account for the latent balance
    /// by subtracting it from the max deposit available otherwise.
    function maxDeposit(address) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 totalDebt_ = _totalDebt(_totalSupply);
        if (totalAssets() < totalDebt_) return 0;

        // the vault will never mint more than 1 share per asset, so no need to convert supply limit to assets
        uint256 twabSupplyLimit_ = _twabSupplyLimit(_totalSupply);
        uint256 _maxDeposit;
        uint256 _latentBalance = _asset.balanceOf(address(this));
        uint256 _maxYieldVaultDeposit = yieldVault.maxDeposit(address(this));
        if (_latentBalance >= _maxYieldVaultDeposit) {
            return 0;
        } else {
            unchecked {
                _maxDeposit = _maxYieldVaultDeposit - _latentBalance;
            }
            return twabSupplyLimit_ < _maxDeposit ? twabSupplyLimit_ : _maxDeposit;
        }
    }

    /// @inheritdoc IERC4626
    /// @dev Returns the same value as `maxDeposit` since shares and assets are 1:1 on mint
    /// @dev Returns zero if any deposit would result in a loss of assets
    function maxMint(address _owner) public view returns (uint256) {
        return maxDeposit(_owner);
    }

    /// @inheritdoc IERC4626
    /// @dev The prize vault maintains a latent balance of assets as part of the "dust collection strategy".
    /// This latent balance are accounted for in the max withdraw limits.
    function maxWithdraw(address _owner) public view returns (uint256) {
        uint256 _maxWithdraw = _maxYieldVaultWithdraw() + _asset.balanceOf(address(this));

        // the owner may receive less than 1 asset per share, so we must convert their balance here
        uint256 _ownerAssets = convertToAssets(balanceOf(_owner));
        return _ownerAssets < _maxWithdraw ? _ownerAssets : _maxWithdraw;
    }

    /// @inheritdoc IERC4626
    /// @dev The prize vault maintains a latent balance of assets as part of the "dust collection strategy".
    /// This latent balance are accounted for in the max redeem limits.
    function maxRedeem(address _owner) public view returns (uint256) {
        uint256 _maxWithdraw = _maxYieldVaultWithdraw() + _asset.balanceOf(address(this));
        uint256 _ownerShares = balanceOf(_owner);

        // The owner will never receive more than 1 asset per share, so there is no need to convert max
        // withdraw to shares unless the owner has more shares than the max withdraw and is redeeming
        // at a loss (when 1 share is worth less than 1 asset).
        if (_ownerShares > _maxWithdraw) {
            uint256 _totalAssets = totalAssets();
            uint256 totalDebt_ = totalDebt();
            if (_totalAssets >= totalDebt_) {
                return _maxWithdraw;
            } else {
                // Convert to shares while rounding up. Since 1 asset is guaranteed to be worth more than
                // 1 share and any upwards rounding will not exceed 1 share, we can be sure that when the
                // shares are converted back to assets (rounding down) the resulting asset value won't
                // exceed `_maxWithdraw`.
                uint256 _maxScaledRedeem = _maxWithdraw.mulDiv(totalDebt_, _totalAssets, Math.Rounding.Up);
                return _maxScaledRedeem >= _ownerShares ? _ownerShares : _maxScaledRedeem;
            }
        } else {
            return _ownerShares;
        }
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 _assets) public pure returns (uint256) {
        // shares represent how many assets an account has deposited, so they are 1:1 on deposit
        return _assets;
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 _shares) public pure returns (uint256) {
        // shares represent how many assets an account has deposited, so they are 1:1 on mint
        return _shares;
    }

    /// @inheritdoc IERC4626
    /// @dev Reverts if `totalAssets` in the vault is zero
    function previewWithdraw(uint256 _assets) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();

        // No withdrawals can occur if the vault controls no assets.
        if (_totalAssets == 0) revert ZeroTotalAssets();

        uint256 totalDebt_ = totalDebt();
        if (_totalAssets >= totalDebt_) {
            return _assets;
        } else {
            // Follows the inverse conversion of `convertToAssets`
            return _assets.mulDiv(totalDebt_, _totalAssets, Math.Rounding.Up);
        }
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 _shares) public view returns (uint256) {
        return convertToAssets(_shares);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 _assets, address _receiver) external returns (uint256) {
        uint256 _shares = previewDeposit(_assets);
        _depositAndMint(msg.sender, _receiver, _assets, _shares);
        return _shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 _shares, address _receiver) external returns (uint256) {
        uint256 _assets = previewMint(_shares);
        _depositAndMint(msg.sender, _receiver, _assets, _shares);
        return _assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) external returns (uint256) {
        uint256 _shares = previewWithdraw(_assets);
        _burnAndWithdraw(msg.sender, _receiver, _owner, _shares, _assets);
        return _shares;
    }

    /// @inheritdoc IERC4626
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) external returns (uint256) {
        uint256 _assets = previewRedeem(_shares);
        _burnAndWithdraw(msg.sender, _receiver, _owner, _shares, _assets);
        return _assets;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Additional Deposit Flows
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Approve underlying asset with permit, deposit into the Vault and mint Vault shares to `_owner`.
    /// @dev Can't be used to deposit on behalf of another user since `permit` does not accept a receiver parameter,
    /// meaning that anyone could reuse the signature and pass an arbitrary receiver to this function.
    /// @param _assets Amount of assets to approve and deposit
    /// @param _owner Address of the owner depositing `_assets` and signing the permit
    /// @param _deadline Timestamp after which the approval is no longer valid
    /// @param _v V part of the secp256k1 signature
    /// @param _r R part of the secp256k1 signature
    /// @param _s S part of the secp256k1 signature
    /// @return Amount of Vault shares minted to `_owner`.
    function depositWithPermit(
        uint256 _assets,
        address _owner,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256) {
        if (_owner != msg.sender) {
            revert PermitCallerNotOwner(msg.sender, _owner);
        }

        // Skip the permit call if the allowance has already been set to exactly what is needed. This prevents
        // griefing attacks where the signature is used by another actor to complete the permit before this
        // function is executed.
        if (_asset.allowance(_owner, address(this)) != _assets) {
            IERC20Permit(address(_asset)).permit(_owner, address(this), _assets, _deadline, _v, _r, _s);
        }

        uint256 _shares = previewDeposit(_assets);
        _depositAndMint(_owner, _owner, _assets, _shares);
        return _shares;
    }

    /// @notice Deposit assets into the Vault and delegate to the sponsorship address.
    /// @dev Emits a `Sponsor` event
    /// @param _assets Amount of assets to deposit
    /// @return Amount of shares minted to caller.
    function sponsor(uint256 _assets) external returns (uint256) {
        address _owner = msg.sender;

        uint256 _shares = previewDeposit(_assets);
        _depositAndMint(_owner, _owner, _assets, _shares);

        if (twabController.delegateOf(address(this), _owner) != SPONSORSHIP_ADDRESS) {
            twabController.sponsor(_owner);
        }

        emit Sponsor(_owner, _assets, _shares);

        return _shares;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Additional Accounting
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the total assets that are owed to share holders and any other internal balances.
    /// @return The total asset debt of the vault
    function totalDebt() public view returns (uint256) {
        return _totalDebt(totalSupply());
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Yield Functions
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Total yield balance of the vault
    /// @dev Equal to total assets minus total debt
    /// @return The total yield balance
    function totalYieldBalance() public view returns (uint256) {
        return _totalYieldBalance(totalAssets(), totalDebt());
    }

    /// @notice Total available yield on the vault
    /// @dev Equal to total assets minus total allocation (total debt + yield buffer)
    /// @return The available yield balance
    function availableYieldBalance() public view returns (uint256) {
        return _availableYieldBalance(totalAssets(), totalDebt());
    }

    /// @notice Current amount of assets available in the yield buffer
    /// @return The available assets in the yield buffer
    function currentYieldBuffer() external view returns (uint256) {
        uint256 totalYieldBalance_ = _totalYieldBalance(totalAssets(), totalDebt());
        uint256 _yieldBuffer = yieldBuffer;
        if (totalYieldBalance_ >= _yieldBuffer) {
            return _yieldBuffer;
        } else {
            return totalYieldBalance_;
        }
    }

    /// @notice Transfers yield fee shares to the yield fee recipient
    /// @param _shares The shares to mint to the yield fee recipient
    /// @dev Emits a `ClaimYieldFeeShares` event
    /// @dev Will revert if the caller is not the yield fee recipient or if zero shares are withdrawn
    function claimYieldFeeShares(uint256 _shares) external onlyYieldFeeRecipient {
        if (_shares == 0) revert MintZeroShares();

        uint256 _yieldFeeBalance = yieldFeeBalance;
        if (_shares > _yieldFeeBalance) revert SharesExceedsYieldFeeBalance(_shares, _yieldFeeBalance);

        yieldFeeBalance -= _yieldFeeBalance;

        _mint(msg.sender, _shares);

        emit ClaimYieldFeeShares(msg.sender, _shares);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // LiquidationSource Functions
    ////////////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILiquidationSource
    /// @dev Returns the liquid amount of `_tokenOut` minus any yield fees.
    /// @dev Supports the liquidation of either assets or prize vault shares.
    function liquidatableBalanceOf(address _tokenOut) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _maxAmountOut;
        if (_tokenOut == address(this)) {
            // Liquidation of vault shares is capped to the TWAB supply limit.
            _maxAmountOut = _twabSupplyLimit(_totalSupply);
        } else if (_tokenOut == address(_asset)) {
            // Liquidation of yield assets is capped at the max yield vault withdraw plus any latent balance.
            _maxAmountOut = _maxYieldVaultWithdraw() + _asset.balanceOf(address(this));
        } else {
            return 0;
        }

        // The liquid yield is computed by taking the available yield balance and multiplying it
        // by (1 - yieldFeePercentage), rounding down, to ensure that enough yield is left for the
        // yield fee.
        uint256 _liquidYield = 
            _availableYieldBalance(totalAssets(), _totalDebt(_totalSupply))
            .mulDiv(FEE_PRECISION - yieldFeePercentage, FEE_PRECISION);

        // The liquid yield is limited by the max that can be minted or withdrawn, depending on
        // `_tokenOut`.
        return _liquidYield >= _maxAmountOut ? _maxAmountOut : _liquidYield;
    }

    /// @inheritdoc ILiquidationSource
    /// @dev Emits a `TransferYieldOut` event
    /// @dev Supports the liquidation of either assets or prize vault shares.
    function transferTokensOut(
        address,
        address _receiver,
        address _tokenOut,
        uint256 _amountOut
    ) public virtual onlyLiquidationPair returns (bytes memory) {
        if (_amountOut == 0) revert LiquidationAmountOutZero();

        uint256 _availableYield = availableYieldBalance();
        uint32 _yieldFeePercentage = yieldFeePercentage;

        // Determine the proportional yield fee based on the amount being liquidated:
        uint256 _yieldFee;
        if (_yieldFeePercentage != 0) {
            // The yield fee is calculated as a portion of the total yield being consumed, such that 
            // `total = amountOut + yieldFee` and `yieldFee / total = yieldFeePercentage`. 
            _yieldFee = (_amountOut * FEE_PRECISION) / (FEE_PRECISION - _yieldFeePercentage) - _amountOut;
        }

        // Ensure total liquidation amount does not exceed the available yield balance:
        if (_amountOut + _yieldFee > _availableYield) {
            revert LiquidationExceedsAvailable(_amountOut + _yieldFee, _availableYield);
        }

        // Increase yield fee balance:
        if (_yieldFee > 0) {
            yieldFeeBalance += _yieldFee;
        }

        // Mint or withdraw amountOut to `_receiver`:
        if (_tokenOut == address(_asset)) {
            _withdraw(_receiver, _amountOut);            
        } else if (_tokenOut == address(this)) {
            _mint(_receiver, _amountOut);
        } else {
            revert LiquidationTokenOutNotSupported(_tokenOut);
        }

        emit TransferYieldOut(msg.sender, _tokenOut, _receiver, _amountOut, _yieldFee);

        return "";
    }

    /// @inheritdoc ILiquidationSource
    function verifyTokensIn(
        address _tokenIn,
        uint256 _amountIn,
        bytes calldata
    ) external onlyLiquidationPair {
        address _prizeToken = address(prizePool.prizeToken());
        if (_tokenIn != _prizeToken) {
            revert LiquidationTokenInNotPrizeToken(_tokenIn, _prizeToken);
        }

        prizePool.contributePrizeTokens(address(this), _amountIn);
    }

    /// @inheritdoc ILiquidationSource
    function targetOf(address) external view returns (address) {
        return address(prizePool);
    }

    /// @inheritdoc ILiquidationSource
    function isLiquidationPair(
        address _tokenOut,
        address _liquidationPair
    ) external view returns (bool) {
        return (_tokenOut == address(_asset) || _tokenOut == address(this)) && _liquidationPair == liquidationPair;
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Setter Functions
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Set claimer.
    /// @param _claimer Address of the claimer
    function setClaimer(address _claimer) external onlyOwner {
        _setClaimer(_claimer);
    }

    /// @notice Set liquidationPair.
    /// @dev Emits a `LiquidationPairSet` event
    /// @param _liquidationPair New liquidationPair address
    function setLiquidationPair(address _liquidationPair) external onlyOwner {
        if (address(_liquidationPair) == address(0)) revert LPZeroAddress();

        liquidationPair = _liquidationPair;

        emit LiquidationPairSet(address(this), address(_liquidationPair));
    }

    /// @notice Set yield fee percentage.
    /// @dev Yield fee is defined on a scale from `0` to `FEE_PRECISION`, inclusive.
    /// @param _yieldFeePercentage The new yield fee percentage to set
    function setYieldFeePercentage(uint32 _yieldFeePercentage) external onlyOwner {
        _setYieldFeePercentage(_yieldFeePercentage);
    }

    /// @notice Set fee recipient.
    /// @param _yieldFeeRecipient Address of the fee recipient
    function setYieldFeeRecipient(address _yieldFeeRecipient) external onlyOwner {
        _setYieldFeeRecipient(_yieldFeeRecipient);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Fetch decimals of the underlying asset.
    /// @dev A return value of false indicates that the attempt failed in some way.
    /// @param asset_ Address of the underlying asset
    /// @return True if the attempt was successful, false otherwise
    /// @return Number of token decimals
    function _tryGetAssetDecimals(IERC20 asset_) internal view returns (bool, uint8) {
        (bool success, bytes memory encodedDecimals) = address(asset_).staticcall(
            abi.encodeWithSelector(IERC20Metadata.decimals.selector)
        );
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    /// @notice Returns the total assets that are owed to share holders and any other internal balances.
    /// @dev The yield fee balance is included since it's cheaper to keep track of those shares
    ///      internally instead of doing an additional TWAB mint on every liquidation.
    /// @param _totalSupply The total share supply of the vault
    /// @return The total asset debt of the vault
    function _totalDebt(uint256 _totalSupply) internal view returns (uint256) {
        return _totalSupply + yieldFeeBalance;
    }

    /// @notice Returns the remaining supply that can be minted without exceeding the TwabController limits.
    /// @dev The TwabController limits the total supply for each vault to uint96
    /// @param _totalSupply The total share supply of the vault
    /// @return The remaining supply that can be minted without exceeding TWAB limits
    function _twabSupplyLimit(uint256 _totalSupply) internal pure returns (uint256) {
        unchecked {
            return type(uint96).max - _totalSupply;
        }
    }

    /// @notice Total yield balance of the vault (including the yield buffer).
    /// @param _totalAssets The total assets controlled by the vault
    /// @param totalDebt_ The total asset debt owed
    /// @return The total yield balance
    function _totalYieldBalance(uint256 _totalAssets, uint256 totalDebt_) internal pure returns (uint256) {
        if (totalDebt_ >= _totalAssets) {
            return 0;
        } else {
            unchecked {
                return _totalAssets - totalDebt_;
            }
        }
    }

    /// @notice Available yield balance given the total assets and total share supply.
    /// @dev Subtracts the yield buffer from the total yield balance.
    /// @param _totalAssets The total assets controlled by the vault
    /// @param totalDebt_ The total asset debt owed
    /// @return The available yield balance
    function _availableYieldBalance(uint256 _totalAssets, uint256 totalDebt_) internal view returns (uint256) {
        uint256 totalYieldBalance_ = _totalYieldBalance(_totalAssets, totalDebt_);
        uint256 _yieldBuffer = yieldBuffer;
        if (totalYieldBalance_ >= _yieldBuffer) {
            unchecked {
                return totalYieldBalance_ - _yieldBuffer;
            }
        } else {
            return 0;
        }
    }

    /// @notice Deposits assets to the yield vault and mints shares
    /// @param _caller The caller of the deposit
    /// @param _receiver The receiver of the deposit shares
    /// @param _assets Amount of assets to deposit
    /// @param _shares Amount of shares to mint
    /// @dev Emits a `Deposit` event.
    /// @dev Will revert if 0 shares are minted back to the receiver or if 0 assets are deposited.
    /// @dev Will revert if the deposit may result in the loss of funds.
    function _depositAndMint(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal {
        if (_shares == 0) revert MintZeroShares();
        if (_assets == 0) revert DepositZeroAssets();

        // If _asset is ERC777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook that is triggered after the transfer
        // calls the vault which is assumed to not be malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.

        _asset.safeTransferFrom(
            _caller,
            address(this),
            _assets
        );

        // Previously accumulated dust is swept into the yield vault along with the deposit.
        uint256 _assetsWithDust = _asset.balanceOf(address(this));
        _asset.approve(address(yieldVault), _assetsWithDust);

        // The shares are calculated and then minted directly to mitigate rounding error loss.
        uint256 _yieldVaultShares = yieldVault.previewDeposit(_assetsWithDust);
        uint256 _assetsUsed = yieldVault.mint(_yieldVaultShares, address(this));
        if (_assetsUsed != _assetsWithDust) {
            // If some latent balance remains, the approval is set back to zero for weird tokens like USDT.
            _asset.approve(address(yieldVault), 0);
        }

        _mint(_receiver, _shares);

        if (totalAssets() < totalDebt()) revert LossyDeposit(totalAssets(), totalDebt());

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    /// @notice Burns shares and withdraws assets from the underlying yield vault.
    /// @param _caller Address of the caller
    /// @param _receiver Address of the receiver of the assets
    /// @param _owner Owner of the shares
    /// @param _shares Shares to burn
    /// @param _assets Assets to withdraw
    /// @dev Emits a `Withdraw` event.
    /// @dev Will revert if 0 assets are withdrawn or if 0 shares are burned
    function _burnAndWithdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _shares,
        uint256 _assets
    ) internal {
        if (_assets == 0) revert WithdrawZeroAssets();
        if (_shares == 0) revert BurnZeroShares();
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(_owner, _shares);
        _withdraw(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /// @notice Returns the max assets that can be withdrawn from the yield vault through this vault's
    /// `_withdraw` function.
    /// @dev This should be used over `yieldVault.maxWithdraw` when considering withdrawal limits since
    /// this function takes into account the yield vault redemption limits, which is necessary since the
    /// `_withdraw` function uses `yieldVault.redeem` instead of `yieldVault.withdraw`. Since we convert
    /// the max redeemable shares to assets rounding down, the `yieldVault.previewWithdraw` call in the
    /// `_withdraw` function is guaranteed to return less than or equal shares to the max yield vault 
    /// redemption.
    /// @return The max assets that can be withdrawn from the yield vault.
    function _maxYieldVaultWithdraw() internal view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.maxRedeem(address(this)));
    }

    /// @notice Withdraws assets to the receiver while accounting for rounding errors.
    /// @param _receiver The receiver of the assets
    /// @param _assets The assets to withdraw
    function _withdraw(address _receiver, uint256 _assets) internal {
        // The vault accumulates dust from rounding errors over time, so if we can fulfill the withdrawal from the
        // latent balance, we don't need to redeem any yield vault shares.
        uint256 _latentAssets = _asset.balanceOf(address(this));
        if (_assets > _latentAssets) {
            // The latent balance is subtracted from the withdrawal so we don't withdraw more than we need.
            uint256 _yieldVaultShares = yieldVault.previewWithdraw(_assets - _latentAssets);
            // Assets are sent to this contract so any leftover dust can be redeposited later.
            yieldVault.redeem(_yieldVaultShares, address(this), address(this));
        }
        if (_receiver != address(this)) {
            _asset.transfer(_receiver, _assets);
        }
    }

    /// @notice Set yield fee percentage.
    /// @dev Yield fee is defined on a scale from `0` to `MAX_YIELD_FEE`, inclusive.
    /// @dev Emits a `YieldFeePercentageSet` event
    /// @param _yieldFeePercentage The new yield fee percentage to set
    function _setYieldFeePercentage(uint32 _yieldFeePercentage) internal {
        if (_yieldFeePercentage > MAX_YIELD_FEE) {
            revert YieldFeePercentageExceedsMax(_yieldFeePercentage, MAX_YIELD_FEE);
        }
        yieldFeePercentage = _yieldFeePercentage;
        emit YieldFeePercentageSet(_yieldFeePercentage);
    }

    /// @notice Set yield fee recipient address.
    /// @dev Emits a `YieldFeeRecipientSet` event
    /// @param _yieldFeeRecipient Address of the fee recipient
    function _setYieldFeeRecipient(address _yieldFeeRecipient) internal {
        yieldFeeRecipient = _yieldFeeRecipient;
        emit YieldFeeRecipientSet(_yieldFeeRecipient);
    }

}