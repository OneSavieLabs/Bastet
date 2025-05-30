// SPDX-License-Identifier: BUSL 1.1
pragma solidity =0.8.22;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../price_feed/interfaces/IPriceAggregator.sol";
import "./interfaces/ICollateralAndLiquidity.sol";
import "./interfaces/IStableConfig.sol";
import "./interfaces/ILiquidizer.sol";
import "../staking/Liquidity.sol";

// The deployed contract through which all liquidity on the exchange is deposited and withdrawn.
// Also allows users to deposit WBTC/WETH liquidity as collateral for borrowing USDS stablecoin.

// The default initial collateralization ratio of collateral / borrowed USDS is 200%.
// The minimum default collateral ratio is 110%, below which positions can be liquidated by any user.
// Users who call the liquidation function on undercollateralized positions receive a default 5% of the liquidated collateral (up to a default max value of $500).
// Liquidated users lose their deposited WBTC/WETH collateral and keep the USDS that they borrowed.

contract CollateralAndLiquidity is Liquidity, ICollateralAndLiquidity
    {
    event CollateralDeposited(address indexed depositor, uint256 amountWBTC, uint256 amountWETH, uint256 liquidity);
    event CollateralWithdrawn(address indexed withdrawer, uint256 collateralWithdrawn, uint256 reclaimedWBTC, uint256 reclaimedWETH);
    event BorrowedUSDS(address indexed borrower, uint256 amountBorrowed);
    event RepaidUSDS(address indexed repayer, uint256 amountRepaid);
    event Liquidation(address indexed liquidator, address indexed liquidatee, uint256 reclaimedWBTC, uint256 reclaimedWETH, uint256 originallyBorrowedUSDS);

	using SafeERC20 for IERC20;
	using SafeERC20 for IUSDS;
    using EnumerableSet for EnumerableSet.AddressSet;

    IStableConfig immutable public stableConfig;
	IPriceAggregator immutable public priceAggregator;
    IUSDS immutable public usds;
	IERC20 immutable public wbtc;
	IERC20 immutable public weth;
	ILiquidizer immutable public liquidizer;

	// Cached for efficiency
	uint256 immutable public wbtcTenToTheDecimals;
    uint256 immutable public wethTenToTheDecimals;

   	// Keeps track of wallets that have borrowed USDS (so that they can be checked easily for sufficient collateral ratios)
   	EnumerableSet.AddressSet private _walletsWithBorrowedUSDS;

	// The amount of USDS that has been borrowed by each user
    mapping(address=>uint256) public usdsBorrowedByUsers;


    constructor( IPools _pools, IExchangeConfig _exchangeConfig, IPoolsConfig _poolsConfig, IStakingConfig _stakingConfig, IStableConfig _stableConfig, IPriceAggregator _priceAggregator, ILiquidizer _liquidizer )
		Liquidity( _pools, _exchangeConfig, _poolsConfig, _stakingConfig )
    	{
		priceAggregator = _priceAggregator;
        stableConfig = _stableConfig;
        liquidizer = _liquidizer;

		usds = _exchangeConfig.usds();
		wbtc = exchangeConfig.wbtc();
		weth = exchangeConfig.weth();

		wbtcTenToTheDecimals = 10 ** IERC20Metadata(address(wbtc)).decimals();
		wethTenToTheDecimals = 10 ** IERC20Metadata(address(weth)).decimals();
    	}


	// Deposit WBTC/WETH liqudity as collateral and increase the caller's collateral share for future rewards.
	// Requires exchange access for the sending wallet (through depositLiquidityAndIncreaseShare)
	function depositCollateralAndIncreaseShare( uint256 maxAmountWBTC, uint256 maxAmountWETH, uint256 minLiquidityReceived, uint256 deadline, bool useZapping ) external nonReentrant ensureNotExpired(deadline)  returns (uint256 addedAmountWBTC, uint256 addedAmountWETH, uint256 addedLiquidity)
		{
		// Have the user deposit the specified WBTC/WETH liquidity and increase their collateral share
		(addedAmountWBTC, addedAmountWETH, addedLiquidity) = _depositLiquidityAndIncreaseShare( wbtc, weth, maxAmountWBTC, maxAmountWETH, minLiquidityReceived, useZapping );

		emit CollateralDeposited(msg.sender, addedAmountWBTC, addedAmountWETH, addedLiquidity);
		}


	// Withdraw WBTC/WETH collateral and claim any pending rewards.
    function withdrawCollateralAndClaim( uint256 collateralToWithdraw, uint256 minReclaimedWBTC, uint256 minReclaimedWETH, uint256 deadline ) external nonReentrant ensureNotExpired(deadline) returns (uint256 reclaimedWBTC, uint256 reclaimedWETH)
		{
		// Make sure that the user has collateral and if they have borrowed USDS that collateralToWithdraw doesn't bring their collateralRatio below allowable levels.
		require( userShareForPool( msg.sender, collateralPoolID ) > 0, "User does not have any collateral" );
		require( collateralToWithdraw <= maxWithdrawableCollateral(msg.sender), "Excessive collateralToWithdraw" );

		// Withdraw the WBTC/WETH liquidity from the liquidity pool (sending the reclaimed tokens back to the user)
		(reclaimedWBTC, reclaimedWETH) = _withdrawLiquidityAndClaim( wbtc, weth, collateralToWithdraw, minReclaimedWBTC, minReclaimedWETH );

		emit CollateralWithdrawn(msg.sender, collateralToWithdraw, reclaimedWBTC, reclaimedWETH);
		}


	// Borrow USDS using existing collateral, making sure that the amount being borrowed does not exceed maxBorrowable
	// Requires exchange access for the sending wallet
    function borrowUSDS( uint256 amountBorrowed ) external nonReentrant
		{
		require( exchangeConfig.walletHasAccess(msg.sender), "Sender does not have exchange access" );
		require( userShareForPool( msg.sender, collateralPoolID ) > 0, "User does not have any collateral" );
		require( amountBorrowed <= maxBorrowableUSDS(msg.sender), "Excessive amountBorrowed" );

		// Increase the borrowed amount for the user
		usdsBorrowedByUsers[msg.sender] += amountBorrowed;

		// Remember that the user has borrowed USDS (so they can later be checked for sufficient collateralization ratios and liquidated if necessary)
		_walletsWithBorrowedUSDS.add(msg.sender);

		// Mint USDS and send it to the user
		usds.mintTo( msg.sender, amountBorrowed );

		emit BorrowedUSDS(msg.sender, amountBorrowed);
		}


     // Repay borrowed USDS and adjust the user's usdsBorrowedByUser
     function repayUSDS( uint256 amountRepaid ) external nonReentrant
		{
		require( userShareForPool( msg.sender, collateralPoolID ) > 0, "User does not have any collateral" );
		require( amountRepaid <= usdsBorrowedByUsers[msg.sender], "Cannot repay more than the borrowed amount" );
		require( amountRepaid > 0, "Cannot repay zero amount" );

		// Decrease the borrowed amount for the user
		usdsBorrowedByUsers[msg.sender] -= amountRepaid;

		// Have the user send the USDS to the USDS contract so that it can later be burned (on USDS.performUpkeep)
		usds.safeTransferFrom(msg.sender, address(usds), amountRepaid);

		// Have USDS remember that the USDS should be burned
		liquidizer.incrementBurnableUSDS( amountRepaid );

		// Check if the user no longer has any borrowed USDS
		if ( usdsBorrowedByUsers[msg.sender] == 0 )
			_walletsWithBorrowedUSDS.remove(msg.sender);

		emit RepaidUSDS(msg.sender, amountRepaid);
		}


	// Liquidate a position which has fallen under the minimum collateral ratio.
	// A default 5% of the value of the collateral is sent to the caller, with the rest being sent to the Liquidator for later conversion to USDS which is then burned.
	function liquidateUser( address wallet ) external nonReentrant
		{
		require( wallet != msg.sender, "Cannot liquidate self" );

		// First, make sure that the user's collateral ratio is below the required level
		require( canUserBeLiquidated(wallet), "User cannot be liquidated" );

		uint256 userCollateralAmount = userShareForPool( wallet, collateralPoolID );

		// Withdraw the liquidated collateral from the liquidity pool.
		// The liquidity is owned by this contract so when it is withdrawn it will be reclaimed by this contract.
		(uint256 reclaimedWBTC, uint256 reclaimedWETH) = pools.removeLiquidity(wbtc, weth, userCollateralAmount, 0, 0, totalShares[collateralPoolID] );

		// Decrease the user's share of collateral as it has been liquidated and they no longer have it.
		_decreaseUserShare( wallet, collateralPoolID, userCollateralAmount, true );

		// The caller receives a default 5% of the value of the liquidated collateral.
		uint256 rewardPercent = stableConfig.rewardPercentForCallingLiquidation();

		uint256 rewardedWBTC = (reclaimedWBTC * rewardPercent) / 100;
		uint256 rewardedWETH = (reclaimedWETH * rewardPercent) / 100;

		// Make sure the value of the rewardAmount is not excessive
		uint256 rewardValue = underlyingTokenValueInUSD( rewardedWBTC, rewardedWETH ); // in 18 decimals
		uint256 maxRewardValue = stableConfig.maxRewardValueForCallingLiquidation(); // 18 decimals
		if ( rewardValue > maxRewardValue )
			{
			rewardedWBTC = (rewardedWBTC * maxRewardValue) / rewardValue;
			rewardedWETH = (rewardedWETH * maxRewardValue) / rewardValue;
			}

		// Reward the caller
		wbtc.safeTransfer( msg.sender, rewardedWBTC );
		weth.safeTransfer( msg.sender, rewardedWETH );

		// Send the remaining WBTC and WETH to the Liquidizer contract so that the tokens can be converted to USDS and burned (on Liquidizer.performUpkeep)
		wbtc.safeTransfer( address(liquidizer), reclaimedWBTC - rewardedWBTC );
		weth.safeTransfer( address(liquidizer), reclaimedWETH - rewardedWETH );

		// Have the Liquidizer contract remember the amount of USDS that will need to be burned.
		uint256 originallyBorrowedUSDS = usdsBorrowedByUsers[wallet];
		liquidizer.incrementBurnableUSDS(originallyBorrowedUSDS);

		// Clear the borrowedUSDS for the user who was liquidated so that they can simply keep the USDS they previously borrowed.
		usdsBorrowedByUsers[wallet] = 0;
		_walletsWithBorrowedUSDS.remove(wallet);

		emit Liquidation(msg.sender, wallet, reclaimedWBTC, reclaimedWETH, originallyBorrowedUSDS);
		}


	// === VIEWS ===

	// The current market value in USD for a given amount of BTC and ETH using the PriceAggregator
	// Returns the value with 18 decimals
	function underlyingTokenValueInUSD( uint256 amountBTC, uint256 amountETH ) public view returns (uint256)
		{
		// Prices from the price feed have 18 decimals
		uint256 btcPrice = priceAggregator.getPriceBTC();
        uint256 ethPrice = priceAggregator.getPriceETH();

		// Keep the 18 decimals from the price and remove the decimals from the token balance
		uint256 btcValue = ( amountBTC * btcPrice ) / wbtcTenToTheDecimals;
		uint256 ethValue = ( amountETH * ethPrice ) / wethTenToTheDecimals;

		return btcValue + ethValue;
		}


	// The current market value of all WBTC/WETH collateral that has been deposited
	// Returns the value with 18 decimals
	function totalCollateralValueInUSD() public view returns (uint256)
		{
		(uint256 reservesWBTC, uint256 reservesWETH) = pools.getPoolReserves(wbtc, weth);

		return underlyingTokenValueInUSD( reservesWBTC, reservesWETH );
		}


	// The current market value of the user's collateral in USD
	// Returns the value with 18 decimals
	function userCollateralValueInUSD( address wallet ) public view returns (uint256)
		{
		uint256 userCollateralAmount = userShareForPool( wallet, collateralPoolID );
		if ( userCollateralAmount == 0 )
			return 0;

		uint256 totalCollateralShares = totalShares[collateralPoolID];

		// Determine how much collateral share the user currently has
		(uint256 reservesWBTC, uint256 reservesWETH) = pools.getPoolReserves(wbtc, weth);

		uint256 userWBTC = (reservesWBTC * userCollateralAmount ) / totalCollateralShares;
		uint256 userWETH = (reservesWETH * userCollateralAmount ) / totalCollateralShares;

		return underlyingTokenValueInUSD( userWBTC, userWETH );
		}


	// The maximum amount of collateral that can be withdrawn while keeping the collateral ratio above a default of 200%
	// Returns value with 18 decimals
	function maxWithdrawableCollateral( address wallet ) public view returns (uint256)
		{
		uint256 userCollateralAmount = userShareForPool( wallet, collateralPoolID );

		// If the user has no collateral then they can't withdraw any collateral
		if ( userCollateralAmount == 0 )
			return 0;

		// When withdrawing, require that the user keep at least the inital collateral ratio (default 200%)
		uint256 requiredCollateralValueAfterWithdrawal = ( usdsBorrowedByUsers[wallet] * stableConfig.initialCollateralRatioPercent() ) / 100;
		uint256 userCollateralValue = userCollateralValueInUSD( wallet );

		// If the user doesn't even have the minimum amount of required collateral then return zero
		if ( userCollateralValue <= requiredCollateralValueAfterWithdrawal )
			return 0;

		// The maximum withdrawable value in USD
		uint256 maxWithdrawableValue = userCollateralValue - requiredCollateralValueAfterWithdrawal;

		// Return the collateralAmount that can be withdrawn
		return userCollateralAmount * maxWithdrawableValue / userCollateralValue;
   		}


	// The maximum amount of USDS that can be borrowed given the user's current collateral and existing balance of borrowedUSDS.
	// Max borrowable USDS defaults to 50% of collateral value.
	// Returns value with 18 decimals.
	function maxBorrowableUSDS( address wallet ) public view returns (uint256)
		{
		// If the user doesn't have any collateral, then they can't borrow any USDS
		if ( userShareForPool( wallet, collateralPoolID ) == 0 )
			return 0;

		// The user's current collateral value will determine the maximum amount that can be borrowed
		uint256 userCollateralValue  = userCollateralValueInUSD( wallet );

		if ( userCollateralValue < stableConfig.minimumCollateralValueForBorrowing() )
			return 0;

		uint256 maxBorrowableAmount = ( userCollateralValue * 100 ) / stableConfig.initialCollateralRatioPercent();

		// Already borrowing more than the max?
		if ( usdsBorrowedByUsers[wallet] >= maxBorrowableAmount )
			return 0;

		return maxBorrowableAmount - usdsBorrowedByUsers[wallet];
   		}


	function numberOfUsersWithBorrowedUSDS() public view returns (uint256)
		{
		return _walletsWithBorrowedUSDS.length();
		}


	// Confirm that a user can be liquidated - that they have borrowed USDS and that their collateral value / borrowedUSDS ratio is less than the minimum required
	function canUserBeLiquidated( address wallet ) public view returns (bool)
		{
		// Check the current collateral ratio for the user
		uint256 usdsBorrowedAmount = usdsBorrowedByUsers[wallet];
		if ( usdsBorrowedAmount == 0 )
			return false;

		uint256 userCollateralValue = userCollateralValueInUSD(wallet);

		// Make sure the user's position is under collateralized
		return (( userCollateralValue * 100 ) / usdsBorrowedAmount) < stableConfig.minimumCollateralRatioPercent();
		}


	function findLiquidatableUsers( uint256 startIndex, uint256 endIndex ) public view returns (address[] memory)
		{
		address[] memory liquidatableUsers = new address[](endIndex - startIndex + 1);
		uint256 count = 0;

		// Cache
		uint256 totalCollateralShares = totalShares[collateralPoolID];
		uint256 totalCollateralValue = totalCollateralValueInUSD();

		if ( totalCollateralValue != 0 )
			for ( uint256 i = startIndex; i <= endIndex; i++ )
				{
				address wallet = _walletsWithBorrowedUSDS.at(i);

				// Determine the minCollateralValue a user needs to have based on their borrowedUSDS
				uint256 minCollateralValue = (usdsBorrowedByUsers[wallet] * stableConfig.minimumCollateralRatioPercent()) / 100;

				// Determine minCollateral in terms of minCollateralValue
				uint256 minCollateral = (minCollateralValue * totalCollateralShares) / totalCollateralValue;

				// Make sure the user has at least minCollateral
				if ( userShareForPool( wallet, collateralPoolID ) < minCollateral )
					liquidatableUsers[count++] = wallet;
				}

		// Resize the array to match the actual number of liquidatable positions found
		address[] memory resizedLiquidatableUsers = new address[](count);
		for ( uint256 i = 0; i < count; i++ )
			resizedLiquidatableUsers[i] = liquidatableUsers[i];

		return resizedLiquidatableUsers;
		}


	function findLiquidatableUsers() external view returns (address[] memory)
		{
		if ( numberOfUsersWithBorrowedUSDS() == 0 )
			return new address[](0);

		return findLiquidatableUsers( 0, numberOfUsersWithBorrowedUSDS() - 1 );
		}
	}
