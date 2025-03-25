// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

// interfaces
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IERC5095} from "./interfaces/IERC5095.sol";
import {ITranche} from "./interfaces/ITranche.sol";
import {IYieldToken} from "./interfaces/IYieldToken.sol";
import {ITrancheFactory} from "./interfaces/ITrancheFactory.sol";
import {IBaseAdapter} from "./interfaces/IBaseAdapter.sol";
// libs
import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import {SafeERC20Namer} from "./utils/SafeERC20Namer.sol";
import {SafeERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";
import {MAX_BPS} from "./Constants.sol";
// inheriting
import {ERC20Permit, ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/extensions/ERC20Permit.sol";
import {Pausable} from "@openzeppelin/contracts@4.9.3/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";
import {BaseToken} from "./BaseToken.sol";

/// @title Tranche
/// @author Napier Labs
/// @author 0xbakuchi
/// @notice Tranche divides a yield-bearing token into two tokens: principal token and yield token.
/// This contract itself is a principal token.
/// Users can interact with this contract to issue, redeem tokens, and gather yield.
/// Both the Principal and Yield tokens share the same decimal notation as the underlying token.
/// Math:
/// - Yield Stripping Math paper: https://github.com/Napier-Lab/napier-v1/blob/main/assets/Yield_Stripping_Math__1_.pdf
/// - Hackmd: https://hackmd.io/W2mPhP7YRjGxqnAc93omLg?both
/// PT/YT and Target token conversion is defined as:
/// P = T * scale / 1e18
///   = T * price * 10^(18 + uDecimals - tDecimals) / 1e18
/// Where P is amount of PT and T is amount of Target.
/// @dev Supported Tokens:
/// - Underlying token can be rebased token.
/// - Underlying must not be ERC777 token.
/// - Target token can not be rebased token.
contract Tranche is BaseToken, ReentrancyGuard, Pausable, ITranche {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    using SafeCast for uint256;

    uint8 internal immutable uDecimals;

    /// @notice Represents the underlying token where users deposit (e.g. DAI)
    IERC20 internal immutable _underlying;

    /// @notice Represents the yield-bearing token (e.g. cDAI)
    IERC20 internal immutable _target;

    /// @notice Represents the Yield token that represents the right to claim the yield
    IYieldToken internal immutable _yt;

    /// @notice An adapter that interacts with the yield source (e.g. Compound)
    IBaseAdapter public immutable adapter;

    /// @notice Address of the management account
    address public immutable management;

    // Principal token Parameters

    /// @inheritdoc IERC5095
    /// @notice The timestamp of maturity in unix seconds
    uint256 public immutable override(BaseToken, IERC5095) maturity;

    /// @notice Percentage of underlying principal reserved for YTs.
    /// YT holders can claim this after maturity. (10000 = 100%)
    uint256 internal immutable tilt;

    /// @notice 10_000 - tilt (10000 = 100%) for gas savings
    uint256 internal immutable oneSubTilt;

    /// @notice The fee for issuing new tokens (10000 = 100%)
    uint256 internal immutable issuanceFeeBps;

    //////////////////////////////////////////////////
    // State Variables
    //////////////////////////////////////////////////

    /// @notice Variables tracking the yield-bearing token's scales
    /// @dev This is used to calculate the claimable yield and is updated on every issue, collect, and redeemYT action.
    ///  - `mscale` represents the scale of the yield-bearing token at or after maturity,
    /// it is set only at the time of users redeeming, redeemingYT and collecting at/after maturity.
    ///  - `maxscale` represents the maximum scale of the yield-bearing token since the Tranche's creation till now.
    GlobalScales internal gscales;

    /// @dev Accumulated issuance fees charged (in units of target token). The management can withdraw this fees.
    uint256 public issuanceFees;

    /// @dev The address that receives the issuance fees. This address can be changed by the `management`.
    address public feeRecipient;

    /// @notice Keeps track of the scale of the target token at the last user action.
    /// @dev It is used for calculating the yield that can be claimed. It gets updated on every user action.
    /// user -> lscale (last scale)
    /// See "Yield Stripping Math" for more details.
    mapping(address => uint256) public lscales;

    /// @notice Keeps track of the yield not claimed by each user in units of the target token.
    /// @dev This value is reset to 0 on every issue, collect and redeemYT action. Every YT transfer also increases this value.
    mapping(address => uint256) public unclaimedYields;

    /* ================== MODIFIERS =================== */

    /// @notice Revert if timestamp is before maturity
    modifier expired() {
        if (block.timestamp < maturity) revert TimestampBeforeMaturity();
        _;
    }

    /// @notice Revert if timestamp is at or after maturity
    modifier notExpired() {
        if (block.timestamp >= maturity) revert TimestampAfterMaturity();
        _;
    }

    /// @notice Revert if reentrancy guard is already set to `entered`
    modifier notEntered() {
        if (_reentrancyGuardEntered()) revert ReentrancyGuarded();
        _;
    }

    /// @notice Revert if msg sender is not management address
    modifier onlyManagement() {
        if (msg.sender != management) revert Unauthorized();
        _;
    }

    /// @dev Assume Tranche is deployed from a factory.
    /// Doesn't take constructor arguments directly so that CREATE2 address is independent of the constructor arguments.
    /// The arguments are fetched through a callback to the factory.
    /// @custom:param _args The arguments for the Tranche contract.
    ///
    /// The constructor is `payable` to remove msg.value check and reduce about 198 gas cost at deployment time.
    /// This is acceptable because the factory contract doesn't deploy Tranche with ETH.
    constructor() payable ERC20("Napier Principal Token", "ePT") ERC20Permit("Napier Principal Token") {
        // Retrieve constructor arguments from the factory
        ITrancheFactory.TrancheInitArgs memory args = ITrancheFactory(msg.sender).args();
        address underlying_ = IBaseAdapter(args.adapter).underlying();
        address target_ = IBaseAdapter(args.adapter).target();

        // Initialize immutable and state variables
        feeRecipient = args.management;
        management = args.management;

        _underlying = IERC20(underlying_);
        _target = IERC20(target_);
        _yt = IYieldToken(args.yt);
        adapter = IBaseAdapter(args.adapter);
        tilt = args.tilt;
        oneSubTilt = MAX_BPS - tilt; // 10_000 - tilt
        issuanceFeeBps = args.issuanceFee;
        maturity = args.maturity;
        uDecimals = ERC20(underlying_).decimals();
        // Set maxscale to the current scale
        gscales.maxscale = IBaseAdapter(args.adapter).scale().toUint128();

        emit SeriesCreated(args.adapter, args.maturity, args.tilt, args.issuanceFee);
    }

    /* ================== MUTATIVE METHODS =================== */

    /// @inheritdoc ITranche
    /// @notice This function issues Principal Token (PT) and Yield Token (YT) to `to` in exchange for `underlyingAmount` of underlying token.
    /// Issued PT and YT is the sum of:
    /// - amount derived from the deposited underlying token
    /// - amount derived from reinveted unclaimed yield
    /// - amount derived from reinvested accrued yield from last time when YT balance was updated to now
    ///
    /// Issuance Fee is charged on the amount of Target Token used to issue PT and YT.
    /// @dev The function will be reverted if the maturity has passed.
    /// @param to The recipient of PT and YT
    /// @param underlyingAmount The amount of underlying token to be deposited. (in units of underlying token)
    /// @return issued The amount of PT and YT minted
    function issue(
        address to,
        uint256 underlyingAmount
    ) external nonReentrant whenNotPaused notExpired returns (uint256 issued) {
        uint256 _lscale = lscales[to];
        uint256 accruedInTarget = unclaimedYields[to];
        uint256 _maxscale = gscales.maxscale;

        // NOTE: Updating mscale/maxscale in the cache before the issue to determine the accrued yield.
        uint256 cscale = adapter.scale();

        if (cscale > _maxscale) {
            // If the current scale is greater than the maxscale, update scales
            _maxscale = cscale;
            gscales.maxscale = cscale.toUint128();
        }
        // Updating user's last scale to the latest maxscale
        lscales[to] = _maxscale;
        delete unclaimedYields[to];

        uint256 yBal = _yt.balanceOf(to);
        // If recipient has unclaimed interest, claim it and then reinvest it to issue more PT and YT.
        // Reminder: lscale is the last scale when the YT balance of the user was updated.
        if (_lscale != 0) {
            accruedInTarget += _computeAccruedInterestInTarget(_maxscale, _lscale, yBal);
        }

        // Transfer underlying from user to adapter and deposit it into adapter to get target token
        _underlying.safeTransferFrom(msg.sender, address(adapter), underlyingAmount);
        (, uint256 sharesMinted) = adapter.prefundedDeposit();

        // Deduct the issuance fee from the amount of target token minted + reinvested yield
        // Fee should be rounded up towards the protocol (against the user) so that issued principal is rounded down
        // Hackmd: F0
        // ptIssued
        // = (u/s + y - fee) * S
        // = (sharesUsed - fee) * S
        // where u = underlyingAmount, s = current scale, y = reinvested yield, S = maxscale
        uint256 sharesUsed = sharesMinted + accruedInTarget;
        uint256 fee = sharesUsed.mulDivUp(issuanceFeeBps, MAX_BPS);
        issued = (sharesUsed - fee).mulWadDown(_maxscale);

        // Accumulate issueance fee in units of target token
        issuanceFees += fee;
        // Mint PT and YT to user
        _mint(to, issued);
        _yt.mint(to, issued);

        emit Issue(msg.sender, to, issued, sharesUsed);
    }

    /// @inheritdoc ITranche
    /// @notice Withdraws underlying tokens from the caller in exchange for `amount` of PT and YT.
    /// 1 PT + 1 YT = 1 Target token (e.g. 1 wstETH). This equation is always true
    /// because PT represents the principal amount of the Target token and YT represents the yield of the Target token.
    /// Basically, anyone can burn `x` PT and `x` YT to withdraw `x` Target tokens anytime.
    ///
    /// Withdrawn amount will be the sum of the following:
    /// - amount derived from PT + YT burn
    /// - amount of unclaimed yield
    /// - amount of accrued yield from the last time when the YT balance was updated to now
    /// @notice If the caller is not `from`, `from` must have approved the caller to spend `pyAmount` for PT and YT prior to calling this function.
    /// @dev Reverts if the caller does not have enough PT and YT.
    /// @param from The owner of PT and YT.
    /// @param to The recipient of the redeemed underlying tokens.
    /// @param pyAmount The amount of principal token (and yield token) to redeem in units of underlying tokens.
    /// @return (uint256) The amount of underlying tokens redeemed.
    function redeemWithYT(address from, address to, uint256 pyAmount) external nonReentrant returns (uint256) {
        uint256 _lscale = lscales[from];
        uint256 accruedInTarget = unclaimedYields[from];

        // Calculate the accrued interest in Target token
        // The lscale should not be 0 because the user should have some YT balance
        if (_lscale == 0) revert NoAccruedYield();

        GlobalScales memory _gscales = gscales;
        _updateGlobalScalesCache(_gscales);

        // Compute the accrued yield from the time when the YT balance is updated last to now
        // The accrued yield in units of target is computed as:
        // Formula: yield = ytBalance * (1/lscale - 1/maxscale)
        // Sum up the accrued yield, plus the unclaimed yield from the last time to now
        accruedInTarget += _computeAccruedInterestInTarget(
            _gscales.maxscale,
            _lscale,
            // Use yt balance instead of `pyAmount`
            // because we'll update the user's lscale to the current maxscale after this line
            // regardless of whether the user redeems all of their yt or not.
            // Otherwise, the user will lose some accrued yield from the last time to now.
            _yt.balanceOf(from)
        );
        // Compute shares equivalent to the amount of principal token to redeem
        uint256 sharesRedeemed = pyAmount.divWadDown(_gscales.maxscale);

        // Update the local scale and accrued yield of `from`
        lscales[from] = _gscales.maxscale;
        delete unclaimedYields[from];
        gscales = _gscales;

        // Burn PT and YT tokens from `from`
        _burnFrom(from, pyAmount);
        _yt.burnFrom(from, msg.sender, pyAmount);

        // Withdraw underlying tokens from the adapter and transfer them to the user
        _target.safeTransfer(address(adapter), sharesRedeemed + accruedInTarget);
        (uint256 amountWithdrawn, ) = adapter.prefundedRedeem(to);

        emit RedeemWithYT(from, to, amountWithdrawn);
        return amountWithdrawn;
    }

    /// @inheritdoc IERC5095
    /// @notice If the sender is not `from`, it must have approval from `from` to redeem `principalAmount` PT.
    /// Redeems `principalAmount` PT from `from` and transfers underlying tokens to `to`.
    /// @dev Reverts if maturity has not passed.
    /// @param principalAmount The amount of principal tokens to redeem in units of underlying tokens.
    /// @param to The recipient of the redeemed underlying tokens.
    /// @param from The owner of the PT.
    /// @return (uint256) The amount of underlying tokens redeemed.
    function redeem(
        uint256 principalAmount,
        address to,
        address from
    ) external override nonReentrant expired returns (uint256) {
        GlobalScales memory _gscales = gscales;
        _updateGlobalScalesCache(_gscales);

        // Compute the shares to be redeemed
        uint256 shares = _computeSharesRedeemed(_gscales, principalAmount);

        gscales = _gscales;
        // Burn PT tokens from `from`
        _burnFrom(from, principalAmount);
        // Withdraw underlying tokens from the adapter and transfer them to `to`
        _target.safeTransfer(address(adapter), shares);
        (uint256 underlyingWithdrawn, ) = adapter.prefundedRedeem(to);

        emit Redeem(from, to, underlyingWithdrawn);
        return underlyingWithdrawn;
    }

    /// @inheritdoc IERC5095
    /// @notice If the sender is not `from`, it must have approval from `from` to redeem an equivalent amount of principal tokens.
    /// Redeems PT equivalent to `underlyingAmount` underlying tokens from `from` and transfers underlying tokens to `to`.
    /// @dev Reverts if maturity has not passed.
    /// @param underlyingAmount The amount of underlying tokens to redeem in units of underlying tokens.
    /// @param to The recipient of the redeemed underlying tokens.
    /// @param from The owner of the PT.
    /// @return (uint256) The amount of principal tokens redeemed.
    function withdraw(
        uint256 underlyingAmount,
        address to,
        address from
    ) external override nonReentrant expired returns (uint256) {
        GlobalScales memory _gscales = gscales;
        uint256 cscale = _updateGlobalScalesCache(_gscales);

        // Compute the shares to be redeemed
        uint256 sharesRedeem = underlyingAmount.divWadDown(cscale);
        uint256 principalAmount = _computePrincipalTokenRedeemed(_gscales, sharesRedeem);

        // Update the global scales
        gscales = _gscales;
        // Burn PT tokens from `from`
        _burnFrom(from, principalAmount);
        // Withdraw underlying tokens from the adapter and transfer them to `to`
        _target.safeTransfer(address(adapter), sharesRedeem);
        (uint256 underlyingWithdrawn, ) = adapter.prefundedRedeem(to);

        emit Redeem(from, to, underlyingWithdrawn);
        return principalAmount;
    }

    /// @notice Before transferring YT, update the accrued yield for the sender and receiver.
    /// NOTE: Every YT transfer will trigger this function to track accrued yield for each user.
    /// @dev This function is only callable by the Yield Token contract when the user transfers YT to another user.
    /// NOTE: YT is not burned in this function even if the maturity has passed.
    /// @param from The address to transfer the Yield Token from.
    /// @param to The address to transfer the Yield Token to (CAN be the same as `from`).
    /// NOTE: `from` and `to` SHOULD NOT be zero addresses.
    /// @param value The amount of Yield Token transferred to `to` (CAN be 0).
    function updateUnclaimedYield(address from, address to, uint256 value) external nonReentrant whenNotPaused {
        if (msg.sender != address(_yt)) revert OnlyYT();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (value == 0) return;

        GlobalScales memory _gscales = gscales;
        uint256 _lscaleFrom = lscales[from];

        // If the lscale is 0, it means the user have never hold any YT before
        // because the lscale is always set to maxscale when the YT is transferrred or minted.
        // This doesn't mean current YT balance is 0 because the user could have transferred all YT out or burned YT.
        // Thus there is no accrued interest for the user.
        if (_lscaleFrom == 0) revert NoAccruedYield();

        _updateGlobalScalesCache(_gscales);

        // Calculate the accrued interest in Target token for `from`
        unclaimedYields[from] += _computeAccruedInterestInTarget(_gscales.maxscale, _lscaleFrom, _yt.balanceOf(from));
        lscales[from] = _gscales.maxscale;

        // Calculate the accrued interest in Target token for `to`. `from` and `to` can be equal.
        uint256 _lscaleReceiver = lscales[to];
        if (_lscaleReceiver != 0) {
            unclaimedYields[to] +=
                _computeAccruedInterestInTarget(_gscales.maxscale, _lscaleReceiver, _yt.balanceOf(to)); // prettier-ignore
        }
        lscales[to] = _gscales.maxscale;
        // update global scales
        gscales = _gscales;
    }

    /// @notice Collects yield for `msg.sender` and converts it to underlying token and transfers it to `msg.sender`.
    /// NOTE: If the maturity has passed, YT will be burned, and some of the principal will be transferred to `msg.sender` based on the `tilt` parameter.
    /// The withdrwan amount of underlying token is the sum of the following:
    /// - Amount of unclaimed yield
    /// - Amount of accrued yield from the time when the YT balance was updated to now
    /// - Amount of principal reserved for YT holders if the maturity has passed
    /// @dev Anyone can call this function to collect yield for themselves.
    /// @return The collected yield in underlying token.
    function collect() public nonReentrant whenNotPaused returns (uint256) {
        uint256 _lscale = lscales[msg.sender];
        uint256 accruedInTarget = unclaimedYields[msg.sender];

        if (_lscale == 0) revert NoAccruedYield();

        GlobalScales memory _gscales = gscales;
        _updateGlobalScalesCache(_gscales);

        uint256 yBal = _yt.balanceOf(msg.sender);
        accruedInTarget += _computeAccruedInterestInTarget(_gscales.maxscale, _lscale, yBal);
        lscales[msg.sender] = _gscales.maxscale;
        delete unclaimedYields[msg.sender];
        gscales = _gscales;

        if (block.timestamp >= maturity) {
            // If matured, burn YT and add the principal portion to the accrued yield
            accruedInTarget += _computeTargetBelongsToYT(_gscales, yBal);
            _yt.burn(msg.sender, yBal);
        }

        // Convert the accrued yield in Target token to underlying token and transfer it to the `msg.sender`
        // Target token may revert if zero-amount transfer is not allowed.
        _target.safeTransfer(address(adapter), accruedInTarget);
        (uint256 accrued, ) = adapter.prefundedRedeem(msg.sender);
        emit Collect(msg.sender, accruedInTarget);
        return accrued;
    }

    /* ================== VIEW METHODS =================== */

    /// @inheritdoc ITranche
    /// @dev This function is useful for off-chain services to get the accrued yield of a user.
    /// @dev This function must not revert in any case.
    function previewCollect(address account) external view returns (uint256) {
        uint256 _lscale = lscales[account];
        uint256 accruedInTarget = unclaimedYields[account];

        // If the lscale is 0, it means the user have never hold any YT before
        if (_lscale == 0) return 0;

        GlobalScales memory _gscales = gscales;
        uint256 cscale = _updateGlobalScalesCache(_gscales);

        // At this point, the scales cache is up to date.
        // Calculate the accrued yield in Target token for `account`

        uint256 yBal = _yt.balanceOf(account);
        accruedInTarget += _computeAccruedInterestInTarget(_gscales.maxscale, _lscale, yBal);

        if (block.timestamp >= maturity) {
            // If matured, add the principal portion to the accrued yield
            accruedInTarget += _computeTargetBelongsToYT(_gscales, yBal);
        }
        // Convert the accrued yield to underlying token
        return accruedInTarget.mulWadDown(cscale);
    }

    /// @inheritdoc IERC5095
    function maxRedeem(address owner) external view override notEntered returns (uint256) {
        // Before maturity, PT can't be redeemed. Return 0.
        if (block.timestamp < maturity) return 0;
        return balanceOf(owner);
    }

    /// @inheritdoc IERC5095
    function maxWithdraw(address owner) external view override returns (uint256 maxUnderlyingAmount) {
        if (block.timestamp < maturity) return 0;
        return convertToUnderlying(balanceOf(owner));
    }

    /// @inheritdoc IERC5095
    function previewRedeem(uint256 principalAmount) external view override returns (uint256 underlyingAmount) {
        if (block.timestamp < maturity) return 0;
        return convertToUnderlying(principalAmount);
    }

    /// @inheritdoc IERC5095
    function previewWithdraw(uint256 underlyingAmount) external view override returns (uint256 principalAmount) {
        if (block.timestamp < maturity) return 0;
        return convertToPrincipal(underlyingAmount);
    }

    /// @inheritdoc IERC5095
    /// @dev Before maturity, the amount of underlying returned is as if the PTs would be at maturity.
    function convertToUnderlying(
        uint256 principalAmount
    ) public view override notEntered returns (uint256 underlyingAmount) {
        GlobalScales memory _gscales = gscales; // Load gscales into memory
        uint128 cscale = adapter.scale().toUint128();
        if (_gscales.mscale == 0) {
            // Simulate the settlement as if it is settled now
            _gscales.mscale = cscale;
            if (cscale > _gscales.maxscale) {
                _gscales.maxscale = cscale;
            }
        }
        uint256 shares = _computeSharesRedeemed(_gscales, principalAmount);

        return shares.mulWadDown(cscale);
    }

    /// @inheritdoc IERC5095
    /// @dev Before maturity, the amount of underlying returned is as if the PTs would be at maturity.
    function convertToPrincipal(uint256 underlyingAmount) public view override notEntered returns (uint256) {
        GlobalScales memory _gscales = gscales; // Load gscales into memory
        uint128 cscale = adapter.scale().toUint128();
        if (_gscales.mscale == 0) {
            // Simulate the settlement as if it is settled now
            _gscales.mscale = cscale;
            if (cscale > _gscales.maxscale) {
                _gscales.maxscale = cscale;
            }
        }
        return _computePrincipalTokenRedeemed(_gscales, underlyingAmount.divWadDown(cscale));
    }

    /* ================== METADATA =================== */

    /// @inheritdoc ITranche
    /// @dev We return the address type instead of IERC20 to avoid additional dependencies for integrators.
    function yieldToken() external view returns (address) {
        return address(_yt);
    }

    /// @inheritdoc IERC5095
    /// @dev We return the address type instead of IERC20 to avoid additional dependencies for integrators.
    function underlying() external view returns (address) {
        return address(_underlying);
    }

    /// @inheritdoc BaseToken
    /// @dev We return the address type instead of IERC20 to avoid additional dependencies for integrators.
    function target() external view override returns (address) {
        return address(_target);
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        string memory tokenName = SafeERC20Namer.tokenName(address(_target));
        return string.concat("Napier Principal Token ", tokenName, "@", _toDateString(maturity));
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        string memory tokenSymbol = SafeERC20Namer.tokenSymbol(address(_target));
        return string.concat("eP-", tokenSymbol, "@", _toDateString(maturity));
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return uDecimals;
    }

    /// @notice get the global scales
    function getGlobalScales() external view notEntered returns (GlobalScales memory) {
        return gscales;
    }

    /// @inheritdoc ITranche
    /// @notice This function is useful for off-chain services to get the series information.
    function getSeries() external view notEntered returns (Series memory) {
        GlobalScales memory _gscales = gscales;
        return
            Series({
                underlying: address(_underlying),
                target: address(_target),
                yt: address(_yt),
                adapter: address(adapter),
                mscale: _gscales.mscale,
                maxscale: _gscales.maxscale,
                tilt: tilt.toUint64(),
                issuanceFee: issuanceFeeBps.toUint64(),
                maturity: maturity.toUint64()
            });
    }

    /* ================== PERMISSIONED METHODS =================== */

    /// @notice Claim accumulated issuance fees. Redeem the fees in underlying.
    /// @dev Only callable by management
    /// @return Issuance fees in units of underlying token (e.g DAI)
    function claimIssuanceFees() external onlyManagement returns (uint256) {
        uint256 fees = issuanceFees - 1; // Ensure that the slot is not cleared, for gas savings
        issuanceFees = 1;
        _target.safeTransfer(address(adapter), fees);
        (uint256 feesInUnderlying, ) = adapter.prefundedRedeem(feeRecipient);
        return feesInUnderlying;
    }

    function setFeeRecipient(address _feeRecipient) external onlyManagement {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /// @notice Rescue a token from the contract. Usually used for tokens sent by a mistake.
    /// @param token erc20 token
    /// @param recipient recipient of the tokens
    function recoverERC20(address token, address recipient) external onlyManagement {
        if (token == address(_target)) revert ProtectedToken();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, balance);
    }

    /// @notice Pause issue, collect and updateUnclaimedYield
    /// @dev only callable by management
    function pause() external onlyManagement {
        _pause();
    }

    /// @notice Unpause issue, collect and updateUnclaimedYield
    /// @dev only callable by management
    function unpause() external onlyManagement {
        _unpause();
    }

    /* ================== INTERNAL METHODS =================== */
    /* ================== UTIL METHODS =================== */

    function _burnFrom(address owner, uint256 amount) internal {
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, amount);
        }
        _burn(owner, amount);
    }

    /// @notice Updates the global scales cache.
    /// If the maturity has passed, updates the maturity scale `mscale` if it's not updated yet. (Settlement)
    /// @return cscale The current scale of the adapter.
    function _updateGlobalScalesCache(GlobalScales memory _cache) internal view returns (uint256) {
        // Get the current scale of the adapter
        uint256 cscale = adapter.scale();
        if (_cache.mscale != 0) return cscale; // Skip if already settled

        // If mscale == 0 and maturity has passed, settle the _cache.
        if (block.timestamp >= maturity) {
            _cache.mscale = cscale.toUint128();
        }
        // Update the _cache's maxscale
        if (cscale > _cache.maxscale) {
            _cache.maxscale = cscale.toUint128();
        }
        return cscale;
    }

    /// @notice Computes the amount of Target tokens to be redeemed for the given PT amount.
    /// @dev This function is responsible for the logic of computing the amount of Target tokens to be redeemed.
    /// The logic is as follows: 1) sunny day (ideal case), 2) not sunny day.
    /// @param _gscales Local cache of global scales.
    /// @param _principalAmount PT amount to redeem in units of underlying tokens.
    function _computeSharesRedeemed(
        GlobalScales memory _gscales,
        uint256 _principalAmount
    ) internal view returns (uint256) {
        // Hackmd: F1
        // If it's a sunny day, PT holders lose `tilt` % of the principal amount.
        if ((_gscales.mscale * MAX_BPS) / _gscales.maxscale >= oneSubTilt) {
            // Formula: shares = principalAmount * (1 - tilt) / mscale
            return ((_principalAmount * oneSubTilt) / MAX_BPS).divWadDown(_gscales.mscale);
        } else {
            // If it's not a sunny day,
            // Formula: shares = principalAmount / maxscale
            return _principalAmount.divWadDown(_gscales.maxscale);
        }
    }

    /// @notice Computes the amount of PT to be redeemed for the given shares amount.
    /// @param _gscales Local cache of global scales.
    /// @param _shares Amount of Target tokens equivalent to the amount of PT to be redeemed (in units of Target tokens).
    function _computePrincipalTokenRedeemed(
        GlobalScales memory _gscales,
        uint256 _shares
    ) internal view returns (uint256) {
        // Hackmd: F1
        // If it's a sunny day, PT holders lose `tilt` % of the principal amount.
        if ((_gscales.mscale * MAX_BPS) / _gscales.maxscale >= oneSubTilt) {
            // Formula: principalAmount = (shares * mscale * MAX_BPS) / oneSubTilt
            return (_shares.mulWadDown(_gscales.mscale) * MAX_BPS) / oneSubTilt;
        }
        // If it's not a sunny day,
        // Formula: principalAmount = shares * maxscale
        return _shares.mulWadDown(_gscales.maxscale);
    }

    /// @notice Computes the amount of Target token that belongs to YT.
    /// @param _gscales Local cache of global scales.
    /// @param _yBal The balance of YT for the user.
    function _computeTargetBelongsToYT(GlobalScales memory _gscales, uint256 _yBal) internal view returns (uint256) {
        // Hackmd: F3
        // If it's a sunny day, PT holders lose `tilt` % of the principal amount and YT holders get the amount.
        if ((_gscales.mscale * MAX_BPS) / _gscales.maxscale >= oneSubTilt) {
            // Formula: targetBelongsToYT = yBal / maxscale - (1 - tilt) * yBal / mscale
            return _yBal.divWadDown(_gscales.maxscale) - ((_yBal * oneSubTilt) / MAX_BPS).divWadDown(_gscales.mscale);
        }
        return 0;
    }

    /// @notice Computes the amount of accrued interest in the Target.
    /// e.g. if the Target scale increases by 5% since the last time the account collected and the account has 100 YT,
    /// then the account will receive 100 * 5% = 5 Target as interest, which is equivalent to 5 * `maxscale` Underlying now.
    /// @dev `_maxscale` should be updated before calling this function.
    /// @param _maxscale The latest max scale of the series (assume non-zero).
    /// @param _lscale The user-stored last scale (_lscale MUST be non-zero).
    /// @param _yBal The user's current balance of Yield Token.
    /// @return accruedInTarget The accrued interest in Target token. (rounded down)
    function _computeAccruedInterestInTarget(
        uint256 _maxscale,
        uint256 _lscale,
        uint256 _yBal
    ) internal pure returns (uint256) {
        // Hackmd: F5, F7
        // Compute how much underlying has accrued since the last time this user collected, in units of Target.
        // The scale is the amount of underlying per Target. `underlying = shares * scale`.
        // Hackmd: F6
        // Reminder: _lscale is the scale of the last time the user collected their yield.
        // If the scale (price) of Target has increased since then (_maxscale > _lscale), the user has accrued some interest.

        // The balance of YT `_yBal` represents the underlying amount a user has deposited into the yield source at the last collection.
        // At the last collection, `_yBal` underlying was worth `_yBal / _lscale` in units of Target.
        // Now, `_yBal` underlying is worth `_yBal / effMaxscale` in units of Target.
        // The difference is the amount of interest accrued in units of Target.
        // NOTE: The `yBal / maxscale` should be rounded up, which lets the `accrued` value round up, i.e., toward the protocol (against a user).
        //       This is to prevent a user from withdrawing more shares than this contract has.
        uint256 sharesNow = _yBal.divWadUp(_maxscale); // rounded up to prevent a user from withdrawing more shares than this contract has.
        uint256 sharesDeposited = _yBal.divWadDown(_lscale);
        if (sharesDeposited <= sharesNow) {
            return 0;
        }
        return sharesDeposited - sharesNow; // rounded down
    }
}