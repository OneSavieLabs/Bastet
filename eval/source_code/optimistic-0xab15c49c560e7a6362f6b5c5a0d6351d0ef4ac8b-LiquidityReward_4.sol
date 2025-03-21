// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV2V3Interface.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

// This code implements a system where liquidity providers can provide Ether, which is converted into WETH and WBTC, and then supplied as liquidity to the Uniswap V3 pool. Rewards are paid in HAN tokens, and liquidity providers can remove their liquidity and claim rewards at any time.

contract LiquidityReward_4 is Ownable, ReentrancyGuard, Pausable {

    AggregatorV2V3Interface public constant PRICE_FEED = AggregatorV2V3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5); // Address of the Chainlink oracle for Ethereum price feed.

    // Addresses related to Uniswap V3.
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Factory public constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool public constant WBTC_POOL = IUniswapV3Pool(0xD4344Ea0c5aDE7e22B9B275F0BdE7a145dEC5A23);

    // Addresses of WETH, WBTC, and HAN tokens.
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20 public constant WBTC = IERC20(0x68f180fcCe6836688e9084f035309E29Bf0A2095);
    IERC20 public constant HAN = IERC20(0x50Bce64397C75488465253c0A034b8097FeA6578);

    uint256 public constant REWARD_PER_SECOND = 7383356920698690000; // Defines the reward per second.
    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 public constant PRICE = 1000000000000; // Default price setting in USD (decimal 8).
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.

    // Constants for Uniswap pool configuration.
    uint24 public constant FEE = 10000;
    int24 public immutable TICK_LOWER = -887200;
    int24 public immutable TICK_UPPER = 887200;
    
    // Variables related to liquidity.
    uint256 public persent = 10;
    uint256 public suppliedWBTC;
    uint256 public suppliedHAN;
    uint256 public totalUnderlyingLiquidity;
    address public v1AuthorizedAddress;
    address public v2AuthorizedAddress;

    // Structure to store information about liquidity providers.
    struct LiquidityProvider {
        uint256 liquidity; // Amount of provided liquidity.
        uint256 tokenId; // Token ID of the provided liquidity.
        uint256 hanAmount; // Amount of HAN tokens provided.
        uint256 wbtcAmount; // Amount of WBTC tokens provided.
        uint256 lastClaimedTime; // Last time rewards were claimed.
        uint256 lockupPeriod; // Time when liquidity can be removed.
    }
    mapping (address => LiquidityProvider) private providers; // Mapping to store information about liquidity providers.
    mapping (address => LiquidityProvider[]) private providerArray; // Mapping to store information about liquidity providers.

    struct TotalLiquidityInfo {
        uint256 totalLiquidity; // Total liquidity supplied
        uint256 totalHanAmount; // Total HAN token amount supplied
        uint256 totalWbtcAmount; // Total WBTC token amount supplied
        uint256 totalRewardReleased; // Total reward released to the provider
        uint256 unclaimedRewards; // Unclaimed rewards of the provider
        uint256 referrerReward; // Referrer reward of the provider
        uint256 liquidityReward; // Provider reward of the provider
    }
    mapping (address => TotalLiquidityInfo) public totalLiquidityInfo; // Mapping to store the total information of a liquidity provider.

    // Function to convert Ether to WETH, swap some for WBTC, and add liquidity to the Uniswap V3 pool.
    function addLiquidity() external payable nonReentrant {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        
        WETH.deposit{value: msg.value}(); // Convert Ether to WETH. 

        uint256 providedEthAmount = msg.value; // Store the amount of Ether provided.
        uint256 currentEthAmount = getEthAmount(PRICE); // Calculate the amount of Ether for the given PRICE.
        require(providedEthAmount >= currentEthAmount, "Provided amount is less than the required minimum");

        uint256 amount = providedEthAmount / 2; // Calculate the amount of Ether to be swapped for WBTC.
        uint256 wbtcTokenAmount = _swapWETHForWBTC(amount); // Swap WETH for WBTC.
        uint256 hanTokenAmount = getEquivalentHanForWBTC(wbtcTokenAmount); // Calculate the equivalent amount of HAN tokens for the swapped WBTC.

        _safeApprove(HAN, address(POSITION_MANAGER), hanTokenAmount); // Approve HAN tokens.
        _safeApprove(WBTC, address(POSITION_MANAGER), wbtcTokenAmount); // Approve WBTC tokens.

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _addLiquidityToUniswap(hanTokenAmount, wbtcTokenAmount);

        // Update the contract's supplied HAN and WBTC amounts and total liquidity.
        suppliedHAN += amount0;
        suppliedWBTC += amount1;
        totalUnderlyingLiquidity += liquidity;

        // Update the liquidity provider's total information.
        totalInfo.totalLiquidity += liquidity; // Add the liquidity to the liquidity provider's total liquidity.
        totalInfo.totalHanAmount += amount0; // Add the HAN amount to the liquidity provider's total HAN amount.
        totalInfo.totalWbtcAmount += amount1; // Add the WBTC amount to the liquidity provider's total WBTC amount.
        totalInfo.referrerReward += amount0 * 2 / persent; // Add the referrer reward to the liquidity provider's referrer reward.
        totalInfo.liquidityReward += amount0; // Add the liquidity reward to the liquidity provider's liquidity reward.

        _addToProviderArray(msg.sender, tokenId, liquidity, amount0, amount1);

        emit LiquidityAdded(msg.sender, tokenId, amount0, amount1, liquidity);
    }

    // Function to remove liquidity and retrieve tokens.
    function removeLiquidity(uint256 _index) external nonReentrant {
        LiquidityProvider memory provider = providerArray[msg.sender][_index];
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        require(provider.lockupPeriod < block.timestamp, "Lockup period is not over yet"); // Check if the lockup period has passed.

        // Remove liquidity and retrieve tokens.
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: provider.tokenId,
            liquidity: uint128(provider.liquidity),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        POSITION_MANAGER.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: provider.tokenId,
            recipient: msg.sender,
            amount0Max: type(uint128).max, 
            amount1Max: type(uint128).max 
        });
        POSITION_MANAGER.collect(collectParams);

        // Deduct the contract's supplied HAN and WBTC amounts and total liquidity.
        suppliedHAN -= provider.hanAmount;
        suppliedWBTC -= provider.wbtcAmount;
        totalUnderlyingLiquidity -= provider.liquidity;

        // Update the liquidity provider's total information.
        totalInfo.totalLiquidity -= provider.liquidity; // Deduct the liquidity from the liquidity provider's total liquidity.
        totalInfo.totalHanAmount -= provider.hanAmount; // Deduct the HAN amount from the liquidity provider's total HAN amount.
        totalInfo.totalWbtcAmount -= provider.wbtcAmount; // Deduct the WBTC amount from the liquidity provider's total WBTC amount.
        totalInfo.unclaimedRewards += _calculateRewards(msg.sender, _index); // Calculate and add rewards to unclaimed rewards.

        emit LiquidityRemoved(msg.sender, provider.tokenId, provider.liquidity);

        _removeElement(_index); // Remove the liquidity provider's information from the array.
    }

    // Function for liquidity providers to claim accumulated rewards.
    function claimRewards() external nonReentrant {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        uint256 reward;

        for(uint i = 0; i < providerArray[msg.sender].length; i++) {
            LiquidityProvider storage provider = providerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i); // Calculate the reward for the liquidity provider.
            if (rewardValue > 0) {
                reward += rewardValue;
                provider.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + totalInfo.unclaimedRewards > 0, "No rewards to claim"); // Check if there are rewards to claim.

        HAN.transfer(msg.sender, reward + totalInfo.unclaimedRewards); // Transfer the calculated rewards.

        totalInfo.totalRewardReleased += reward + totalInfo.unclaimedRewards; // Update the total amount of rewards released.
        totalInfo.unclaimedRewards = 0; // Reset the unclaimed rewards.

        emit RewardsClaimed(msg.sender, reward);
    }

    // Function to add a referrer list.
    function registrationV1(address _user) external nonReentrant returns (uint256) {
        require(msg.sender == v1AuthorizedAddress, "Not authorized");
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[_user];
        uint256 reward;
        reward = totalInfo.referrerReward; // Store the referrer reward.
        require(reward > 0, "No referrer reward"); // Check if the liquidity provider has a referrer reward.
        totalInfo.referrerReward = 0; // Reset the referrer reward.
        emit ReferrerRegistered(_user, reward);
        return reward;
    }

    // Function to set the v1 authorized address.
    function setV1AuthorizedAddress(address _v1AuthorizedAddress) external onlyOwner nonReentrant {
        v1AuthorizedAddress = _v1AuthorizedAddress;
        emit V1AuthorizedAddressSet(_v1AuthorizedAddress);
    }

    // Function to add a provider list.
    function registrationV2(address _user) external nonReentrant returns (uint256) {
        require(msg.sender == v2AuthorizedAddress, "Not authorized");
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[_user];
        uint256 reward = 0;
        reward += totalInfo.liquidityReward; // Store the provider reward.
        totalInfo.liquidityReward = 0; // Reset the provider reward.
        emit ReferrerRegistered(_user, reward);
        return reward;
    }

    // Function to set the v2 authorized address.
    function setV2AuthorizedAddress(address _v2AuthorizedAddress) external onlyOwner nonReentrant {
        v2AuthorizedAddress = _v2AuthorizedAddress;
        emit V2AuthorizedAddressSet(_v2AuthorizedAddress);
    }

    // Function set the persent.
    function setPersent(uint256 _persent) external onlyOwner nonReentrant {
        persent = _persent;
        emit SetPersent(_persent);
    }   

    // Function to view the reward amount for a specific user.
    function rewardView(address _user) public view returns (uint256) {
        uint256 reward = 0;
        for(uint i = 0; i < providerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i); // Calculate the reward for the liquidity provider.
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        return reward;
    }

    // Function to convert Ethereum price to USD. (decimal 18)
    function getUSDPrice(uint256 _ethAmount) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 usdAmount = _ethAmount * ethPriceInUSD / WEI_MULTIPLIER;

        return usdAmount;
    }

    // Function to convert USD price to Ethereum. (decimal 8)
    function getEthAmount(uint256 _usdPrice) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 ethAmount = _usdPrice * WEI_MULTIPLIER / ethPriceInUSD;

        return ethAmount;
    }

    // Function to view the remaining time for liquidity removal.
    function remainingDuration(address _user, uint256 _index) public view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        if(provider.lockupPeriod > block.timestamp) { 
            return provider.lockupPeriod - block.timestamp;
        } else {
            return 0;
        }
    }

    // Function to calculate the equivalent amount of HAN tokens for a given amount of WBTC.
    function getEquivalentHanForWBTC(uint _wbtcAmount) public view returns (uint) {
        (, int24 tick, , , , , ) = WBTC_POOL.slot0();

        uint btcPrice = OracleLibrary.getQuoteAtTick(
            tick,
            uint128(_wbtcAmount),
            WBTC_POOL.token1(),
            WBTC_POOL.token0()
        );
        return btcPrice;
    }

    // Function to view the information of a liquidity provider Array.
    function getProviders(address _user) public view returns(LiquidityProvider[] memory) {
        return providerArray[_user];
    }

    // internal function to calculate rewards for a user.
    function _calculateRewards(address _user, uint256 _index) internal view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - provider.lastClaimedTime; // Calculate the time elapsed since the last reward claim.
        reward = provider.liquidity * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER; // Calculate the reward based on elapsed time.
        return reward;
    }

    function _addLiquidityToUniswap(uint256 _hanTokenAmount, uint256 _wbtcTokenAmount) private returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(HAN),
            token1: address(WBTC),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: _hanTokenAmount,
            amount1Desired: _wbtcTokenAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(params);
        return (tokenId, liquidity, amount0, amount1);
    }

    // private function to add a liquidity provider to the array.
    function _addToProviderArray(address _user, uint256 _tokenId, uint256 _liquidity, uint256 _hanAmount, uint256 _wbtcAmount) private {
        LiquidityProvider memory newProvider = LiquidityProvider({
            tokenId: _tokenId,
            liquidity: _liquidity,
            hanAmount: _hanAmount,
            wbtcAmount: _wbtcAmount,
            lastClaimedTime: block.timestamp,
            lockupPeriod: block.timestamp + YEAR
        });
        providerArray[_user].push(newProvider);
    }

    // private function to swap WETH for WBTC.
    function _swapWETHForWBTC(uint256 _wethAmount) private returns (uint256) {
        
        uint256 wbtcBalanceBefore = WBTC.balanceOf(address(this)); // Check WBTC balance before the swap.

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(WBTC),
            fee: FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        IERC20(address(WETH)).approve(address(SWAP_ROUTER), _wethAmount);
        SWAP_ROUTER.exactInputSingle(params);

        uint256 wbtcBalanceAfter = WBTC.balanceOf(address(this)); // Check WBTC balance after the swap.

        uint256 wbtcReceived = wbtcBalanceAfter - wbtcBalanceBefore; // Store the amount of WBTC received from the swap.
        emit SwapWETHForWBTC(msg.sender, _wethAmount, wbtcReceived);
        return wbtcReceived;
    }

    // private function to safely approve tokens.
    function _safeApprove(IERC20 _token, address _spender, uint256 _amount) private {
        uint256 currentAllowance = _token.allowance(address(this), _spender);

        if (currentAllowance != _amount) {
            if (currentAllowance > 0) {
                _token.approve(_spender, 0);
            }
            _token.approve(_spender, _amount);
            emit SafeApprove(address(_token), _spender, _amount);
        }
    }

    // private function to remove an element from the array.
    function _removeElement(uint256 _index) private {
        require(_index < providerArray[msg.sender].length, "Invalid index");
        providerArray[msg.sender][_index] = providerArray[msg.sender][providerArray[msg.sender].length - 1];
        providerArray[msg.sender].pop();
    }

    // Functions to recover wrong tokens or Ether sent to the contract.
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner nonReentrant {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit ERC20Recovered(_tokenAddress, msg.sender, _tokenAmount);
    }
    function recoverEther(address payable _recipient, uint256 _ethAmount) external onlyOwner nonReentrant{
        _recipient.transfer(_ethAmount);
        emit EtherRecovered(_recipient, _ethAmount);
    }

    // Functions to pause or unpause the contract.
    function pause() external onlyOwner nonReentrant {
        _pause();
    }
    function unpause() external onlyOwner nonReentrant {
        _unpause();
    }

    // Definitions of events for each major operation.
    event LiquidityAdded(address indexed provider, uint256 tokenId, uint256 hanAmount, uint256 wbtcAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 tokenId, uint256 liquidity);
    event RewardsClaimed(address indexed provider, uint256 reward);
    event ReferrerRegistered(address indexed user, uint256 reward);
    event MusikhanAdded(address indexed musikhan, uint256 amount);
    event V1AuthorizedAddressSet(address indexed newAuthorizedAddress);
    event V2AuthorizedAddressSet(address indexed newAuthorizedAddress);
    event SetPersent(uint256 indexed persent);
    event SwapWETHForWBTC(address indexed sender, uint256 wethAmount, uint256 wbtcReceived);
    event SafeApprove(address indexed token, address indexed spender, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event EtherRecovered(address indexed to, uint256 amount);
}