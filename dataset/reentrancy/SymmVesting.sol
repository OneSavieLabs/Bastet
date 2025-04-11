// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import "./Vesting.sol";
import "./interfaces/IPermit2.sol";
import "./interfaces/IMintableERC20.sol";
import { IPool } from "./interfaces/IPool.sol";
import { IRouter } from "./interfaces/IRouter.sol";

/// @title SymmVesting Contract
/// @notice Extends Vesting to add liquidity functionality for SYMM and SYMM LP tokens.
/// @dev Inherits pausable functionality and vesting plan management from Vesting.
contract SymmVesting is Vesting {
	using SafeERC20 for IERC20;
	using VestingPlanOps for VestingPlan;

	//--------------------------------------------------------------------------
	// Events
	//--------------------------------------------------------------------------

	/// @notice Emitted when liquidity is added.
	/// @param user The address adding liquidity.
	/// @param symmAmount The amount of SYMM used.
	/// @param usdcAmount The amount of USDC required.
	/// @param lpAmount The amount of LP tokens received.
	event LiquidityAdded(address indexed user, uint256 symmAmount, uint256 usdcAmount, uint256 lpAmount);

	//--------------------------------------------------------------------------
	// Errors
	//--------------------------------------------------------------------------

	error SlippageExceeded();
	error ZeroDivision();
	error MaxUsdcExceeded();

	//--------------------------------------------------------------------------
	// State Variables
	//--------------------------------------------------------------------------

	IPool public POOL;
	IRouter public ROUTER;
	IPermit2 public PERMIT2;
	address public VAULT;
	address public SYMM;
	address public USDC;
	address public SYMM_LP;

	//--------------------------------------------------------------------------
	// Initialization
	//--------------------------------------------------------------------------

	/// @notice Initializes the SymmVesting contract.
	/// @param admin Address to receive the admin and role assignments.
	/// @param _lockedClaimPenaltyReceiver Address that receives the locked claim penalty.
	function initialize(
		address admin,
		address _lockedClaimPenaltyReceiver,
		address _pool,
		address _router,
		address _permit2,
		address _vault,
		address _symm,
		address _usdc,
		address _symm_lp
	) public initializer {
		if (
			admin == address(0) ||
			_lockedClaimPenaltyReceiver == address(0) ||
			_pool == address(0) ||
			_router == address(0) ||
			_permit2 == address(0) ||
			_vault == address(0) ||
			_symm == address(0) ||
			_usdc == address(0) ||
			_symm_lp == address(0)
		) revert ZeroAddress();
		__vesting_init(admin, 500000000000000000, _lockedClaimPenaltyReceiver);
		POOL = IPool(_pool);
		ROUTER = IRouter(_router);
		PERMIT2 = IPermit2(_permit2);
		VAULT = _vault;
		SYMM = _symm;
		USDC = _usdc;
		SYMM_LP = _symm_lp;
	}

	//--------------------------------------------------------------------------
	// Liquidity for Vesting Functions
	//--------------------------------------------------------------------------

	/// @notice Adds liquidity by converting a portion of SYMM vesting into SYMM LP tokens.
	/// @dev Claims any unlocked tokens from SYMM and SYMM LP vesting plans.
	///      Reverts if the SYMM vesting plan's locked amount is insufficient.
	/// @param amount The amount of SYMM to use for adding liquidity.
	/// @param minLpAmount The minimum acceptable LP token amount to receive (for slippage protection).
	/// @param maxUsdcIn The maximum amount of USDC that can be used (for price protection).
	/// @return amountsIn Array of token amounts used (SYMM and USDC).
	/// @return lpAmount The amount of LP tokens minted.
	function addLiquidity(
		uint256 amount,
		uint256 minLpAmount,
		uint256 maxUsdcIn
	) external whenNotPaused nonReentrant returns (uint256[] memory amountsIn, uint256 lpAmount) {
		return _addLiquidityProcess(amount, minLpAmount, maxUsdcIn);
	}

	/// @notice Adds liquidity by converting a portion of SYMM vesting into SYMM LP tokens.
	/// @dev Claims any unlocked tokens from SYMM and SYMM LP vesting plans.
	///      Reverts if the SYMM vesting plan's locked amount is insufficient.
	/// @param percentage The percentage of locked SYMM to use for adding liquidity.
	/// @param minLpAmount The minimum acceptable LP token amount to receive (for slippage protection).
	/// @param maxUsdcIn The maximum amount of USDC that can be used (for price protection).
	/// @return amountsIn Array of token amounts used (SYMM and USDC).
	/// @return lpAmount The amount of LP tokens minted.
	function addLiquidityByPercentage(
		uint256 percentage,
		uint256 minLpAmount,
		uint256 maxUsdcIn
	) external whenNotPaused nonReentrant returns (uint256[] memory amountsIn, uint256 lpAmount) {
		uint256 amount = (getLockedAmountsForToken(msg.sender, SYMM) * percentage) / 1e18;
		return _addLiquidityProcess(amount, minLpAmount, maxUsdcIn);
	}

	function _addLiquidityProcess(
		uint256 amount,
		uint256 minLpAmount,
		uint256 maxUsdcIn
	) internal returns (uint256[] memory amountsIn, uint256 lpAmount) {
		// Claim any unlocked SYMM tokens first.
		_claimUnlockedToken(SYMM, msg.sender);

		VestingPlan storage symmVestingPlan = vestingPlans[SYMM][msg.sender];
		uint256 symmLockedAmount = symmVestingPlan.lockedAmount();
		if (symmLockedAmount < amount) revert InvalidAmount();

		_ensureSufficientBalance(SYMM, amount);

		// Add liquidity to the pool.
		(amountsIn, lpAmount) = _addLiquidity(amount, minLpAmount, maxUsdcIn);

		// Update SYMM vesting plan by reducing the locked amount.
		symmVestingPlan.resetAmount(symmLockedAmount - amountsIn[0]);

		// Claim any unlocked SYMM LP tokens.
		_claimUnlockedToken(SYMM_LP, msg.sender);

		VestingPlan storage lpVestingPlan = vestingPlans[SYMM_LP][msg.sender];

		address[] memory users = new address[](1);
		users[0] = msg.sender;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = lpVestingPlan.lockedAmount() + lpAmount;

		// Increase the locked amount by the received LP tokens.
		if (lpVestingPlan.isSetup()) {
			_resetVestingPlans(SYMM_LP, users, amounts);
		} else {
			_setupVestingPlans(SYMM_LP, block.timestamp, symmVestingPlan.endTime, users, amounts);
		}

		emit LiquidityAdded(msg.sender, amountsIn[0], amountsIn[1], lpAmount);
	}

	/// @notice Internal function to add liquidity using a specified amount of SYMM.
	/// @dev Transfers USDC from the caller, approves token spending for the VAULT, and interacts with the liquidity router.
	/// @param symmIn The amount of SYMM to contribute.
	/// @param minLpAmount The minimum acceptable LP token amount to receive (for slippage protection).
	/// @param maxUsdcIn The maximum amount of USDC that can be used (for price protection).
	/// @return amountsIn Array containing the amounts of SYMM and USDC used.
	/// @return lpAmount The number of LP tokens minted.
	function _addLiquidity(uint256 symmIn, uint256 minLpAmount, uint256 maxUsdcIn) internal returns (uint256[] memory amountsIn, uint256 lpAmount) {
		(uint256 usdcIn, uint256 expectedLpAmount) = getLiquidityQuote(symmIn);

		// Check if usdcIn exceeds maxUsdcIn parameter
		if (maxUsdcIn > 0 && usdcIn > maxUsdcIn) revert MaxUsdcExceeded();

		uint256 minLpAmountWithSlippage = minLpAmount > 0 ? minLpAmount : (expectedLpAmount * 99) / 100; // Default 1% slippage if not specified

		// Retrieve pool tokens. Assumes poolTokens[0] is SYMM and poolTokens[1] is USDC.
		IERC20[] memory poolTokens = POOL.getTokens();
		(IERC20 symm, IERC20 usdc) = (poolTokens[0], poolTokens[1]);

		// Pull USDC from the user and approve the VAULT.
		usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
		usdc.approve(address(PERMIT2), usdcIn);
		symm.approve(address(PERMIT2), symmIn);
		PERMIT2.approve(SYMM, address(ROUTER), uint160(symmIn), uint48(block.timestamp));
		PERMIT2.approve(USDC, address(ROUTER), uint160(usdcIn), uint48(block.timestamp));

		amountsIn = new uint256[](2);
		amountsIn[0] = symmIn;
		amountsIn[1] = usdcIn;

		uint256 initialLpBalance = IERC20(SYMM_LP).balanceOf(address(this));

		// Call the router to add liquidity.
		amountsIn = ROUTER.addLiquidityProportional(
			address(POOL),
			amountsIn,
			expectedLpAmount,
			false, // wethIsEth: bool
			"" // userData: bytes
		);

		// Return unused usdc
		if (usdcIn - amountsIn[1] > 0) usdc.safeTransfer(msg.sender, usdcIn - amountsIn[1]);

		// Calculate actual LP tokens received by comparing balances.
		uint256 newLpBalance = IERC20(SYMM_LP).balanceOf(address(this));
		lpAmount = newLpBalance - initialLpBalance;

		if (lpAmount < minLpAmountWithSlippage) revert SlippageExceeded();
	}

	/// @notice Calculates the ceiling of (a * b) divided by c.
	/// @dev Computes ceil(a * b / c) using the formula (a * b - 1) / c + 1 when the product is nonzero.
	///      Returns 0 if a * b equals 0.
	/// @param a The multiplicand.
	/// @param b The multiplier.
	/// @param c The divisor.
	/// @return result The smallest integer greater than or equal to (a * b) / c.
	function _mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256 result) {
		// This check is required because Yul's div doesn't revert on c==0.
		if (c == 0) revert ZeroDivision();

		// Multiple overflow protection is done by Solidity 0.8.x.
		uint256 product = a * b;

		// The traditional divUp formula is:
		// divUp(x, y) := (x + y - 1) / y
		// To avoid intermediate overflow in the addition, we distribute the division and get:
		// divUp(x, y) := (x - 1) / y + 1
		// Note that this requires x != 0, if x == 0 then the result is zero
		//
		// Equivalent to:
		// result = a == 0 ? 0 : (a * b - 1) / c + 1
		assembly ("memory-safe") {
			result := mul(iszero(iszero(product)), add(div(sub(product, 1), c), 1))
		}
	}

	/// @notice Calculates the USDC required and LP tokens expected for a given SYMM amount.
	/// @dev Uses current pool balances and total supply to compute the liquidity parameters.
	/// @param symmAmount The amount of SYMM.
	/// @return usdcAmount The USDC required.
	/// @return lpAmount The LP tokens that will be minted.
	function getLiquidityQuote(uint256 symmAmount) public view returns (uint256 usdcAmount, uint256 lpAmount) {
		uint256[] memory balances = POOL.getCurrentLiveBalances();
		uint256 totalSupply = POOL.totalSupply();
		uint256 symmBalance = balances[0];
		uint256 usdcBalance = balances[1];

		usdcAmount = (symmAmount * usdcBalance) / symmBalance;
		usdcAmount = _mulDivUp(usdcAmount, 1e18, 1e30);
		lpAmount = (symmAmount * totalSupply) / symmBalance;
	}

	function _mintTokenIfPossible(address token, uint256 amount) internal override {
		if (token == SYMM) IMintableERC20(token).mint(address(this), amount);
	}
}
