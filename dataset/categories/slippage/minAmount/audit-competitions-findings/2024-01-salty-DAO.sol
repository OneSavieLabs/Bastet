// SPDX-License-Identifier: BUSL 1.1
pragma solidity =0.8.22;

import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "../price_feed/interfaces/IPriceAggregator.sol";
import "../rewards/interfaces/IRewardsEmitter.sol";
import "../rewards/interfaces/IRewardsConfig.sol";
import "../stable/interfaces/IStableConfig.sol";
import "../stable/interfaces/ILiquidizer.sol";
import "../interfaces/IExchangeConfig.sol";
import "../staking/interfaces/IStaking.sol";
import "../interfaces/IAccessManager.sol";
import "./interfaces/ICalledContract.sol";
import "./interfaces/IProposals.sol";
import "./interfaces/IDAO.sol";
import "../pools/PoolUtils.sol";
import "./Parameters.sol";
import "../Upkeep.sol";


// Allows users to propose and vote on various governance actions such as changing parameters, whitelisting/unwhitelisting tokens, sending tokens, calling other contracts, and updating the website.
// It handles proposing ballots, tracking votes, enforcing voting requirements, and executing approved proposals.
contract DAO is IDAO, Parameters, ReentrancyGuard
    {
	event BallotFinalized(uint256 indexed ballotID, Vote winningVote);
    event SetContract(string indexed ballotName, address indexed contractAddress);
    event SetWebsiteURL(string newURL);
    event WhitelistToken(IERC20 indexed token);
    event UnwhitelistToken(IERC20 indexed token);
    event GeoExclusionUpdated(string country, bool excluded, uint256 geoVersion);
    event ArbitrageProfitsWithdrawn(address indexed upkeepContract, IERC20 indexed weth, uint256 withdrawnAmount);
    event SaltSent(address indexed to, uint256 amount);
    event ContractCalled(address indexed contractAddress, uint256 indexed intArg);
    event TeamRewardsTransferred(uint256 teamAmount);

    event POLFormed(IERC20 indexed tokenA, IERC20 indexed tokenB, uint256 amountA, uint256 amountB);
    event POLProcessed(uint256 claimedSALT);
    event POLWithdrawn(IERC20 indexed tokenA, IERC20 indexed tokenB, uint256 withdrawnA, uint256 withdrawnB);

	using SafeERC20 for ISalt;
	using SafeERC20 for IERC20;
	using SafeERC20 for IUSDS;

	IPools immutable public pools;
	IProposals immutable public proposals;
	IExchangeConfig immutable public exchangeConfig;
	IPoolsConfig immutable public poolsConfig;
	IStakingConfig immutable public stakingConfig;
	IRewardsConfig immutable public rewardsConfig;
	IStableConfig immutable public stableConfig;
	IDAOConfig immutable public daoConfig;
	IPriceAggregator immutable public priceAggregator;
	IRewardsEmitter immutable public liquidityRewardsEmitter;
	ICollateralAndLiquidity immutable public collateralAndLiquidity;
	ILiquidizer immutable public liquidizer;

	ISalt immutable public salt;
    IUSDS immutable public usds;
	IERC20 immutable public dai;


	// The default IPFS URL for the website content (can be changed with a setWebsiteURL proposal)
	string public websiteURL;

	// Countries that have been excluded from access to the DEX (used by AccessManager.sol)
	// Keys as ISO 3166 Alpha-2 Codes
	mapping(string=>bool) public excludedCountries;


    constructor( IPools _pools, IProposals _proposals, IExchangeConfig _exchangeConfig, IPoolsConfig _poolsConfig, IStakingConfig _stakingConfig, IRewardsConfig _rewardsConfig, IStableConfig _stableConfig, IDAOConfig _daoConfig, IPriceAggregator _priceAggregator, IRewardsEmitter _liquidityRewardsEmitter, ICollateralAndLiquidity _collateralAndLiquidity )
		{
		pools = _pools;
		proposals = _proposals;
		exchangeConfig = _exchangeConfig;
		poolsConfig = _poolsConfig;
		stakingConfig = _stakingConfig;
		rewardsConfig = _rewardsConfig;
		stableConfig = _stableConfig;
		daoConfig = _daoConfig;
		priceAggregator = _priceAggregator;
        liquidityRewardsEmitter = _liquidityRewardsEmitter;
        collateralAndLiquidity = _collateralAndLiquidity;
 		liquidizer = collateralAndLiquidity.liquidizer();

        usds = exchangeConfig.usds();
        salt = exchangeConfig.salt();
        dai = exchangeConfig.dai();

		// Gas saving approves for eventually forming Protocol Owned Liquidity
		salt.approve(address(collateralAndLiquidity), type(uint256).max);
		usds.approve(address(collateralAndLiquidity), type(uint256).max);
		dai.approve(address(collateralAndLiquidity), type(uint256).max);

		// Excluded by default: United States, Canada, United Kingdom, China, India, Pakistan, Russia, Afghanistan, Cuba, Iran, North Korea, Syria, Venezuela
		// Note that the DAO can remove any of these exclusions - or open up access completely to the exchange as it sees fit.
		excludedCountries["US"] = true;
		excludedCountries["CA"] = true;
		excludedCountries["GB"] = true;
		excludedCountries["CN"] = true;
		excludedCountries["IN"] = true;
		excludedCountries["PK"] = true;
		excludedCountries["RU"] = true;
		excludedCountries["AF"] = true;
		excludedCountries["CU"] = true;
		excludedCountries["IR"] = true;
		excludedCountries["KP"] = true;
		excludedCountries["SY"] = true;
		excludedCountries["VE"] = true;
        }


	// Finalize the vote for a parameter ballot (increase, decrease or no_change) for a given parameter
	function _finalizeParameterBallot( uint256 ballotID ) internal
		{
		Ballot memory ballot = proposals.ballotForID(ballotID);

		Vote winningVote = proposals.winningParameterVote(ballotID);

		if ( winningVote == Vote.INCREASE )
			_executeParameterChange( ParameterTypes(ballot.number1), true, poolsConfig, stakingConfig, rewardsConfig, stableConfig, daoConfig, priceAggregator );
		else if ( winningVote == Vote.DECREASE )
			_executeParameterChange( ParameterTypes(ballot.number1), false, poolsConfig, stakingConfig, rewardsConfig, stableConfig, daoConfig, priceAggregator );

		// Finalize the ballot even if NO_CHANGE won
		proposals.markBallotAsFinalized(ballotID);

		emit BallotFinalized(ballotID, winningVote);
		}


	function _executeSetContract( Ballot memory ballot ) internal
		{
		bytes32 nameHash = keccak256(bytes( ballot.ballotName ) );

		if ( nameHash == keccak256(bytes( "setContract:priceFeed1_confirm" )) )
			priceAggregator.setPriceFeed( 1, IPriceFeed(ballot.address1) );
		else if ( nameHash == keccak256(bytes( "setContract:priceFeed2_confirm" )) )
			priceAggregator.setPriceFeed( 2, IPriceFeed(ballot.address1) );
		else if ( nameHash == keccak256(bytes( "setContract:priceFeed3_confirm" )) )
			priceAggregator.setPriceFeed( 3, IPriceFeed(ballot.address1) );
		else if ( nameHash == keccak256(bytes( "setContract:accessManager_confirm" )) )
			exchangeConfig.setAccessManager( IAccessManager(ballot.address1) );

		emit SetContract(ballot.ballotName, ballot.address1);
		}


	function _executeSetWebsiteURL( Ballot memory ballot ) internal
		{
		websiteURL = ballot.string1;
		emit SetWebsiteURL(ballot.string1);
		}


	function _executeApproval( Ballot memory ballot ) internal
		{
		if ( ballot.ballotType == BallotType.UNWHITELIST_TOKEN )
			{
			// All tokens are paired with both WBTC and WETH so unwhitelist those pools
			poolsConfig.unwhitelistPool( pools, IERC20(ballot.address1), exchangeConfig.wbtc() );
			poolsConfig.unwhitelistPool( pools, IERC20(ballot.address1), exchangeConfig.weth() );

			emit UnwhitelistToken(IERC20(ballot.address1));
			}

		else if ( ballot.ballotType == BallotType.SEND_SALT )
			{
			// Make sure the contract has the SALT balance before trying to send it.
			// This should not happen but is here just in case - to prevent approved proposals from reverting on finalization.
			if ( exchangeConfig.salt().balanceOf(address(this)) >= ballot.number1 )
				{
				IERC20(exchangeConfig.salt()).safeTransfer( ballot.address1, ballot.number1 );

				emit SaltSent(ballot.address1, ballot.number1);
				}
			}

		else if ( ballot.ballotType == BallotType.CALL_CONTRACT )
			{
			ICalledContract(ballot.address1).callFromDAO( ballot.number1 );

			emit ContractCalled(ballot.address1, ballot.number1);
			}

		else if ( ballot.ballotType == BallotType.INCLUDE_COUNTRY )
			{
			excludedCountries[ ballot.string1 ] = false;

			emit GeoExclusionUpdated(ballot.string1, false, exchangeConfig.accessManager().geoVersion());
			}

		else if ( ballot.ballotType == BallotType.EXCLUDE_COUNTRY )
			{
			excludedCountries[ ballot.string1 ] = true;

			// If the AccessManager doesn't implement excludedCountriesUpdated, this will revert and countries will not be able to be excluded until the AccessManager is working properly.
			exchangeConfig.accessManager().excludedCountriesUpdated();

			emit GeoExclusionUpdated(ballot.string1, true, exchangeConfig.accessManager().geoVersion());
			}

		// Once an initial setContract proposal passes, it automatically starts a second confirmation ballot (to prevent last minute approvals)
		else if ( ballot.ballotType == BallotType.SET_CONTRACT )
			proposals.createConfirmationProposal( string.concat(ballot.ballotName, "_confirm"), BallotType.CONFIRM_SET_CONTRACT, ballot.address1, "", ballot.description );

		// Once an initial setWebsiteURL proposal passes, it automatically starts a second confirmation ballot (to prevent last minute approvals)
		else if ( ballot.ballotType == BallotType.SET_WEBSITE_URL )
			proposals.createConfirmationProposal( string.concat(ballot.ballotName, "_confirm"), BallotType.CONFIRM_SET_WEBSITE_URL, address(0), ballot.string1, ballot.description );

		else if ( ballot.ballotType == BallotType.CONFIRM_SET_CONTRACT )
			_executeSetContract( ballot );

		else if ( ballot.ballotType == BallotType.CONFIRM_SET_WEBSITE_URL )
			_executeSetWebsiteURL( ballot );
		}


	// Finalize the vote for an approval ballot (yes or no) for a given proposal
	function _finalizeApprovalBallot( uint256 ballotID ) internal
		{
		if ( proposals.ballotIsApproved(ballotID ) )
			{
			Ballot memory ballot = proposals.ballotForID(ballotID);
			_executeApproval( ballot );
			}

		proposals.markBallotAsFinalized(ballotID);
		}


	// Finalize and execute a token whitelisting ballot.
	// If the proposal is currently the whitelisting proposal with the most yes votes then the token can be whitelisted.
	// Only the top voted whitelisting proposal can be finalized - as whitelisting requires bootstrapping rewards to be sent from the DAO.
	// If NO > YES than the proposal is removed immediately (quorum would already have been determined - in canFinalizeBallot as called from finalizeBallot).
	function _finalizeTokenWhitelisting( uint256 ballotID ) internal
		{
		if ( proposals.ballotIsApproved(ballotID ) )
			{
			// The ballot is approved. Any reversions below will allow the ballot to be attemped to be finalized later - as the ballot won't be finalized on reversion.
			Ballot memory ballot = proposals.ballotForID(ballotID);

			uint256 bootstrappingRewards = daoConfig.bootstrappingRewards();

			// Make sure that the DAO contract holds the required amount of SALT for bootstrappingRewards.
			// Twice the bootstrapping rewards are needed (for both the token/WBTC and token/WETH pools)
			uint256 saltBalance = exchangeConfig.salt().balanceOf( address(this) );
			require( saltBalance >= bootstrappingRewards * 2, "Whitelisting is not currently possible due to insufficient bootstrapping rewards" );

			// Fail to whitelist for now if this isn't the whitelisting proposal with the most votes - can try again later.
			uint256 bestWhitelistingBallotID = proposals.tokenWhitelistingBallotWithTheMostVotes();
			require( bestWhitelistingBallotID == ballotID, "Only the token whitelisting ballot with the most votes can be finalized" );

			// All tokens are paired with both WBTC and WETH, so whitelist both pairings
			poolsConfig.whitelistPool( pools,  IERC20(ballot.address1), exchangeConfig.wbtc() );
			poolsConfig.whitelistPool( pools,  IERC20(ballot.address1), exchangeConfig.weth() );

			bytes32 pool1 = PoolUtils._poolID( IERC20(ballot.address1), exchangeConfig.wbtc() );
			bytes32 pool2 = PoolUtils._poolID( IERC20(ballot.address1), exchangeConfig.weth() );

			// Send the initial bootstrappingRewards to promote initial liquidity on these two newly whitelisted pools
			AddedReward[] memory addedRewards = new AddedReward[](2);
			addedRewards[0] = AddedReward( pool1, bootstrappingRewards );
			addedRewards[1] = AddedReward( pool2, bootstrappingRewards );

			exchangeConfig.salt().approve( address(liquidityRewardsEmitter), bootstrappingRewards * 2 );
			liquidityRewardsEmitter.addSALTRewards( addedRewards );

			emit WhitelistToken(IERC20(ballot.address1));
			}

		// Mark the ballot as finalized (which will also remove it from the list of open token whitelisting proposals)
		proposals.markBallotAsFinalized(ballotID);
		}


	// Finalize the vote on a specific ballot.
	// Can be called by anyone, but only actually finalizes the ballot if it can be finalized.
	function finalizeBallot( uint256 ballotID ) external nonReentrant
		{
		// Checks that ballot is live, and minimumEndTime and quorum have both been reached
		require( proposals.canFinalizeBallot(ballotID), "The ballot is not yet able to be finalized" );

		Ballot memory ballot = proposals.ballotForID(ballotID);

		if ( ballot.ballotType == BallotType.PARAMETER )
			_finalizeParameterBallot(ballotID);
		else if ( ballot.ballotType == BallotType.WHITELIST_TOKEN )
			_finalizeTokenWhitelisting(ballotID);
		else
			_finalizeApprovalBallot(ballotID);
		}


	// Withdraw the WETH arbitrage profits deposited in the Pools contract and send them to the caller (the Upkeep contract).
	function withdrawArbitrageProfits( IERC20 weth ) external returns (uint256 withdrawnAmount)
		{
		require( msg.sender == address(exchangeConfig.upkeep()), "DAO.withdrawArbitrageProfits is only callable from the Upkeep contract" );

		// The arbitrage profits are deposited in the Pools contract as WETH and owned by the DAO.
		uint256 depositedWETH = pools.depositedUserBalance(address(this), weth );
		if ( depositedWETH == 0 )
			return 0;

		pools.withdraw( weth, depositedWETH );

		// Check the WETH balance - in case any WETH was accidentally sent here previously
		withdrawnAmount = weth.balanceOf( address(this) );
		weth.safeTransfer( msg.sender, withdrawnAmount );

		emit ArbitrageProfitsWithdrawn(msg.sender, weth, withdrawnAmount);
		}


	// Form SALT/USDS or USDS/DAI Protocol Owned Liquidity using the given amount of specified tokens.
	// Assumes that the tokens have already been transferred to this contract.
	function formPOL( IERC20 tokenA, IERC20 tokenB, uint256 amountA, uint256 amountB ) external
		{
		require( msg.sender == address(exchangeConfig.upkeep()), "DAO.formPOL is only callable from the Upkeep contract" );

		// Use zapping to form the liquidity so that all the specified tokens are used
		collateralAndLiquidity.depositLiquidityAndIncreaseShare( tokenA, tokenB, amountA, amountB, 0, block.timestamp, true );

		emit POLFormed(tokenA, tokenB, amountA, amountB);
		}


	function processRewardsFromPOL() external
		{
		require( msg.sender == address(exchangeConfig.upkeep()), "DAO.processRewardsFromPOL is only callable from the Upkeep contract" );

		// The DAO owns SALT/USDS and USDS/DAI liquidity.
		bytes32[] memory poolIDs = new bytes32[](2);
		poolIDs[0] = PoolUtils._poolID(salt, usds);
		poolIDs[1] = PoolUtils._poolID(usds, dai);

		uint256 claimedSALT = collateralAndLiquidity.claimAllRewards(poolIDs);
		if ( claimedSALT == 0 )
			return;

		// Send 10% of the rewards to the initial team
		uint256 amountToSendToTeam = claimedSALT / 10;
		salt.safeTransfer( exchangeConfig.managedTeamWallet().mainWallet(), amountToSendToTeam );
		emit TeamRewardsTransferred(amountToSendToTeam);

		uint256 remainingSALT = claimedSALT - amountToSendToTeam;

		// Burn a default 50% of the remaining SALT that was just claimed - the rest of the SALT stays in the DAO contract.
		uint256 saltToBurn = ( remainingSALT * daoConfig.percentPolRewardsBurned() ) / 100;

		salt.safeTransfer( address(salt), saltToBurn );
		salt.burnTokensInContract();

		emit POLProcessed(claimedSALT);
		}


	// Withdraws the specified amount of the Protocol Owned Liquidity from the DAO and sends the underlying tokens to the Liquidizer to be burned as USDS as needed.
	// Called when the amount of recovered USDS from liquidating a user's WBTC/WETH collateral is insufficient to cover burning the USDS that they had borrowed.
	// Only callable from the Liquidizer contract.
	function withdrawPOL( IERC20 tokenA, IERC20 tokenB, uint256 percentToLiquidate ) external
		{
		require(msg.sender == address(liquidizer), "DAO.withdrawProtocolOwnedLiquidity is only callable from the Liquidizer contract" );

		bytes32 poolID = PoolUtils._poolID(tokenA, tokenB);
		uint256 liquidityHeld = collateralAndLiquidity.userShareForPool( address(this), poolID );
		if ( liquidityHeld == 0 )
			return;

		uint256 liquidityToWithdraw = (liquidityHeld * percentToLiquidate) / 100;

		// Withdraw the specified Protocol Owned Liquidity
		(uint256 reclaimedA, uint256 reclaimedB) = collateralAndLiquidity.withdrawLiquidityAndClaim(tokenA, tokenB, liquidityToWithdraw, 0, 0, block.timestamp );

		// Send the withdrawn tokens to the Liquidizer so that the tokens can be swapped to USDS and burned as needed.
		tokenA.safeTransfer( address(liquidizer), reclaimedA );
		tokenB.safeTransfer( address(liquidizer), reclaimedB );

		emit POLWithdrawn(tokenA, tokenB, reclaimedA, reclaimedB);
		}


	// === VIEWS ===

	function countryIsExcluded( string calldata country ) external view returns (bool)
		{
		return excludedCountries[country];
		}
	}