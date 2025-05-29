// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import {ImmutableArgs} from "clones-with-immutable-args/ImmutableArgs.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IUniswapV3MintCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {LIQUIDATION_GRACE_PERIOD} from "./libraries/constants/Constants.sol";
import {Q128} from "./libraries/constants/Q.sol";
import {BalanceSheet, Assets, Prices} from "./libraries/BalanceSheet.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {square, mulDiv128} from "./libraries/MulDiv.sol";
import {extract} from "./libraries/Positions.sol";
import {TickMath} from "./libraries/TickMath.sol";

import {Factory} from "./Factory.sol";
import {Lender} from "./Lender.sol";
import {VolatilityOracle} from "./VolatilityOracle.sol";

interface ILiquidator {
    receive() external payable;

    function swap1For0(bytes calldata data, uint256 received1, uint256 expected0) external;

    function swap0For1(bytes calldata data, uint256 received0, uint256 expected1) external;
}

interface IManager {
    /**
     * @notice Gives the `IManager` full control of the `Borrower`. Called within `Borrower.modify`.
     * @dev In most cases, you'll want to verify that `msg.sender` is, in fact, a `Borrower` using
     * `factory.isBorrower(msg.sender)`.
     * @param data Encoded parameters that were passed to `Borrower.modify`
     * @param owner The owner of the `Borrower`
     * @param positions The `Borrower`'s current Uniswap positions. You can convert them to an array using
     * `Positions.extract`
     * @return Updated positions, encoded using `Positions.zip`. Return 0 if you don't wish to make any changes.
     */
    function callback(bytes calldata data, address owner, uint208 positions) external returns (uint208);
}

