// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { Babylonian } from "./vendor0.8/uniswap/Babylonian.sol";
import { FullMath, LiquidityAmounts } from "./vendor0.8/uniswap/LiquidityAmounts.sol";
import { TickMath } from "./vendor0.8/uniswap/TickMath.sol";
import { PositionKey } from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import { ErrLib } from "./libraries/ErrLib.sol";
import { IMultiStrategy } from "./interfaces/IMultiStrategy.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

// import "hardhat/console.sol";

contract Multipool is Ownable, ERC20 {
    error InvalidManaging();
    error InvalidFee(uint24 fee);

    enum MANAGING {
        MAXTOTALSUPPLY,
        PROTOCOLFEEWEIGHT,
        OPERATOR,
        TWAPDURATION,
        MAXTWAPDEVIATION
    }

    struct Slot0Data {
        int24 tick;
        uint160 currentSqrtRatioX96;
    }

    struct PositionInfo {
        int24 lowerTick;
        int24 upperTick;
        uint24 poolFeeAmt;
        uint256 weight;
        address poolAddress;
        bytes32 positionKey;
    }

    struct RebalanceParams {
        // The direction of the swap, true for token0 to token1, false for token1 to token0
        bool zeroForOne;
        // Aggregator's router address
        address swapTarget;
        // The amount of the swap
        uint amountIn;
        // Aggregator's data that stores pathes and amounts swap through
        bytes swapData;
    }

    struct UnderlyingPool {
        int24 tickSpacing;
        address poolAddress;
    }

    struct FeeGrowth {
        uint256 accPerShare0;
        uint256 accPerShare1;
        uint256 gmiAccPerShare0;
        uint256 gmiAccPerShare1;
    }

    IUniswapV3Factory public immutable underlyingV3Factory;
    uint24[] public fees;
    bool private entered;
    address private constant burnAddress = 0x000000000000000000000000000000000000dEaD;
    IMultiStrategy public immutable strategy;
    uint256 public constant MAX_WEIGHT_UINT256 = 10000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant MINIMUM_AMOUNT = 1000_000;
    address public immutable multiFactory;
    address public immutable token0;
    address public immutable token1;

    address operator;

    uint256 public protocolFeeWeightMax = 2000; //20 %
    uint256 public protocolFeeWeight = 2000;

    uint256 public maxTotalSupply = 1e20;

    uint256 public maxTwapDeviation = 100; // 1%

    uint32 public twapDuration = 150;
    /**
     * @dev The accumulated fee per share of liquidity multiplied by FixedPoint128.Q128.
     * Tthe amount of pending fees per share should be added to the userRewardDebt variable.
     */
    FeeGrowth public feesGrowthInsideLastX128;

    //      fee =>poolAddress
    mapping(uint24 => UnderlyingPool) public underlyingTrustedPools;

    mapping(address => bool) public approvedTargets;

    PositionInfo[] public multiPosition;

    event Deposit(address user, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Withdraw(address user, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Rebalance(
        uint256 reserve0Before,
        uint256 reserve1Before,
        uint256 reserve0,
        uint256 reserve1,
        uint256 swappedOut
    );
    event SwapTargetApproved(address indexed target, bool approved);
    event ParamChanged(MANAGING managing, uint param);
    event TrustedPoolAdded(uint24 fee, address poolAddress);

    constructor(
        address _token0,
        address _token1,
        address manager,
        address _underlyingV3Factory,
        IMultiStrategy _strategy,
        string memory _name,
        string memory _symbol,
        uint24[] memory _fees
    ) ERC20(_name, _symbol) {
        IUniswapV3Factory factory = IUniswapV3Factory(_underlyingV3Factory);

        for (uint256 i = 0; i < _fees.length; ) {
            _addUnderlyingPool(_fees[i], _token0, _token1, factory);
            unchecked {
                ++i;
            }
        }
        underlyingV3Factory = factory;

        multiFactory = msg.sender;

        strategy = _strategy;
        token0 = _token0;
        token1 = _token1;

        _transferOwnership(manager);
        operator = manager;
    }

    modifier nonReentrant() {
        require(!entered, "RC");
        entered = true;
        _;
        entered = false;
    }

    function addUnderlyingPool(uint24 fee) external onlyOwner {
        _addUnderlyingPool(fee, token0, token1, underlyingV3Factory);
    }

    function _addUnderlyingPool(
        uint24 _fee,
        address _token0,
        address _token1,
        IUniswapV3Factory _factory
    ) private {
        address poolAddress = _factory.getPool(_token0, _token1, _fee);

        if (poolAddress == address(0)) {
            revert InvalidFee(_fee);
        }
        underlyingTrustedPools[_fee] = UnderlyingPool({
            tickSpacing: IUniswapV3Pool(poolAddress).tickSpacing(),
            poolAddress: poolAddress
        });
        fees.push(_fee);
        emit TrustedPoolAdded(_fee, poolAddress);
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        ErrLib.requirement(
            success && (data.length == 0 || abi.decode(data, (bool))),
            ErrLib.ErrorCode.ERC20_TRANSFER_DID_NOT_SUCCEED
        );
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        ErrLib.requirement(
            success && (data.length == 0 || abi.decode(data, (bool))),
            ErrLib.ErrorCode.ERC20_TRANSFER_FROM_DID_NOT_SUCCEED
        );
    }

    function _safeApprove(address token, address spender, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        ErrLib.requirement(
            success && (data.length == 0 || abi.decode(data, (bool))),
            ErrLib.ErrorCode.ERC20_APPROVE_DID_NOT_SUCCEED
        );
    }

    /**
     * @dev Takes a snapshot of current state and returns various information related to multi pool.
     * @return reserve0 Amount of token0 in the reserve
     * @return reserve1 Amount of token1 in the reserve
     * @return feesGrow A structure containing fee growth information
     * @return _totalSupply Total number of LP tokens minted
     */
    function snapshot()
        external
        returns (
            uint256 reserve0,
            uint256 reserve1,
            FeeGrowth memory feesGrow,
            uint256 _totalSupply
        )
    {
        _totalSupply = totalSupply();
        _earn(_totalSupply);
        Slot0Data[] memory slots = getSlots();
        (reserve0, reserve1, , ) = _getReserves(slots);
        feesGrow = feesGrowthInsideLastX128;
    }

    /**
     * @notice This function collects fees from the liquidity pool and updates the fee growth inside both Vaults per share
     *         based on the amount of fees collected. It then returns the updated fee growth values.
     * @dev When called, this function updates the fee growth inside each Vault according to the realised fees in the current block,
     *      adding them to the `feesGrowthInsideLastX128` struct member variable of the contract.
     */
    function earn() external {
        uint256 _totalSupply = totalSupply();
        _earn(_totalSupply);
    }

    function _earn(uint256 _totalSupply) private {
        if (_totalSupply > 0) {
            _withdraw(0, _totalSupply);
        }
    }

    function _checkTicks(int24 tickLower, int24 tickUpper, int24 _tickSpacing) private pure {
        ErrLib.requirement(tickLower < tickUpper, ErrLib.ErrorCode.LOWER_SHOULD_BE_LESS_UPPER);
        ErrLib.requirement(tickLower >= TickMath.MIN_TICK, ErrLib.ErrorCode.LOWER_TOO_SMALL);
        ErrLib.requirement(tickUpper <= TickMath.MAX_TICK, ErrLib.ErrorCode.UPPER_TOO_BIG);
        ErrLib.requirement(tickLower % _tickSpacing == 0, ErrLib.ErrorCode.TICKLOWER_IS_NOT_SPACED);
        ErrLib.requirement(tickUpper % _tickSpacing == 0, ErrLib.ErrorCode.TICKUPPER_IS_NOT_SPACED);
    }

    function _getTicksForPosition(
        int24 tick,
        int24 positionRange,
        int24 tickSpacingOffset,
        int24 tickSpacing
    ) private pure returns (int24 lowerTick, int24 upperTick) {
        int24 floorTick = (tick / tickSpacing) * tickSpacing;
        if (tickSpacingOffset == 0) {
            lowerTick = floorTick - (positionRange - tickSpacing) / 2;
            upperTick = floorTick + (positionRange + tickSpacing) / 2;
        } else if (tickSpacingOffset > 0) {
            lowerTick = floorTick + tickSpacing * tickSpacingOffset;
            upperTick = lowerTick + positionRange;
        } else {
            upperTick = floorTick + tickSpacing * tickSpacingOffset;
            lowerTick = upperTick - positionRange;
        }
    }

    function _initializeStrategy() private returns (Slot0Data[] memory) {
        uint256 positionsNum = strategy.strategySize();
        ErrLib.requirement(positionsNum > 0, ErrLib.ErrorCode.STRATEGY_DOES_NOT_EXIST);
        delete multiPosition;
        PositionInfo memory position;
        int24 upperTick;
        int24 lowerTick;
        Slot0Data[] memory slots = new Slot0Data[](positionsNum);

        for (uint256 i = 0; i < positionsNum; ) {
            IMultiStrategy.Strategy memory sPosition = strategy.getStrategyAt(i);
            UnderlyingPool memory uPool = underlyingTrustedPools[sPosition.poolFeeAmt];
            position.poolFeeAmt = sPosition.poolFeeAmt;
            position.weight = sPosition.weight;
            position.poolAddress = uPool.poolAddress;
            (slots[i].currentSqrtRatioX96, slots[i].tick, , , , , ) = IUniswapV3Pool(
                uPool.poolAddress
            ).slot0();
            (lowerTick, upperTick) = _getTicksForPosition(
                slots[i].tick,
                sPosition.positionRange,
                sPosition.tickSpacingOffset,
                uPool.tickSpacing
            );
            _checkTicks(lowerTick, upperTick, uPool.tickSpacing);
            position.upperTick = upperTick;
            position.lowerTick = lowerTick;
            position.positionKey = PositionKey.compute(
                address(this),
                position.lowerTick,
                position.upperTick
            );

            multiPosition.push(position);
            unchecked {
                ++i;
            }
        }
        return slots;
    }

    function _calcLiquidityAmountToDeposit(
        uint160 currentSqrtRatioX96,
        PositionInfo memory position,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) private pure returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtRatioX96,
            TickMath.getSqrtRatioAtTick(position.lowerTick),
            TickMath.getSqrtRatioAtTick(position.upperTick),
            (amount0Desired * position.weight) / MAX_WEIGHT_UINT256,
            (amount1Desired * position.weight) / MAX_WEIGHT_UINT256
        );
    }

    function _upFeesGrowth(uint256 fee0, uint256 fee1, uint256 _totalSupply) private {
        feesGrowthInsideLastX128.gmiAccPerShare0 += FullMath.mulDiv(
            fee0,
            FixedPoint128.Q128,
            _totalSupply
        );

        feesGrowthInsideLastX128.gmiAccPerShare1 += FullMath.mulDiv(
            fee1,
            FixedPoint128.Q128,
            _totalSupply
        );
        uint256 feeGrowthWeight = MAX_WEIGHT_UINT256 - protocolFeeWeight;
        uint256 fee0WPF = (fee0 * feeGrowthWeight) / MAX_WEIGHT_UINT256;
        uint256 fee1WPF = (fee1 * feeGrowthWeight) / MAX_WEIGHT_UINT256;

        feesGrowthInsideLastX128.accPerShare0 += FullMath.mulDiv(
            fee0WPF,
            FixedPoint128.Q128,
            _totalSupply
        );

        feesGrowthInsideLastX128.accPerShare1 += FullMath.mulDiv(
            fee1WPF,
            FixedPoint128.Q128,
            _totalSupply
        );

        _pay(token0, address(this), owner(), fee0 - fee0WPF);
        _pay(token1, address(this), owner(), fee1 - fee1WPF);
    }

    function _deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 _totalSupply,
        Slot0Data[] memory slots
    ) private {
        uint128 liquidity;
        uint256 fee0;
        uint256 fee1;
        uint256 posNum = multiPosition.length;
        PositionInfo memory position;
        for (uint256 i = 0; i < posNum; ) {
            position = multiPosition[i];

            liquidity = _calcLiquidityAmountToDeposit(
                slots[i].currentSqrtRatioX96,
                position,
                amount0Desired,
                amount1Desired
            );
            if (liquidity > 0) {
                (, , , uint128 tokensOwed0Before, uint128 tokensOwed1Before) = IUniswapV3Pool(
                    position.poolAddress
                ).positions(position.positionKey);

                IUniswapV3Pool(position.poolAddress).mint(
                    address(this), //recipient
                    position.lowerTick,
                    position.upperTick,
                    liquidity,
                    abi.encode(position.poolFeeAmt)
                );

                (, , , uint128 tokensOwed0After, uint128 tokensOwed1After) = IUniswapV3Pool(
                    position.poolAddress
                ).positions(position.positionKey);

                fee0 += tokensOwed0After - tokensOwed0Before;
                fee1 += tokensOwed1After - tokensOwed1Before;

                IUniswapV3Pool(position.poolAddress).collect(
                    address(this),
                    position.lowerTick,
                    position.upperTick,
                    type(uint128).max,
                    type(uint128).max
                );
            }
            unchecked {
                ++i;
            }
        }

        if (_totalSupply > 0) {
            _upFeesGrowth(fee0, fee1, _totalSupply);
        }
    }

    /**
     * @notice Deposit function for adding liquidity to the pool
     * @dev This function allows a user to deposit `amount0Desired` and `amount1Desired` amounts of token0 and token1
     *      respectively into the liquidity pool and receive `lpAmount` amount of corresponding liquidity pool tokens in return.
     *      It first checks if the pool has been initialized, meaning there's already liquidity added in it. If not,
     *      then it requires that the first deposit be made by the owner address. If initialized, the optimal amount of token
     *      to be deposited is calculated based on existing reserves and minimums specified. Then, the amount of LP tokens
     *      to be minted is calculated, and the tokens are transferred accordingly from the caller to the contract. Finally,
     *      the deposit function is called internally, which uses Uniswap V3's mint function to add the liquidity to the pool.
     * @param amount0Desired The amount of token0 desired to deposit.
     * @param amount1Desired The amount of token1 desired to deposit.
     * @param amount0Min The minimum amount of token0 required to be deposited.
     * @param amount1Min The minimum amount of token1 required to be deposited.
     * @return lpAmount Returns the amount of liquidity tokens created.
     */
    function deposit(
        // TODO:  PAUSED + Max CAPS
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 lpAmount) {
        ErrLib.requirement(
            amount0Desired > MINIMUM_AMOUNT && amount1Desired > MINIMUM_AMOUNT,
            ErrLib.ErrorCode.AMOUNT_TOO_SMALL
        );
        uint256 _totalSupply = totalSupply();
        Slot0Data[] memory slots;

        if (_totalSupply == 0) {
            ErrLib.requirement(
                msg.sender == owner(),
                ErrLib.ErrorCode.FIRST_DEPOSIT_SHOULD_BE_MAKE_BY_OWNER
            );
            // fetched from Uniswap codebase
            lpAmount = Babylonian.sqrt(amount0Desired * amount1Desired) - MINIMUM_LIQUIDITY;
            _mint(burnAddress, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            slots = _initializeStrategy();
        } else {
            slots = getSlots();
            (uint256 reserve0, uint256 reserve1, , ) = _getReserves(slots);
            (amount0Desired, amount1Desired) = _optimizeAmounts(
                amount0Desired,
                amount1Desired,
                amount0Min,
                amount1Min,
                reserve0,
                reserve1
            );
            // MINIMUM
            uint256 l0 = (amount0Desired * _totalSupply) / reserve0;
            uint256 l1 = (amount1Desired * _totalSupply) / reserve1;
            lpAmount = l0 < l1 ? l0 : l1;
        }

        ErrLib.requirement(lpAmount > 0, ErrLib.ErrorCode.INSUFFICIENT_LIQUIDITY_MINTED);
        ErrLib.requirement(
            maxTotalSupply >= _totalSupply + lpAmount,
            ErrLib.ErrorCode.MAX_TOTAL_SUPPLY_REACHED
        );
        _pay(token0, msg.sender, address(this), amount0Desired);
        _pay(token1, msg.sender, address(this), amount1Desired);

        _deposit(amount0Desired, amount1Desired, _totalSupply, slots);

        _mint(msg.sender, lpAmount);

        emit Deposit(msg.sender, amount0Desired, amount1Desired, lpAmount);
    }

    function _withdraw(
        uint256 lpAmount,
        uint256 _totalSupply
    ) private returns (uint256 withdrawnAmount0, uint256 withdrawnAmount1) {
        assert(_totalSupply > 0);
        PositionInfo memory position;
        uint256 posNum = multiPosition.length;
        uint256 fee0;
        uint256 fee1;
        for (uint256 i = 0; i < posNum; ) {
            position = multiPosition[i];

            {
                (uint128 liquidity, , , , ) = IUniswapV3Pool(position.poolAddress).positions(
                    position.positionKey
                );

                uint128 liquidityToWithdraw = uint128(
                    (uint256(liquidity) * lpAmount) / _totalSupply
                );

                (, , , uint128 tokensOwed0Before, uint128 tokensOwed1Before) = IUniswapV3Pool(
                    position.poolAddress
                ).positions(position.positionKey);

                (uint256 amount0, uint256 amount1) = IUniswapV3Pool(position.poolAddress).burn(
                    position.lowerTick,
                    position.upperTick,
                    liquidityToWithdraw
                );

                withdrawnAmount0 += amount0;
                withdrawnAmount1 += amount1;

                (, , , uint128 tokensOwed0After, uint128 tokensOwed1After) = IUniswapV3Pool(
                    position.poolAddress
                ).positions(position.positionKey);

                fee0 += (tokensOwed0After - amount0) - tokensOwed0Before;
                fee1 += (tokensOwed1After - amount1) - tokensOwed1Before;
            }

            IUniswapV3Pool(position.poolAddress).collect(
                address(this),
                position.lowerTick,
                position.upperTick,
                type(uint128).max,
                type(uint128).max
            );

            unchecked {
                ++i;
            }
        }

        _upFeesGrowth(fee0, fee1, _totalSupply);
    }

    /**
     * @notice Allows the caller to withdraw their liquidity from the pool and receive the underlying tokens.
     * @param lpAmount The amount of liquidity pool tokens to withdraw.
     * @param amount0OutMin The minimum amount of token0 that the caller must receive on withdrawal.
     * @param amount1OutMin The minimum amount of token1 that the caller must receive on withdrawal.
     * @dev This function transfers the withdrawn liquidity proportional to the caller's share of the total liquidity pool. It then collects
     *      the accumulated fees for the position before burning and withdrawing liquidity. Finally, it transfers the withdrawn tokens
     *      to the caller and emits the Withdraw event.
     * @return withdrawnAmount0 The amount of token0 received by the caller after the withdrawal.
     * @return withdrawnAmount1 The amount of token1 received by the caller after the withdrawal.
     */
    function withdraw(
        uint256 lpAmount,
        uint256 amount0OutMin,
        uint256 amount1OutMin
    ) external returns (uint256 withdrawnAmount0, uint256 withdrawnAmount1) {
        uint256 _totalSupply = totalSupply();

        (withdrawnAmount0, withdrawnAmount1) = _withdraw(lpAmount, _totalSupply);

        if (lpAmount > 0) {
            withdrawnAmount0 +=
                ((IERC20(token0).balanceOf(address(this)) - withdrawnAmount0) * lpAmount) /
                _totalSupply;
            withdrawnAmount1 +=
                ((IERC20(token1).balanceOf(address(this)) - withdrawnAmount1) * lpAmount) /
                _totalSupply;

            ErrLib.requirement(
                withdrawnAmount0 >= amount0OutMin && withdrawnAmount1 >= amount1OutMin,
                ErrLib.ErrorCode.PRICE_SLIPPAGE_CHECK
            );

            _burn(msg.sender, lpAmount);
            _pay(token0, address(this), msg.sender, withdrawnAmount0);
            _pay(token1, address(this), msg.sender, withdrawnAmount1);
            emit Withdraw(msg.sender, withdrawnAmount0, withdrawnAmount1, lpAmount);
        }
    }

    /**
     * @dev This function returns the current sqrt price and tick from every opened position
     */
    function getSlots() public view returns (Slot0Data[] memory) {
        uint256 posNum = multiPosition.length;
        Slot0Data[] memory slots = new Slot0Data[](posNum);
        for (uint256 i = 0; i < posNum; ) {
            PositionInfo memory position = multiPosition[i];
            (slots[i].currentSqrtRatioX96, slots[i].tick, , , , , ) = IUniswapV3Pool(
                position.poolAddress
            ).slot0();
            unchecked {
                ++i;
            }
        }
        return slots;
    }

    /**
     * @dev This function is called after a underlying pool is minted.
     * It pays the underlying pool their owed amounts of token0 and token1 taking into account slippage, if any.
     * In order to verify that the correct pool has minted, it decodes the `data` parameter to get the pool
     * fee and uses it to check against a trusted underlying pool.
     * @param amount0Owed The amount of token0 owed to the underlying pool
     * @param amount1Owed The amount of token1 owed to the underlying pool
     * @param data Additional data provided during the minting process.
     * The function decodes a `poolFee` variable from the `data` parameter, which is used to validate
     * if the call comes from a trusted underlying pool.
     * The function then checks if the call is made by the trusted underlying pool,
     * otherwise it throws an error with a custom message.
     * Finally, the function transfers the owed amounts of token0 and token1 to the underlying pool,
     * taking into account slippage.
     */
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // a fee as unique pool key
        uint24 poolFee = abi.decode(data, (uint24));
        ErrLib.requirement(
            msg.sender == underlyingTrustedPools[poolFee].poolAddress,
            ErrLib.ErrorCode.FORBIDDEN
        );

        // the depositor(if it is not a current contract) must approve the contract, taking into account slippage.
        _pay(token0, address(this), msg.sender, amount0Owed);
        _pay(token1, address(this), msg.sender, amount1Owed);
    }

    function _pay(address token, address payer, address recipient, uint256 value) private {
        if (value > 0) {
            if (payer == address(this)) {
                _safeTransfer(token, recipient, value);
            } else {
                _safeTransferFrom(token, payer, recipient, value);
            }
        }
    }

    /**
     * @dev Returns the current reserves for token0 and token1.
     * @return reserve0 The current reserve of token0
     * @return reserve1 The current reserve of token1
     * @return pendingFee0 The amount of fees accrued but not yet claimed in token0
     * @return pendingFee1 The amount of fees accrued but not yet claimed in token1
     */
    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 pendingFee0, uint256 pendingFee1)
    {
        Slot0Data[] memory slots = getSlots();
        (reserve0, reserve1, pendingFee0, pendingFee1) = _getReserves(slots);
    }

    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickCurrent,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool
            .ticks(tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool
            .ticks(tickUpper);

        if (tickCurrent < tickLower) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
            feeGrowthInside0X128 =
                feeGrowthGlobal0X128 -
                lowerFeeGrowthOutside0X128 -
                upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 =
                feeGrowthGlobal1X128 -
                lowerFeeGrowthOutside1X128 -
                upperFeeGrowthOutside1X128;
        } else {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }

    function _getReserves(
        Slot0Data[] memory slots
    )
        private
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 pendingFee0, uint256 pendingFee1)
    {
        reserve0 = IERC20(token0).balanceOf(address(this));
        reserve1 = IERC20(token1).balanceOf(address(this));

        uint256 posNum = multiPosition.length;
        for (uint256 i = 0; i < posNum; ) {
            PositionInfo memory position = multiPosition[i];
            uint128 liquidity;
            uint256 feeGrowthInside0LastX128;
            uint256 feeGrowthInside1LastX128;
            {
                uint128 tokensOwed0;
                uint128 tokensOwed1;
                (
                    liquidity,
                    feeGrowthInside0LastX128,
                    feeGrowthInside1LastX128,
                    tokensOwed0,
                    tokensOwed1
                ) = IUniswapV3Pool(position.poolAddress).positions(position.positionKey);
                reserve0 += tokensOwed0;
                reserve1 += tokensOwed1;
            }
            if (liquidity > 0) {
                (
                    uint256 feeGrowthInside0X128Pending,
                    uint256 feeGrowthInside1X128Pending
                ) = _getFeeGrowthInside(
                        IUniswapV3Pool(position.poolAddress),
                        slots[i].tick,
                        position.lowerTick,
                        position.upperTick
                    );
                pendingFee0 += uint128(
                    FullMath.mulDiv(
                        feeGrowthInside0X128Pending - feeGrowthInside0LastX128,
                        liquidity,
                        FixedPoint128.Q128
                    )
                );
                pendingFee1 += uint128(
                    FullMath.mulDiv(
                        feeGrowthInside1X128Pending - feeGrowthInside1LastX128,
                        liquidity,
                        FixedPoint128.Q128
                    )
                );
            }

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                slots[i].currentSqrtRatioX96,
                TickMath.getSqrtRatioAtTick(position.lowerTick),
                TickMath.getSqrtRatioAtTick(position.upperTick),
                liquidity
            );
            reserve0 += amount0;
            reserve1 += amount1;

            unchecked {
                ++i;
            }
        }
        // take away protocol fee
        uint256 feeGrowthWeight = MAX_WEIGHT_UINT256 - protocolFeeWeight;
        pendingFee0 = (pendingFee0 * feeGrowthWeight) / MAX_WEIGHT_UINT256;
        pendingFee1 = (pendingFee1 * feeGrowthWeight) / MAX_WEIGHT_UINT256;

        reserve0 += pendingFee0;
        reserve1 += pendingFee1;
    }

    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) private pure returns (uint256 amountB) {
        ErrLib.requirement(amountA > 0, ErrLib.ErrorCode.INSUFFICIENT_AMOUNT);
        ErrLib.requirement(reserveA > 0 && reserveB > 0, ErrLib.ErrorCode.INSUFFICIENT_LIQUIDITY);
        amountB = (amountA * reserveB) / reserveA;
    }

    function _optimizeAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 reserve0,
        uint256 reserve1
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (reserve0 == 0 && reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = _quote(amount0Desired, reserve0, reserve1);
            if (amount1Optimal <= amount1Desired) {
                ErrLib.requirement(
                    amount1Optimal >= amount1Min,
                    ErrLib.ErrorCode.INSUFFICIENT_1_AMOUNT
                );
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = _quote(amount1Desired, reserve1, reserve0);
                assert(amount0Optimal <= amount0Desired);
                ErrLib.requirement(
                    amount0Optimal >= amount0Min,
                    ErrLib.ErrorCode.INSUFFICIENT_0_AMOUNT
                );
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }
    }

    /**
     * @notice Calculates the estimated amount of token that will be received as output with the specified input amount and current price.
     * @param zeroForOne A boolean to specify if token0(true) or token1(false) is the input currency.
     * @param amountIn The input amount of the token to swap.
     * @return swappedOut The estimated output amount of tokens that will be received based on the current price.
     */
    function getAmountOut(
        bool zeroForOne,
        uint256 amountIn
    ) public view returns (uint256 swappedOut) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(underlyingTrustedPools[500].poolAddress)
            .observe(secondsAgo);
        int24 avarageTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int32(twapDuration));
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avarageTick);
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            swappedOut = zeroForOne
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            swappedOut = zeroForOne
                ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
                : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
        }
    }

    /**
     * @dev This function closes all opened positions, swaps desired token to other(if needed) and opens new positions
     *      with new strategy settings
     * @param params Details for the swap
     * */
    function rebalanceAll(RebalanceParams calldata params) external nonReentrant {
        ErrLib.requirement(operator == msg.sender, ErrLib.ErrorCode.OPERATOR_NOT_APPROVED);
        ErrLib.requirement(
            approvedTargets[params.swapTarget],
            ErrLib.ErrorCode.SWAP_TARGET_NOT_APPROVED
        );
        uint256 _totalSupply = totalSupply();
        // withdraw all liquidity completely
        _withdraw(_totalSupply, _totalSupply);

        uint reserve0Before = IERC20(token0).balanceOf(address(this));
        uint reserve1Before = IERC20(token1).balanceOf(address(this));
        if (params.amountIn > 0) {
            _approveToken(params.zeroForOne ? token0 : token1, params.swapTarget, params.amountIn);
            (bool success, ) = params.swapTarget.call(params.swapData);
            ErrLib.requirement(success, ErrLib.ErrorCode.ERROR_SWAPPING_TOKENS);
        }
        uint reserve0 = IERC20(token0).balanceOf(address(this));
        uint reserve1 = IERC20(token1).balanceOf(address(this));
        ErrLib.requirement(
            reserve0 > MINIMUM_AMOUNT && reserve1 > MINIMUM_AMOUNT,
            ErrLib.ErrorCode.INSUFFICIENT_LIQUIDITY
        );
        uint256 amountIn = params.zeroForOne
            ? reserve0Before - reserve0
            : reserve1Before - reserve1;
        ErrLib.requirement(amountIn <= params.amountIn, ErrLib.ErrorCode.AMOUNT_IN_TO_BIG);
        uint256 amountOut = params.zeroForOne
            ? reserve1 - reserve1Before
            : reserve0 - reserve0Before;
        uint256 swappedOut = getAmountOut(params.zeroForOne, amountIn);
        if (amountOut < swappedOut) {
            ErrLib.requirement(
                (swappedOut * maxTwapDeviation) / MAX_WEIGHT_UINT256 >= swappedOut - amountOut,
                ErrLib.ErrorCode.PRICE_SLIPPAGE_CHECK
            );
        }

        // Should delete old positions properly and open new one
        Slot0Data[] memory slots = _initializeStrategy();
        _deposit(reserve0, reserve1, _totalSupply, slots);

        emit Rebalance(reserve0Before, reserve1Before, reserve0, reserve1, swappedOut);
    }

    /**
     * @dev setParam function manages parameters of the contract by the owner
     * @param _managing Index of the parameter that should be changed
     * @param _param Value of the parameter that should changed to
     * */
    function setParam(MANAGING _managing, uint _param) external onlyOwner {
        if (_managing == MANAGING.MAXTOTALSUPPLY) {
            maxTotalSupply = _param;
        } else if (_managing == MANAGING.PROTOCOLFEEWEIGHT) {
            ErrLib.requirement(
                _param <= protocolFeeWeightMax,
                ErrLib.ErrorCode.PROTOCOL_FEE_TOO_BIG
            );
            uint256 _totalSupply = totalSupply();
            _earn(_totalSupply);
            protocolFeeWeight = _param;
        } else if (_managing == MANAGING.OPERATOR) {
            ErrLib.requirement(_param != 0, ErrLib.ErrorCode.INVALID_ADDRESS);
            operator = address(uint160(_param));
        } else if (_managing == MANAGING.TWAPDURATION) {
            twapDuration = uint32(_param);
        } else if (_managing == MANAGING.MAXTWAPDEVIATION) {
            ErrLib.requirement(_param <= 5000, ErrLib.ErrorCode.DEVIATION_TO_BIG);
            maxTwapDeviation = _param;
        } else {
            revert InvalidManaging();
        }
        emit ParamChanged(_managing, _param);
    }

    /**
     * @dev manageSwapTarget function set/restrict permission to aggregator's router to swap through
     * @param _target Address of  aggregator's router
     * @param _approved true/false - set/restrict permission
     * */

    function manageSwapTarget(address _target, bool _approved) external onlyOwner {
        ErrLib.requirement(_target != address(0), ErrLib.ErrorCode.INVALID_ADDRESS);
        approvedTargets[_target] = _approved;
        emit SwapTargetApproved(_target, _approved);
    }

    function _approveToken(address token, address spender, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), spender) > 0) _safeApprove(token, spender, 0);
        _safeApprove(token, spender, amount);
    }
}