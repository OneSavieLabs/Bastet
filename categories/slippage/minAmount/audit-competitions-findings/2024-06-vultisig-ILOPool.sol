// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-core/contracts/libraries/FullMath.sol';

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';

import './interfaces/IILOPool.sol';
import './interfaces/IILOManager.sol';
import './libraries/PositionKey.sol';
import './libraries/SqrtPriceMathPartial.sol';
import './base/ILOVest.sol';
import './base/LiquidityManagement.sol';
import './base/ILOPoolImmutableState.sol';
import './base/Initializable.sol';
import './base/Multicall.sol';
import "./base/ILOWhitelist.sol";

/// @title NFT positions
/// @notice Wraps Uniswap V3 positions in the ERC721 non-fungible token interface
contract ILOPool is
    ERC721,
    IILOPool,
    ILOWhitelist,
    ILOVest,
    Initializable,
    Multicall,
    ILOPoolImmutableState,
    LiquidityManagement
{
    SaleInfo saleInfo;

    /// @dev when lauch successfully we can not refund anymore
    bool private _launchSucceeded;

    /// @dev when refund triggered, we can not launch anymore
    bool private _refundTriggered;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;
    VestingConfig[] private _vestingConfigs;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId;
    uint256 totalRaised;
    constructor() ERC721('', '') {
        _disableInitialize();
    }

    function name() public pure override(ERC721, IERC721Metadata) returns (string memory) {
        return 'KRYSTAL ILOPool V1';
    }

    function symbol() public pure override(ERC721, IERC721Metadata) returns (string memory) {
        return 'KRYSTAL-ILO-V1';
    }

    function initialize(InitPoolParams calldata params) external override whenNotInitialized() {
        _nextId = 1;
        // initialize imutable state
        MANAGER = msg.sender;
        IILOManager.Project memory _project = IILOManager(MANAGER).project(params.uniV3Pool);

        WETH9 = IILOManager(MANAGER).WETH9();
        RAISE_TOKEN = _project.raiseToken;
        SALE_TOKEN = _project.saleToken;
        _cachedUniV3PoolAddress = params.uniV3Pool;
        _cachedPoolKey = _project._cachedPoolKey;
        TICK_LOWER = params.tickLower;
        TICK_UPPER = params.tickUpper;
        SQRT_RATIO_LOWER_X96 = params.sqrtRatioLowerX96;
        SQRT_RATIO_UPPER_X96 = params.sqrtRatioUpperX96;
        SQRT_RATIO_X96 = _project.initialPoolPriceX96;

        // rounding up to make sure that the number of sale token is enough for sale
        (uint256 maxSaleAmount,) = _saleAmountNeeded(params.hardCap);
        // initialize sale
        saleInfo = SaleInfo({
            hardCap: params.hardCap,
            softCap: params.softCap,
            maxCapPerUser: params.maxCapPerUser,
            start: params.start,
            end: params.end,
            maxSaleAmount: maxSaleAmount
        });

        _validateSharesAndVests(_project.launchTime, params.vestingConfigs);
        // initialize vesting
        for (uint256 index = 0; index < params.vestingConfigs.length; index++) {
            _vestingConfigs.push(params.vestingConfigs[index]);
        }

        emit ILOPoolInitialized(
            params.uniV3Pool,
            TICK_LOWER,
            TICK_UPPER,
            saleInfo,
            params.vestingConfigs
        );
    }

    /// @inheritdoc IILOPool
    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint128 liquidity,
            uint256 raiseAmount,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128
        )
    {
        return (
            _positions[tokenId].liquidity,
            _positions[tokenId].raiseAmount,
            _positions[tokenId].feeGrowthInside0LastX128,
            _positions[tokenId].feeGrowthInside1LastX128
        );
    }

    /// @inheritdoc IILOSale
    function buy(uint256 raiseAmount, address recipient)
        external override 
        returns (
            uint256 tokenId,
            uint128 liquidityDelta
        )
    {
        require(_isWhitelisted(recipient), "UA");
        require(block.timestamp > saleInfo.start && block.timestamp < saleInfo.end, "ST");
        // check if raise amount over capacity
        require(saleInfo.hardCap - totalRaised >= raiseAmount, "HC");
        totalRaised += raiseAmount;

        require(totalSold() <= saleInfo.maxSaleAmount, "SA");

        // if investor already have a position, just increase raise amount and liquidity
        // otherwise, mint new nft for investor and assign vesting schedules
        if (balanceOf(recipient) == 0) {
            _mint(recipient, (tokenId = _nextId++));
            _positionVests[tokenId].schedule = _vestingConfigs[0].schedule;
        } else {
            tokenId = tokenOfOwnerByIndex(recipient, 0);
        }

        Position storage _position = _positions[tokenId];
        require(raiseAmount <= saleInfo.maxCapPerUser - _position.raiseAmount, "UC");
        _position.raiseAmount += raiseAmount;

        // get amount of liquidity associated with raise amount
        if (RAISE_TOKEN == _cachedPoolKey.token0) {
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(SQRT_RATIO_X96, SQRT_RATIO_UPPER_X96, raiseAmount);
        } else {
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount1(SQRT_RATIO_LOWER_X96, SQRT_RATIO_X96, raiseAmount);
        }

        require(liquidityDelta > 0, "ZA");

        // calculate amount of share liquidity investor recieve by INVESTOR_SHARES config
        liquidityDelta = uint128(FullMath.mulDiv(liquidityDelta, _vestingConfigs[0].shares, BPS));
        
        // increase investor's liquidity
        _position.liquidity += liquidityDelta;

        // update total liquidity locked for vest and assiging vesing schedules
        _positionVests[tokenId].totalLiquidity = _position.liquidity;

        // transfer fund into contract
        TransferHelper.safeTransferFrom(RAISE_TOKEN, msg.sender, address(this), raiseAmount);

        emit Buy(recipient, tokenId, raiseAmount, liquidityDelta);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), 'UA');
        _;
    }

    /// @inheritdoc IILOPool
    function claim(uint256 tokenId)
        external
        payable
        override
        isAuthorizedForToken(tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        // only can claim if the launch is successfully
        require(_launchSucceeded, "PNL");

        // calculate amount of unlocked liquidity for the position
        uint128 liquidity2Claim = _claimableLiquidity(tokenId);
        IUniswapV3Pool pool = IUniswapV3Pool(_cachedUniV3PoolAddress);
        Position storage position = _positions[tokenId];
        {
            IILOManager.Project memory _project = IILOManager(MANAGER).project(address(pool));

            uint128 positionLiquidity = position.liquidity;
            require(positionLiquidity >= liquidity2Claim);

            // get amount of token0 and token1 that pool will return for us
            (amount0, amount1) = pool.burn(TICK_LOWER, TICK_UPPER, liquidity2Claim);

            // get amount of token0 and token1 after deduct platform fee
            (amount0, amount1) = _deductFees(amount0, amount1, _project.platformFee);

            bytes32 positionKey = PositionKey.compute(address(this), TICK_LOWER, TICK_UPPER);

            // calculate amount of fees that position generated
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);
            uint256 fees0 = FullMath.mulDiv(
                                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                                positionLiquidity,
                                FixedPoint128.Q128
                            );
            
            uint256 fees1 = FullMath.mulDiv(
                                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                                positionLiquidity,
                                FixedPoint128.Q128
                            );

            // amount of fees after deduct performance fee
            (fees0, fees1) = _deductFees(fees0, fees1, _project.performanceFee);

            // fees is combined with liquidity token amount to return to the user
            amount0 += fees0;
            amount1 += fees1;

            position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
            position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;

            // subtraction is safe because we checked positionLiquidity is gte liquidity2Claim
            position.liquidity = positionLiquidity - liquidity2Claim;
            emit DecreaseLiquidity(tokenId, liquidity2Claim, amount0, amount1);

        }
        // real amount collected from uintswap pool
        (uint128 amountCollected0, uint128 amountCollected1) = pool.collect(
            address(this),
            TICK_LOWER,
            TICK_UPPER,
            type(uint128).max,
            type(uint128).max
        );
        emit Collect(tokenId, address(this), amountCollected0, amountCollected1);

        // transfer token for user
        TransferHelper.safeTransfer(_cachedPoolKey.token0, ownerOf(tokenId), amount0);
        TransferHelper.safeTransfer(_cachedPoolKey.token1, ownerOf(tokenId), amount1);

        emit Claim(ownerOf(tokenId), tokenId,liquidity2Claim, amount0, amount1, position.feeGrowthInside0LastX128, position.feeGrowthInside1LastX128);

        address feeTaker = IILOManager(MANAGER).FEE_TAKER();
        // transfer fee to fee taker
        TransferHelper.safeTransfer(_cachedPoolKey.token0, feeTaker, amountCollected0-amount0);
        TransferHelper.safeTransfer(_cachedPoolKey.token1, feeTaker, amountCollected1-amount1);
    }

    modifier OnlyManager() {
        require(msg.sender == MANAGER, "UA");
        _;
    }

    /// @inheritdoc IILOPool
    function launch() external override OnlyManager() {
        require(!_launchSucceeded, "PL");
        // when refund triggered, we can not launch pool anymore
        require(!_refundTriggered, "IRF");
        // make sure that soft cap requirement match
        require(totalRaised >= saleInfo.softCap, "SC");
        uint128 liquidity;
        address uniV3PoolAddress = _cachedUniV3PoolAddress;
        {
            uint256 amount0;
            uint256 amount1;
            uint256 amount0Min;
            uint256 amount1Min;
            address token0Addr = _cachedPoolKey.token0;

            // calculate sale amount of tokens needed for launching pool
            if (token0Addr == RAISE_TOKEN) {
                amount0 = totalRaised;
                amount0Min = totalRaised;
                (amount1, liquidity) = _saleAmountNeeded(totalRaised);
            } else {
                (amount0, liquidity) = _saleAmountNeeded(totalRaised);
                amount1 = totalRaised;
                amount1Min = totalRaised;
            }

            // actually deploy liquidity to uniswap pool
            (amount0, amount1) = addLiquidity(AddLiquidityParams({
                pool: IUniswapV3Pool(uniV3PoolAddress),
                liquidity: liquidity,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0Min,
                amount1Min: amount1Min
            }));

            emit PoolLaunch(uniV3PoolAddress, liquidity, amount0, amount1);
        }

        IILOManager.Project memory _project = IILOManager(MANAGER).project(uniV3PoolAddress);

        // assigning vests for the project configuration
        for (uint256 index = 1; index < _vestingConfigs.length; index++) {
            uint256 tokenId;
            VestingConfig memory projectConfig = _vestingConfigs[index];
            // mint nft for recipient
            _mint(projectConfig.recipient, (tokenId = _nextId++));
            uint128 liquidityShares = uint128(FullMath.mulDiv(liquidity, projectConfig.shares, BPS));

            Position storage _position = _positions[tokenId];
            _position.liquidity = liquidityShares;
            _positionVests[tokenId].totalLiquidity = liquidityShares;

            // assign vesting schedule
            LinearVest[] storage schedule = _positionVests[tokenId].schedule;
            for (uint256 i = 0; i < projectConfig.schedule.length; i++) {
                schedule.push(projectConfig.schedule[i]);
            }

            emit Buy(projectConfig.recipient, tokenId, 0, liquidityShares);
        }

        // transfer back leftover sale token to project admin
        _refundProject(_project.admin);

        _launchSucceeded = true;
    }

    modifier refundable() {
        if (!_refundTriggered) {
            // if ilo pool is lauch sucessfully, we can not refund anymore
            require(!_launchSucceeded, "PL");
            IILOManager.Project memory _project = IILOManager(MANAGER).project(_cachedUniV3PoolAddress);
            require(block.timestamp >= _project.refundDeadline, "RFT");

            _refundTriggered = true;
        }
        _;
    }

    /// @inheritdoc IILOPool
    function claimRefund(uint256 tokenId) external override refundable() isAuthorizedForToken(tokenId) {
        uint256 refundAmount = _positions[tokenId].raiseAmount;
        address tokenOwner = ownerOf(tokenId);

        delete _positions[tokenId];
        delete _positionVests[tokenId];
        _burn(tokenId);

        TransferHelper.safeTransfer(RAISE_TOKEN, tokenOwner, refundAmount);
        emit UserRefund(tokenOwner, tokenId,refundAmount);
    }

    /// @inheritdoc IILOPool
    function claimProjectRefund(address projectAdmin) external override refundable() OnlyManager() returns(uint256 refundAmount) {
        return _refundProject(projectAdmin);
    }

    function _refundProject(address projectAdmin) internal returns (uint256 refundAmount) {
        refundAmount = IERC20(SALE_TOKEN).balanceOf(address(this));
        if (refundAmount > 0) {
            TransferHelper.safeTransfer(SALE_TOKEN, projectAdmin, refundAmount);
            emit ProjectRefund(projectAdmin, refundAmount);
        }
    }

    /// @inheritdoc IILOSale
    function totalSold() public view override returns (uint256 _totalSold) {
        (_totalSold,) =_saleAmountNeeded(totalRaised);
    }

    /// @notice return sale token amount needed for the raiseAmount.
    /// @dev sale token amount is rounded up
    function _saleAmountNeeded(uint256 raiseAmount) internal view returns (
        uint256 saleAmountNeeded,
        uint128 liquidity
    ) {
        if (raiseAmount == 0) return (0, 0);

        if (_cachedPoolKey.token0 == SALE_TOKEN) {
            // liquidity1 raised
            liquidity = LiquidityAmounts.getLiquidityForAmount1(SQRT_RATIO_LOWER_X96, SQRT_RATIO_X96, raiseAmount);
            saleAmountNeeded = SqrtPriceMathPartial.getAmount0Delta(SQRT_RATIO_X96, SQRT_RATIO_UPPER_X96, liquidity, true);
        } else {
            // liquidity0 raised
            liquidity = LiquidityAmounts.getLiquidityForAmount0(SQRT_RATIO_X96, SQRT_RATIO_UPPER_X96, raiseAmount);
            saleAmountNeeded = SqrtPriceMathPartial.getAmount1Delta(SQRT_RATIO_LOWER_X96, SQRT_RATIO_X96, liquidity, true);
        }
    }

    /// @inheritdoc ILOVest
    function _unlockedLiquidity(uint256 tokenId) internal view override returns (uint128 liquidityUnlocked) {
        PositionVest storage _positionVest = _positionVests[tokenId];
        LinearVest[] storage vestingSchedule = _positionVest.schedule;
        uint128 totalLiquidity = _positionVest.totalLiquidity;

        for (uint256 index = 0; index < vestingSchedule.length; index++) {

            LinearVest storage vest = vestingSchedule[index];

            // if vest is not started, skip this vest and all following vest
            if (block.timestamp < vest.start) {
                break;
            }

            // if vest already end, all the shares are unlocked
            // otherwise we calculate shares of unlocked times and get the unlocked share number
            // all vest after current unlocking vest is ignored
            if (vest.end < block.timestamp) {
                liquidityUnlocked += uint128(FullMath.mulDiv(
                    vest.shares, 
                    totalLiquidity, 
                    BPS
                ));
            } else {
                liquidityUnlocked += uint128(FullMath.mulDiv(
                    vest.shares * totalLiquidity, 
                    block.timestamp - vest.start, 
                    (vest.end - vest.start) * BPS
                ));
            }
        }
    }

    /// @notice calculate the amount left after deduct fee
    /// @param amount0 the amount of token0 before deduct fee
    /// @param amount1 the amount of token1 before deduct fee
    /// @return amount0Left the amount of token0 after deduct fee
    /// @return amount1Left the amount of token1 after deduct fee
    function _deductFees(uint256 amount0, uint256 amount1, uint16 feeBPS) internal pure 
        returns (
            uint256 amount0Left, 
            uint256 amount1Left
        ) {
        amount0Left = amount0 - FullMath.mulDiv(amount0, feeBPS, BPS);
        amount1Left = amount1 - FullMath.mulDiv(amount1, feeBPS, BPS);
    }

    /// @inheritdoc IILOVest
    function vestingStatus(uint256 tokenId) external view override returns (
        uint128 unlockedLiquidity,
        uint128 claimedLiquidity
    ) {
        unlockedLiquidity = _unlockedLiquidity(tokenId);
        claimedLiquidity = _positionVests[tokenId].totalLiquidity - _positions[tokenId].liquidity;
    }

    /// @inheritdoc ILOVest
    function _claimableLiquidity(uint256 tokenId) internal view override returns (uint128) {
        uint128 liquidityClaimed = _positionVests[tokenId].totalLiquidity - _positions[tokenId].liquidity;
        uint128 liquidityUnlocked = _unlockedLiquidity(tokenId);
        return liquidityClaimed < liquidityUnlocked ? liquidityUnlocked - liquidityClaimed : 0;
    }

    modifier onlyProjectAdmin() override {
        IILOManager.Project memory _project = IILOManager(MANAGER).project(_cachedUniV3PoolAddress);
        require(msg.sender == _project.admin, "UA");
        _;
    }

}