/// @title Borrower
/// @author Aloe Labs, Inc.
/// @dev "Test everything; hold fast what is good." - 1 Thessalonians 5:21
contract Borrower is IUniswapV3MintCallback {
    using SafeTransferLib for ERC20;

    /**
     * @notice Most liquidations involve swapping one asset for another. To incentivize such swaps (even in
     * volatile markets) liquidators are rewarded with a 5% bonus. To avoid paying that bonus to liquidators,
     * the account owner can listen for this event. Once it's emitted, they have 2 minutes to bring the
     * account back to health. If they fail, the liquidation will proceed.
     * @dev Fortuitous price movements and/or direct `Lender.repay` can bring the account back to health and
     * nullify the immediate liquidation threat, but they will not clear the warning. This means that next
     * time the account is unhealthy, liquidators might skip `warn` and `liquidate` right away. To clear the
     * warning and return to a "clean" state, make sure to call `modify` -- even if the callback is a no-op.
     * @dev The deadline for regaining health (avoiding liquidation) is given by `slot0.unleashLiquidationTime`.
     * If this value is 0, the account is in the aforementioned "clean" state.
     */
    event Warn();

    /**
     * @notice Emitted when the account gets `liquidate`d
     * @param repay0 The amount of `TOKEN0` that was repaid
     * @param repay1 The amount of `TOKEN1` that was repaid
     * @param incentive1 The value of the swap bonus given to the liquidator, expressed in terms of `TOKEN1`
     * @param priceX128 The price at which the liquidation took place
     */
    event Liquidate(uint256 repay0, uint256 repay1, uint256 incentive1, uint256 priceX128);

    enum State {
        Ready,
        Locked,
        InModifyCallback
    }

    uint256 private constant SLOT0_MASK_POSITIONS = 0x000000000000ffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 private constant SLOT0_MASK_UNLEASH   = 0x00ffffffffff0000000000000000000000000000000000000000000000000000; // prettier-ignore
    uint256 private constant SLOT0_MASK_STATE     = 0x7f00000000000000000000000000000000000000000000000000000000000000; // prettier-ignore
    uint256 private constant SLOT0_DIRT           = 0x8000000000000000000000000000000000000000000000000000000000000000; // prettier-ignore

    /// @notice The factory that created this contract
    Factory public immutable FACTORY;

    /// @notice The oracle to use for prices and implied volatility
    VolatilityOracle public immutable ORACLE;

    /// @notice The Uniswap pair in which this `Borrower` can manage positions
    IUniswapV3Pool public immutable UNISWAP_POOL;

    /// @notice The first token of the Uniswap pair
    ERC20 public immutable TOKEN0;

    /// @notice The second token of the Uniswap pair
    ERC20 public immutable TOKEN1;

    /// @notice The lender of `TOKEN0`
    Lender public immutable LENDER0;

    /// @notice The lender of `TOKEN1`
    Lender public immutable LENDER1;

    /**
     * @notice The `Borrower`'s only mutable storage. Lowest 144 bits store the lower/upper bounds of up to 3 Uniswap
     * positions, encoded by `Positions.zip`. Next 64 bits are unused within the `Borrower` and available to users as
     * "free" storage － no additional sstore's. These 208 bits (144 + 64) are passed to `IManager.callback`, and get
     * updated when the callback returns a non-zero value. The next 40 bits are either 0 or `unleashLiquidationTime`,
     * as explained in the `Warn` event docs. The highest 8 bits represent the current `State` enum, plus 128. We add
     * 128 (i.e. set the highest bit to 1) so that the slot is always non-zero, even in the absence of Uniswap
     * positions － this saves gas.
     */
    uint256 public slot0;

    modifier onlyInModifyCallback() {
        require(slot0 & SLOT0_MASK_STATE == uint256(State.InModifyCallback) << 248);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(VolatilityOracle oracle, IUniswapV3Pool pool, Lender lender0, Lender lender1) {
        FACTORY = Factory(msg.sender);
        ORACLE = oracle;
        UNISWAP_POOL = pool;
        LENDER0 = lender0;
        LENDER1 = lender1;

        TOKEN0 = lender0.asset();
        TOKEN1 = lender1.asset();

        assert(pool.token0() == address(TOKEN0) && pool.token1() == address(TOKEN1));
    }

    receive() external payable {}

    function owner() public pure returns (address) {
        return ImmutableArgs.addr();
    }

    /*//////////////////////////////////////////////////////////////
                           MAIN ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Warns the borrower that they're about to be liquidated. NOTE: Liquidators are only
     * forced to call this in cases where the 5% swap bonus is up for grabs.
     * @param oracleSeed The indices of `UNISWAP_POOL.observations` where we start our search for
     * the 30-minute-old (lowest 16 bits) and 60-minute-old (next 16 bits) observations when getting
     * TWAPs. If any of the highest 8 bits are set, we fallback to onchain binary search.
     */
    function warn(uint40 oracleSeed) external {
        uint256 slot0_ = slot0;
        // Essentially `slot0.state == State.Ready && slot0.unleashLiquidationTime == 0`
        require(slot0_ & (SLOT0_MASK_STATE | SLOT0_MASK_UNLEASH) == 0);

        {
            // Fetch prices from oracle
            (Prices memory prices, ) = getPrices(oracleSeed);
            // Tally assets without actually withdrawing Uniswap positions
            Assets memory assets = _getAssets(slot0_, prices, false);
            // Fetch liabilities from lenders
            (uint256 liabilities0, uint256 liabilities1) = _getLiabilities();
            // Ensure only unhealthy accounts get warned
            require(!BalanceSheet.isHealthy(prices, assets, liabilities0, liabilities1), "Aloe: healthy");
        }

        slot0 = slot0_ | ((block.timestamp + LIQUIDATION_GRACE_PERIOD) << 208);
        emit Warn();
    }

    /**
     * @notice Liquidates the borrower, using all available assets to pay down liabilities. If
     * some or all of the payment cannot be made in-kind, `callee` is expected to swap one asset
     * for the other at a venue of their choosing. NOTE: Branches involving callbacks will fail
     * until the borrower has been `warn`ed and the grace period has expired.
     * @dev As a baseline, `callee` receives `address(this).balance / strain` ETH. This amount is
     * intended to cover transaction fees. If the liquidation involves a swap callback, `callee`
     * receives a 5% bonus denominated in the surplus token. In other words, if the two numeric
     * callback arguments were denominated in the same asset, the first argument would be 5% larger.
     * @param callee A smart contract capable of swapping `TOKEN0` for `TOKEN1` and vice versa
     * @param data Encoded parameters that get forwarded to `callee` callbacks
     * @param strain Almost always set to `1` to pay off all debt and receive maximum reward. If
     * liquidity is thin and swap price impact would be too large, you can use higher values to
     * reduce swap size and make it easier for `callee` to do its job. `2` would be half swap size,
     * `3` one third, and so on.
     * @param oracleSeed The indices of `UNISWAP_POOL.observations` where we start our search for
     * the 30-minute-old (lowest 16 bits) and 60-minute-old (next 16 bits) observations when getting
     * TWAPs. If any of the highest 8 bits are set, we fallback to onchain binary search.
     */
    function liquidate(ILiquidator callee, bytes calldata data, uint256 strain, uint40 oracleSeed) external {
        uint256 slot0_ = slot0;
        // Essentially `slot0.state == State.Ready`
        require(slot0_ & SLOT0_MASK_STATE == 0);
        slot0 = slot0_ | (uint256(State.Locked) << 248);

        uint256 priceX128;
        uint256 liabilities0;
        uint256 liabilities1;
        uint256 incentive1;
        {
            // Fetch prices from oracle
            (Prices memory prices, ) = getPrices(oracleSeed);
            priceX128 = square(prices.c);
            // Withdraw Uniswap positions while tallying assets
            Assets memory assets = _getAssets(slot0_, prices, true);
            // Fetch liabilities from lenders
            (liabilities0, liabilities1) = _getLiabilities();
            // Calculate liquidation incentive
            incentive1 = BalanceSheet.computeLiquidationIncentive(
                assets.fixed0 + assets.fluid0C, // total assets0 at `prices.c` (the TWAP)
                assets.fixed1 + assets.fluid1C, // total assets1 at `prices.c` (the TWAP)
                liabilities0,
                liabilities1,
                priceX128
            );
            // Ensure only unhealthy accounts can be liquidated
            require(!BalanceSheet.isHealthy(prices, assets, liabilities0, liabilities1), "Aloe: healthy");
        }

        // NOTE: The health check values assets at the TWAP and is difficult to manipulate. However,
        // the instantaneous price does impact what tokens we receive when burning Uniswap positions.
        // As such, additional calls to `TOKEN0.balanceOf` and `TOKEN1.balanceOf` are required for
        // precise inventory, and we take care not to increase `incentive1`.

        unchecked {
            // Figure out what portion of liabilities can be repaid using existing assets
            uint256 repayable0 = Math.min(liabilities0, TOKEN0.balanceOf(address(this)));
            uint256 repayable1 = Math.min(liabilities1, TOKEN1.balanceOf(address(this)));

            // See what remains (similar to "shortfall" in BalanceSheet)
            liabilities0 -= repayable0;
            liabilities1 -= repayable1;

            // Decide whether to swap or not
            bool shouldSwap;
            assembly ("memory-safe") {
                // If both are zero or neither is zero, there's nothing more to do
                shouldSwap := xor(gt(liabilities0, 0), gt(liabilities1, 0))
                // Divide by `strain` and check again. This second check can generate false positives in cases
                // where one division (not both) floors to 0, which is why we `and()` with the check above.
                liabilities0 := div(liabilities0, strain)
                liabilities1 := div(liabilities1, strain)
                shouldSwap := and(shouldSwap, xor(gt(liabilities0, 0), gt(liabilities1, 0)))
                // If not swapping, set `incentive1 = 0`
                incentive1 := mul(shouldSwap, incentive1)
            }

            if (shouldSwap) {
                uint256 unleashTime = (slot0_ & SLOT0_MASK_UNLEASH) >> 208;
                require(0 < unleashTime && unleashTime < block.timestamp, "Aloe: grace");

                incentive1 /= strain;
                if (liabilities0 > 0) {
                    // NOTE: This value is not constrained to `TOKEN1.balanceOf(address(this))`, so liquidators
                    // are responsible for setting `strain` such that the transfer doesn't revert. This shouldn't
                    // be an issue unless the borrower has already started accruing bad debt.
                    uint256 available1 = mulDiv128(liabilities0, priceX128) + incentive1;

                    TOKEN1.safeTransfer(address(callee), available1);
                    callee.swap1For0(data, available1, liabilities0);

                    repayable0 += liabilities0;
                } else {
                    // NOTE: This value is not constrained to `TOKEN0.balanceOf(address(this))`, so liquidators
                    // are responsible for setting `strain` such that the transfer doesn't revert. This shouldn't
                    // be an issue unless the borrower has already started accruing bad debt.
                    uint256 available0 = Math.mulDiv(liabilities1 + incentive1, Q128, priceX128);

                    TOKEN0.safeTransfer(address(callee), available0);
                    callee.swap0For1(data, available0, liabilities1);

                    repayable1 += liabilities1;
                }
            }

            _repay(repayable0, repayable1);
            slot0 = (slot0_ & SLOT0_MASK_POSITIONS) | SLOT0_DIRT;

            payable(callee).transfer(address(this).balance / strain);
            emit Liquidate(repayable0, repayable1, incentive1, priceX128);
        }
    }

    /**
     * @notice Allows the owner to manage their account by handing control to some `callee`. Inside the
     * callback `callee` has access to all sub-commands (`uniswapDeposit`, `uniswapWithdraw`, `transfer`,
     * `borrow`, `repay`, and `withdrawAnte`). Whatever `callee` does, the account MUST be healthy
     * after the callback.
     * @param callee The smart contract that will get temporary control of this account
     * @param data Encoded parameters that get forwarded to `callee`
     * @param oracleSeed The indices of `UNISWAP_POOL.observations` where we start our search for
     * the 30-minute-old (lowest 16 bits) and 60-minute-old (next 16 bits) observations when getting
     * TWAPs. If any of the highest 8 bits are set, we fallback to onchain binary search.
     */
    function modify(IManager callee, bytes calldata data, uint40 oracleSeed) external payable {
        uint256 slot0_ = slot0;
        // Essentially `slot0.state == State.Ready && msg.sender == owner()`
        require(slot0_ & SLOT0_MASK_STATE == 0 && msg.sender == owner(), "Aloe: only owner");

        slot0 = slot0_ | (uint256(State.InModifyCallback) << 248);
        {
            uint208 positions = callee.callback(data, msg.sender, uint208(slot0_));
            assembly ("memory-safe") {
                // Equivalent to `if (positions > 0) slot0_ = positions`
                slot0_ := or(positions, mul(slot0_, iszero(positions)))
            }
        }
        slot0 = (slot0_ & SLOT0_MASK_POSITIONS) | SLOT0_DIRT;

        (uint256 liabilities0, uint256 liabilities1) = _getLiabilities();
        if (liabilities0 > 0 || liabilities1 > 0) {
            (uint208 ante, uint8 nSigma, uint8 mtd, uint32 pausedUntilTime) = FACTORY.getParameters(UNISWAP_POOL);
            (Prices memory prices, bool seemsLegit) = _getPrices(oracleSeed, nSigma, mtd);

            require(
                seemsLegit && (block.timestamp > pausedUntilTime) && (address(this).balance >= ante),
                "Aloe: missing ante / sus price"
            );

            Assets memory assets = _getAssets(slot0_, prices, false);
            require(BalanceSheet.isHealthy(prices, assets, liabilities0, liabilities1), "Aloe: unhealthy");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SUB-COMMANDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Callback for Uniswap V3 pool; necessary for `uniswapDeposit` to work
     * @param amount0 The amount of `TOKEN0` owed to the `UNISWAP_POOL`
     * @param amount1 The amount of `TOKEN1` owed to the `UNISWAP_POOL`
     */
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(UNISWAP_POOL));

        if (amount0 > 0) TOKEN0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) TOKEN1.safeTransfer(msg.sender, amount1);
    }

    /**
     * @notice Allows the `owner()` to add liquidity to a Uniswap position (or create a new one). Only works
     * within the `modify` callback.
     * @dev The `LiquidityAmounts` library can help convert underlying amounts to units of `liquidity`.
     * NOTE: Depending on your use-case, it may be more gas-efficient to call `UNISWAP_POOL.mint` in your
     * own contract, instead of doing `uniswapDeposit` inside of `modify`'s callback. As long as you set
     * this `Borrower` as the recipient in `UNISWAP_POOL.mint`, the result is the same.
     * @param lower The tick at the position's lower bound
     * @param upper The tick at the position's upper bound
     * @param liquidity The amount of liquidity to add, in Uniswap's internal units
     * @return amount0 The precise amount of `TOKEN0` that went into the Uniswap position
     * @return amount1 The precise amount of `TOKEN1` that went into the Uniswap position
     */
    function uniswapDeposit(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external onlyInModifyCallback returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = UNISWAP_POOL.mint(address(this), lower, upper, liquidity, "");
    }

    /**
     * @notice Allows the `owner()` to withdraw liquidity from one of their Uniswap positions. Only works within
     * the `modify` callback.
     * @dev The `LiquidityAmounts` library can help convert underlying amounts to units of `liquidity`
     * @param lower The tick at the position's lower bound
     * @param upper The tick at the position's upper bound
     * @param liquidity The amount of liquidity to remove, in Uniswap's internal units. Pass 0 to collect
     * fees without burning any liquidity.
     * @param recipient Receives the tokens from Uniswap. Usually the address of this `Borrower` account.
     * @return burned0 The amount of `TOKEN0` that was removed from the Uniswap position
     * @return burned1 The amount of `TOKEN1` that was removed from the Uniswap position
     * @return collected0 Equal to `burned0` plus any earned `TOKEN0` fees that hadn't yet been claimed
     * @return collected1 Equal to `burned1` plus any earned `TOKEN1` fees that hadn't yet been claimed
     */
    function uniswapWithdraw(
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address recipient
    ) external onlyInModifyCallback returns (uint256 burned0, uint256 burned1, uint256 collected0, uint256 collected1) {
        (burned0, burned1, collected0, collected1) = _uniswapWithdraw(lower, upper, liquidity, recipient);
    }

    /**
     * @notice The most flexible sub-command. Allows the `owner()` to transfer amounts of `TOKEN0` and `TOKEN1`
     * to any `recipient` they want. Only works within the `modify` callback.
     * @param amount0 The amount of `TOKEN0` to transfer
     * @param amount1 The amount of `TOKEN1` to transfer
     * @param recipient Receives the transferred tokens
     */
    function transfer(uint256 amount0, uint256 amount1, address recipient) external onlyInModifyCallback {
        if (amount0 > 0) TOKEN0.safeTransfer(recipient, amount0);
        if (amount1 > 0) TOKEN1.safeTransfer(recipient, amount1);
    }

    /**
     * @notice Allows the `owner()` to borrow funds from `LENDER0` and `LENDER1`. Only works within the `modify`
     * callback.
     * @dev If `amount0 > 0` and interest hasn't yet accrued in this block for `LENDER0`, it will accrue
     * prior to processing your new borrow. Same goes for `amount1 > 0` and `LENDER1`.
     * @param amount0 The amount of `TOKEN0` to borrow
     * @param amount1 The amount of `TOKEN1` to borrow
     * @param recipient Receives the borrowed tokens. Usually the address of this `Borrower` account.
     */
    function borrow(uint256 amount0, uint256 amount1, address recipient) external onlyInModifyCallback {
        if (amount0 > 0) LENDER0.borrow(amount0, recipient);
        if (amount1 > 0) LENDER1.borrow(amount1, recipient);
    }

    /**
     * @notice Allows the `owner()` to repay debts to `LENDER0` and `LENDER1`. Only works within the `modify`
     * callback.
     * @dev This is technically unnecessary since you could call `Lender.repay` directly, specifying this
     * contract as the `beneficiary` and using the `transfer` sub-command to make payments. We include it
     * because it's convenient and gas-efficient for common use-cases.
     * @param amount0 The amount of `TOKEN0` to repay
     * @param amount1 The amount of `TOKEN1` to repay
     */
    function repay(uint256 amount0, uint256 amount1) external onlyInModifyCallback {
        _repay(amount0, amount1);
    }

    /**
     * @notice Allows the `owner()` to withdraw their ante. Only works within the `modify` callback.
     * @param recipient Receives the ante (as Ether)
     */
    function withdrawAnte(address payable recipient) external onlyInModifyCallback {
        // WARNING: External call to user-specified address
        recipient.transfer(address(this).balance);
    }

    /**
     * @notice Allows the `owner()` to perform arbitrary transfers. Useful for rescuing misplaced funds. Only
     * works within the `modify` callback.
     * @param token The ERC20 token to transfer
     * @param amount The amount to transfer
     * @param recipient Receives the transferred tokens
     */
    function rescue(ERC20 token, uint256 amount, address recipient) external onlyInModifyCallback {
        // WARNING: External call to user-specified address
        token.safeTransfer(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             BALANCE SHEET
    //////////////////////////////////////////////////////////////*/

    function getUniswapPositions() external view returns (int24[] memory) {
        return extract(slot0);
    }

    /**
     * @notice Summarizes all oracle data pertinent to account health
     * @dev If `seemsLegit == false`, you can call `Factory.pause` to temporarily disable borrows
     * @param oracleSeed The indices of `UNISWAP_POOL.observations` where we start our search for
     * the 30-minute-old (lowest 16 bits) and 60-minute-old (next 16 bits) observations when getting
     * TWAPs. If any of the highest 8 bits are set, we fallback to onchain binary search.
     * @return prices The probe prices currently being used to evaluate account health
     * @return seemsLegit Whether the Uniswap TWAP seems to have been manipulated or not
     */
    function getPrices(uint40 oracleSeed) public view returns (Prices memory prices, bool seemsLegit) {
        (, uint8 nSigma, uint8 manipulationThresholdDivisor, ) = FACTORY.getParameters(UNISWAP_POOL);
        (prices, seemsLegit) = _getPrices(oracleSeed, nSigma, manipulationThresholdDivisor);
    }

    function _getPrices(
        uint40 oracleSeed,
        uint8 nSigma,
        uint8 manipulationThresholdDivisor
    ) private view returns (Prices memory prices, bool seemsLegit) {
        uint56 metric;
        uint256 iv;
        // compute current price and volatility
        (metric, prices.c, iv) = ORACLE.consult(UNISWAP_POOL, oracleSeed);
        // compute prices at which solvency will be checked
        (prices.a, prices.b, seemsLegit) = BalanceSheet.computeProbePrices(
            metric,
            prices.c,
            iv,
            nSigma,
            manipulationThresholdDivisor
        );
    }

    function _getAssets(uint256 slot0_, Prices memory prices, bool withdraw) private returns (Assets memory assets) {
        assets.fixed0 = TOKEN0.balanceOf(address(this));
        assets.fixed1 = TOKEN1.balanceOf(address(this));

        int24[] memory positions = extract(slot0_);
        uint256 count = positions.length;
        unchecked {
            for (uint256 i; i < count; i += 2) {
                // Load lower and upper ticks from the `positions` array
                int24 l = positions[i];
                int24 u = positions[i + 1];
                // Fetch amount of `liquidity` in the position
                (uint128 liquidity, , , , ) = UNISWAP_POOL.positions(keccak256(abi.encodePacked(address(this), l, u)));

                if (liquidity == 0) continue;

                // Compute lower and upper sqrt ratios
                uint160 L = TickMath.getSqrtRatioAtTick(l);
                uint160 U = TickMath.getSqrtRatioAtTick(u);

                // Compute the value of `liquidity` (in terms of token1) at both probe prices
                assets.fluid1A += LiquidityAmounts.getValueOfLiquidity(prices.a, L, U, liquidity);
                assets.fluid1B += LiquidityAmounts.getValueOfLiquidity(prices.b, L, U, liquidity);

                // Compute what amounts underlie `liquidity` at the current TWAP
                (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(prices.c, L, U, liquidity);
                assets.fluid0C += amount0;
                assets.fluid1C += amount1;

                if (!withdraw) continue;

                // Withdraw all `liquidity` from the position
                _uniswapWithdraw(l, u, liquidity, address(this));
            }
        }
    }

    function _getLiabilities() private view returns (uint256 amount0, uint256 amount1) {
        amount0 = LENDER0.borrowBalanceStored(address(this));
        amount1 = LENDER1.borrowBalanceStored(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _uniswapWithdraw(
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address recipient
    ) private returns (uint256 burned0, uint256 burned1, uint256 collected0, uint256 collected1) {
        (burned0, burned1) = UNISWAP_POOL.burn(lower, upper, liquidity);
        (collected0, collected1) = UNISWAP_POOL.collect(recipient, lower, upper, type(uint128).max, type(uint128).max);
    }

    function _repay(uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) {
            TOKEN0.safeTransfer(address(LENDER0), amount0);
            LENDER0.repay(amount0, address(this));
        }
        if (amount1 > 0) {
            TOKEN1.safeTransfer(address(LENDER1), amount1);
            LENDER1.repay(amount1, address(this));
        }
    }
}
