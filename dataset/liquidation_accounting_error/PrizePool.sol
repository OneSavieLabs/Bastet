// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeCast } from "openzeppelin/utils/math/SafeCast.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { SD59x18, convert, sd } from "prb-math/SD59x18.sol";
import { SD1x18, unwrap, UNIT } from "prb-math/SD1x18.sol";
import { TwabController } from "pt-v5-twab-controller/TwabController.sol";

import { DrawAccumulatorLib, Observation, MAX_OBSERVATION_CARDINALITY } from "./libraries/DrawAccumulatorLib.sol";
import { TieredLiquidityDistributor, Tier } from "./abstract/TieredLiquidityDistributor.sol";
import { TierCalculationLib } from "./libraries/TierCalculationLib.sol";

/// @notice Thrown when the prize pool is constructed with a first draw open timestamp that is in the past
error FirstDrawOpensInPast();

/// @notice Thrown when the Twab Controller has an incompatible period length
error IncompatibleTwabPeriodLength();

/// @notice Thrown when the Twab Controller has an incompatible period offset
error IncompatibleTwabPeriodOffset();

/// @notice Thrown when someone tries to set the draw manager with the zero address
error DrawManagerIsZeroAddress();

/// @notice Thrown when the passed creator is the zero address
error CreatorIsZeroAddress();

/// @notice Thrown when the caller is not the deployer.
error NotDeployer();

/// @notice Thrown when the range start draw id is computed with range of zero
error RangeSizeZero();

/// @notice Thrown if the prize pool has shutdown
error PrizePoolShutdown();

/// @notice Thrown if the prize pool is not shutdown
error PrizePoolNotShutdown();

/// @notice Thrown when someone tries to withdraw too many rewards.
/// @param requested The requested reward amount to withdraw
/// @param available The total reward amount available for the caller to withdraw
error InsufficientRewardsError(uint256 requested, uint256 available);

/// @notice Thrown when an address did not win the specified prize on a vault when claiming.
/// @param vault The vault address
/// @param winner The address checked for the prize
/// @param tier The prize tier
/// @param prizeIndex The prize index
error DidNotWin(address vault, address winner, uint8 tier, uint32 prizeIndex);

/// @notice Thrown when the prize being claimed has already been claimed
/// @param vault The vault address
/// @param winner The address checked for the prize
/// @param tier The prize tier
/// @param prizeIndex The prize index
error AlreadyClaimed(address vault, address winner, uint8 tier, uint32 prizeIndex);

/// @notice Thrown when the claim reward exceeds the maximum.
/// @param reward The reward being claimed
/// @param maxReward The max reward that can be claimed
error RewardTooLarge(uint256 reward, uint256 maxReward);

/// @notice Thrown when the contributed amount is more than the available, un-accounted balance.
/// @param amount The contribution amount that is being claimed
/// @param available The available un-accounted balance that can be claimed as a contribution
error ContributionGTDeltaBalance(uint256 amount, uint256 available);

/// @notice Thrown when the withdraw amount is greater than the available reserve.
/// @param amount The amount being withdrawn
/// @param reserve The total reserve available for withdrawal
error InsufficientReserve(uint104 amount, uint104 reserve);

/// @notice Thrown when the winning random number is zero.
error RandomNumberIsZero();

/// @notice Thrown when the draw cannot be awarded since it has not closed.
/// @param drawClosesAt The timestamp in seconds at which the draw closes
error AwardingDrawNotClosed(uint48 drawClosesAt);

/// @notice Thrown when prize index is greater or equal to the max prize count for the tier.
/// @param invalidPrizeIndex The invalid prize index
/// @param prizeCount The prize count for the tier
/// @param tier The tier number
error InvalidPrizeIndex(uint32 invalidPrizeIndex, uint32 prizeCount, uint8 tier);

/// @notice Thrown when there are no awarded draws when a computation requires an awarded draw.
error NoDrawsAwarded();

/// @notice Thrown when the Prize Pool is constructed with a draw timeout of zero
error DrawTimeoutIsZero();

/// @notice Thrown when the Prize Pool is constructed with a draw timeout greater than the grand prize period draws
error DrawTimeoutGTGrandPrizePeriodDraws();

/// @notice Thrown when attempting to claim from a tier that does not exist.
/// @param tier The tier number that does not exist
/// @param numberOfTiers The current number of tiers
error InvalidTier(uint8 tier, uint8 numberOfTiers);

/// @notice Thrown when the caller is not the draw manager.
/// @param caller The caller address
/// @param drawManager The drawManager address
error CallerNotDrawManager(address caller, address drawManager);

/// @notice Thrown when someone tries to claim a prize that is zero size
error PrizeIsZero();

/// @notice Thrown when someone tries to claim a prize, but sets the reward recipient address to the zero address.
error RewardRecipientZeroAddress();

/// @notice Thrown when a claim is attempted after the claiming period has expired.
error ClaimPeriodExpired();

/// @notice Thrown when anyone but the creator calls a privileged function
error OnlyCreator();

/// @notice Thrown when the draw manager has already been set
error DrawManagerAlreadySet();

/// @notice Thrown when the grand prize period is too large
/// @param grandPrizePeriodDraws The set grand prize period
/// @param maxGrandPrizePeriodDraws The max grand prize period
error GrandPrizePeriodDrawsTooLarge(uint24 grandPrizePeriodDraws, uint24 maxGrandPrizePeriodDraws);

/// @notice Constructor Parameters
/// @param prizeToken The token to use for prizes
/// @param twabController The Twab Controller to retrieve time-weighted average balances from
/// @param creator The address that will be permitted to finish prize pool initialization after deployment
/// @param tierLiquidityUtilizationRate The rate at which liquidity is utilized for prize tiers. This allows
/// for deviations in prize claims; if 0.75e18 then it is 75% utilization so it can accommodate 25% deviation
/// in more prize claims.
/// @param drawPeriodSeconds The number of seconds between draws.
/// E.g. a Prize Pool with a daily draw should have a draw period of 86400 seconds.
/// @param firstDrawOpensAt The timestamp at which the first draw will open
/// @param grandPrizePeriodDraws The target number of draws to pass between each grand prize
/// @param numberOfTiers The number of tiers to start with. Must be greater than or equal to the minimum
/// number of tiers
/// @param tierShares The number of shares to allocate to each tier
/// @param canaryShares The number of shares to allocate to each canary tier
/// @param reserveShares The number of shares to allocate to the reserve
/// @param drawTimeout The number of draws that need to be missed before the prize pool shuts down. The timeout
/// resets when a draw is awarded.
struct ConstructorParams {
  IERC20 prizeToken;
  TwabController twabController;
  address creator;
  uint256 tierLiquidityUtilizationRate;
  uint48 drawPeriodSeconds;
  uint48 firstDrawOpensAt;
  uint24 grandPrizePeriodDraws;
  uint8 numberOfTiers;
  uint8 tierShares;
  uint8 canaryShares;
  uint8 reserveShares;
  uint24 drawTimeout;
}

/// @notice A struct to represent a shutdown portion of liquidity for a vault and account
/// @param numerator The numerator of the portion
/// @param denominator The denominator of the portion
struct ShutdownPortion {
  uint256 numerator;
  uint256 denominator;
}

/// @title PoolTogether V5 Prize Pool
/// @author G9 Software Inc. & PoolTogether Inc. Team
/// @notice The Prize Pool holds the prize liquidity and allows vaults to claim prizes.
contract PrizePool is TieredLiquidityDistributor {
  using SafeERC20 for IERC20;
  using DrawAccumulatorLib for DrawAccumulatorLib.Accumulator;

  /* ============ Events ============ */

  /// @notice Emitted when a prize is claimed.
  /// @param vault The address of the vault that claimed the prize.
  /// @param winner The address of the winner
  /// @param recipient The address of the prize recipient
  /// @param drawId The draw ID of the draw that was claimed.
  /// @param tier The prize tier that was claimed.
  /// @param prizeIndex The index of the prize that was claimed
  /// @param payout The amount of prize tokens that were paid out to the winner
  /// @param claimReward The amount of prize tokens that were paid to the claimer
  /// @param claimRewardRecipient The address that the claimReward was sent to
  event ClaimedPrize(
    address indexed vault,
    address indexed winner,
    address indexed recipient,
    uint24 drawId,
    uint8 tier,
    uint32 prizeIndex,
    uint152 payout,
    uint96 claimReward,
    address claimRewardRecipient
  );

  /// @notice Emitted when a draw is awarded.
  /// @param drawId The ID of the draw that was awarded
  /// @param winningRandomNumber The winning random number for the awarded draw
  /// @param lastNumTiers The previous number of prize tiers
  /// @param numTiers The number of prize tiers for the awarded draw
  /// @param reserve The resulting reserve available
  /// @param prizeTokensPerShare The amount of prize tokens per share for the awarded draw
  /// @param drawOpenedAt The start timestamp of the awarded draw
  event DrawAwarded(
    uint24 indexed drawId,
    uint256 winningRandomNumber,
    uint8 lastNumTiers,
    uint8 numTiers,
    uint104 reserve,
    uint128 prizeTokensPerShare,
    uint48 drawOpenedAt
  );

  /// @notice Emitted when any amount of the reserve is rewarded to a recipient.
  /// @param to The recipient of the reward
  /// @param amount The amount of assets rewarded
  event AllocateRewardFromReserve(address indexed to, uint256 amount);

  /// @notice Emitted when the reserve is manually increased.
  /// @param user The user who increased the reserve
  /// @param amount The amount of assets transferred
  event ContributedReserve(address indexed user, uint256 amount);

  /// @notice Emitted when a vault contributes prize tokens to the pool.
  /// @param vault The address of the vault that is contributing tokens
  /// @param drawId The ID of the first draw that the tokens will be contributed to
  /// @param amount The amount of tokens contributed
  event ContributePrizeTokens(address indexed vault, uint24 indexed drawId, uint256 amount);

  /// @notice Emitted when the draw manager is set
  /// @param drawManager The address of the draw manager
  event SetDrawManager(address indexed drawManager);

  /// @notice Emitted when an address withdraws their prize claim rewards.
  /// @param account The account that is withdrawing rewards
  /// @param to The address the rewards are sent to
  /// @param amount The amount withdrawn
  /// @param available The total amount that was available to withdraw before the transfer
  event WithdrawRewards(
    address indexed account,
    address indexed to,
    uint256 amount,
    uint256 available
  );

  /// @notice Emitted when an address receives new prize claim rewards.
  /// @param to The address the rewards are given to
  /// @param amount The amount increased
  event IncreaseClaimRewards(address indexed to, uint256 amount);

  /* ============ State ============ */

  /// @notice The DrawAccumulator that tracks the exponential moving average of the contributions by a vault.
  mapping(address vault => DrawAccumulatorLib.Accumulator accumulator) internal _vaultAccumulator;

  /// @notice Records the claim record for a winner.
  mapping(address vault => mapping(address account => mapping(uint24 drawId => mapping(uint8 tier => mapping(uint32 prizeIndex => bool claimed)))))
    internal _claimedPrizes;

  /// @notice Tracks the total rewards accrued for a claimer or draw completer.
  mapping(address recipient => uint256 rewards) internal _rewards;

  /// @notice The special value for the donator address. Contributions from this address are excluded from the total odds.
  /// @dev 0x000...F2EE because it's free money!
  address public constant DONATOR = 0x000000000000000000000000000000000000F2EE;

  /// @notice The token that is being contributed and awarded as prizes.
  IERC20 public immutable prizeToken;

  /// @notice The Twab Controller to use to retrieve historic balances.
  TwabController public immutable twabController;

  /// @notice The number of seconds between draws.
  uint48 public immutable drawPeriodSeconds;

  /// @notice The timestamp at which the first draw will open.
  uint48 public immutable firstDrawOpensAt;

  /// @notice The maximum number of draws that can be missed before the prize pool is considered inactive.
  uint24 public immutable drawTimeout;

  /// @notice The address that is allowed to set the draw manager
  address immutable creator;

  /// @notice The exponential weighted average of all vault contributions.
  DrawAccumulatorLib.Accumulator internal _totalAccumulator;

  /// @notice The winner random number for the last awarded draw.
  uint256 internal _winningRandomNumber;

  /// @notice The draw manager address.
  address public drawManager;

  /// @notice Tracks reserve that was contributed directly to the reserve. Always increases.
  uint96 internal _directlyContributedReserve;

  /// @notice The number of prize claims for the last awarded draw.
  uint24 public claimCount;

  /// @notice The total amount of prize tokens that have been claimed for all time.
  uint128 internal _totalWithdrawn;

  /// @notice The total amount of rewards that have yet to be claimed
  uint104 internal _totalRewardsToBeClaimed;

  /// @notice The observation at which the shutdown balance was recorded
  Observation shutdownObservation;
  
  /// @notice The balance available to be withdrawn at shutdown
  uint256 shutdownBalance;

  /// @notice The total contributed observation that was used for the last withdrawal for a vault and account
  mapping(address vault => mapping(address account => Observation lastWithdrawalTotalContributedObservation)) internal _withdrawalObservations;

  /// @notice The shutdown portion of liquidity for a vault and account
  mapping(address vault => mapping(address account => ShutdownPortion shutdownPortion)) internal _shutdownPortions;

  /* ============ Constructor ============ */

  /// @notice Constructs a new Prize Pool.
  /// @param params A struct of constructor parameters
  constructor(
    ConstructorParams memory params
  )
    TieredLiquidityDistributor(
      params.tierLiquidityUtilizationRate,
      params.numberOfTiers,
      params.tierShares,
      params.canaryShares,
      params.reserveShares,
      params.grandPrizePeriodDraws
    )
  {
    if (params.drawTimeout == 0) {
      revert DrawTimeoutIsZero();
    }

    if (params.drawTimeout > params.grandPrizePeriodDraws) {
      revert DrawTimeoutGTGrandPrizePeriodDraws();
    }

    if (params.firstDrawOpensAt < block.timestamp) {
      revert FirstDrawOpensInPast();
    }

    if (params.grandPrizePeriodDraws >= MAX_OBSERVATION_CARDINALITY) {
      revert GrandPrizePeriodDrawsTooLarge(params.grandPrizePeriodDraws, MAX_OBSERVATION_CARDINALITY - 1);
    }

    uint48 twabPeriodOffset = params.twabController.PERIOD_OFFSET();
    uint48 twabPeriodLength = params.twabController.PERIOD_LENGTH();

    if (
      params.drawPeriodSeconds < twabPeriodLength ||
      params.drawPeriodSeconds % twabPeriodLength != 0
    ) {
      revert IncompatibleTwabPeriodLength();
    }

    if ((params.firstDrawOpensAt - twabPeriodOffset) % twabPeriodLength != 0) {
      revert IncompatibleTwabPeriodOffset();
    }

    if (params.creator == address(0)) {
      revert CreatorIsZeroAddress();
    }

    creator = params.creator;
    drawTimeout = params.drawTimeout;
    prizeToken = params.prizeToken;
    twabController = params.twabController;
    drawPeriodSeconds = params.drawPeriodSeconds;
    firstDrawOpensAt = params.firstDrawOpensAt;
  }

  /* ============ Modifiers ============ */

  /// @notice Modifier that throws if sender is not the draw manager.
  modifier onlyDrawManager() {
    if (msg.sender != drawManager) {
      revert CallerNotDrawManager(msg.sender, drawManager);
    }
    _;
  }

  /// @notice Sets the Draw Manager contract on the prize pool. Can only be called once by the creator.
  /// @param _drawManager The address of the Draw Manager contract
  function setDrawManager(address _drawManager) external {
    if (msg.sender != creator) {
      revert OnlyCreator();
    }
    if (drawManager != address(0)) {
      revert DrawManagerAlreadySet();
    }
    drawManager = _drawManager;

    emit SetDrawManager(_drawManager);
  }

  /* ============ External Write Functions ============ */

  /// @notice Contributes prize tokens on behalf of the given vault.
  /// @dev The tokens should have already been transferred to the prize pool.
  /// @dev The prize pool balance will be checked to ensure there is at least the given amount to deposit.
  /// @param _prizeVault The address of the vault to contribute to
  /// @param _amount The amount of prize tokens to contribute
  /// @return The amount of available prize tokens prior to the contribution.
  function contributePrizeTokens(address _prizeVault, uint256 _amount) public returns (uint256) {
    uint256 _deltaBalance = prizeToken.balanceOf(address(this)) - accountedBalance();
    if (_deltaBalance < _amount) {
      revert ContributionGTDeltaBalance(_amount, _deltaBalance);
    }
    uint24 openDrawId_ = getOpenDrawId();
    _vaultAccumulator[_prizeVault].add(_amount, openDrawId_);
    _totalAccumulator.add(_amount, openDrawId_);
    emit ContributePrizeTokens(_prizeVault, openDrawId_, _amount);
    return _deltaBalance;
  }

  /// @notice Allows a user to donate prize tokens to the prize pool.
  /// @param _amount The amount of tokens to donate. The amount should already be approved for transfer.
  function donatePrizeTokens(uint256 _amount) external {
    prizeToken.safeTransferFrom(msg.sender, address(this), _amount);
    contributePrizeTokens(DONATOR, _amount);
  }

  /// @notice Allows the Manager to allocate a reward from the reserve to a recipient.
  /// @param _to The address to allocate the rewards to
  /// @param _amount The amount of tokens for the reward
  function allocateRewardFromReserve(address _to, uint96 _amount) external onlyDrawManager notShutdown {
    if (_to == address(0)) {
      revert RewardRecipientZeroAddress();
    }
    if (_amount > _reserve) {
      revert InsufficientReserve(_amount, _reserve);
    }

    unchecked {
      _reserve -= _amount;
    }

    _rewards[_to] += _amount;
    _totalRewardsToBeClaimed = SafeCast.toUint104(_totalRewardsToBeClaimed + _amount);
    emit AllocateRewardFromReserve(_to, _amount);
  }

  /// @notice Allows the Manager to award a draw with the winning random number.
  /// @dev Updates the number of tiers, the winning random number and the prize pool reserve.
  /// @param winningRandomNumber_ The winning random number for the draw
  /// @return The ID of the awarded draw
  function awardDraw(uint256 winningRandomNumber_) external onlyDrawManager notShutdown returns (uint24) {
    // check winning random number
    if (winningRandomNumber_ == 0) {
      revert RandomNumberIsZero();
    }
    uint24 awardingDrawId = getDrawIdToAward();
    uint48 awardingDrawOpenedAt = drawOpensAt(awardingDrawId);
    uint48 awardingDrawClosedAt = awardingDrawOpenedAt + drawPeriodSeconds;
    if (block.timestamp < awardingDrawClosedAt) {
      revert AwardingDrawNotClosed(awardingDrawClosedAt);
    }

    uint24 lastAwardedDrawId_ = _lastAwardedDrawId;
    uint32 _claimCount = claimCount;
    uint8 _numTiers = numberOfTiers;
    uint8 _nextNumberOfTiers = _numTiers;

    _nextNumberOfTiers = computeNextNumberOfTiers(_claimCount);

    // If any draws were skipped from the last awarded draw to the one we are awarding, the contribution
    // from those skipped draws will be included in the new distributions.
    _awardDraw(
      awardingDrawId,
      _nextNumberOfTiers,
      getTotalContributedBetween(lastAwardedDrawId_ + 1, awardingDrawId)
    );

    _winningRandomNumber = winningRandomNumber_;
    if (_claimCount != 0) {
      claimCount = 0;
    }

    emit DrawAwarded(
      awardingDrawId,
      winningRandomNumber_,
      _numTiers,
      _nextNumberOfTiers,
      _reserve,
      prizeTokenPerShare,
      awardingDrawOpenedAt
    );

    return awardingDrawId;
  }

  /// @notice Claims a prize for a given winner and tier.
  /// @dev This function takes in an address _winner, a uint8 _tier, a uint96 _claimReward, and an
  /// address _claimRewardRecipient. It checks if _winner is actually the winner of the _tier for the calling vault.
  /// If so, it calculates the prize size and transfers it to the winner. If not, it reverts with an error message.
  /// The function then checks the claim record of _winner to see if they have already claimed the prize for the
  /// awarded draw. If not, it updates the claim record with the claimed tier and emits a ClaimedPrize event with
  /// information about the claim.
  /// Note that this function can modify the state of the contract by updating the claim record, changing the largest
  /// tier claimed and the claim count, and transferring prize tokens. The function is marked as external which
  /// means that it can be called from outside the contract.
  /// @param _winner The address of the eligible winner
  /// @param _tier The tier of the prize to be claimed.
  /// @param _prizeIndex The prize to claim for the winner. Must be less than the prize count for the tier.
  /// @param _prizeRecipient The recipient of the prize
  /// @param _claimReward The claimReward associated with claiming the prize.
  /// @param _claimRewardRecipient The address to receive the claimReward.
  /// @return Total prize amount claimed (payout and claimRewards combined).
  function claimPrize(
    address _winner,
    uint8 _tier,
    uint32 _prizeIndex,
    address _prizeRecipient,
    uint96 _claimReward,
    address _claimRewardRecipient
  ) external returns (uint256) {
    /// @dev Claims cannot occur after a draw has been finalized (1 period after a draw closes). This prevents
    /// the reserve from changing while the following draw is being awarded.
    uint24 lastAwardedDrawId_ = _lastAwardedDrawId;
    if (isDrawFinalized(lastAwardedDrawId_)) {
      revert ClaimPeriodExpired();
    }
    if (_claimRewardRecipient == address(0) && _claimReward > 0) {
      revert RewardRecipientZeroAddress();
    }

    uint8 _numTiers = numberOfTiers;

    Tier memory tierLiquidity = _getTier(_tier, _numTiers);

    if (_claimReward > tierLiquidity.prizeSize) {
      revert RewardTooLarge(_claimReward, tierLiquidity.prizeSize);
    }

    if (tierLiquidity.prizeSize == 0) {
      revert PrizeIsZero();
    }

    if (!isWinner(msg.sender, _winner, _tier, _prizeIndex)) {
      revert DidNotWin(msg.sender, _winner, _tier, _prizeIndex);
    }

    if (_claimedPrizes[msg.sender][_winner][lastAwardedDrawId_][_tier][_prizeIndex]) {
      revert AlreadyClaimed(msg.sender, _winner, _tier, _prizeIndex);
    }

    _claimedPrizes[msg.sender][_winner][lastAwardedDrawId_][_tier][_prizeIndex] = true;

    _consumeLiquidity(tierLiquidity, _tier, tierLiquidity.prizeSize);

    // `amount` is the payout amount
    uint256 amount;
    if (_claimReward != 0) {
      emit IncreaseClaimRewards(_claimRewardRecipient, _claimReward);
      _rewards[_claimRewardRecipient] += _claimReward;

      unchecked {
        amount = tierLiquidity.prizeSize - _claimReward;
      }
    } else {
      amount = tierLiquidity.prizeSize;
    }

    // co-locate to save gas
    claimCount++;
    _totalWithdrawn = SafeCast.toUint128(_totalWithdrawn + amount);
    _totalRewardsToBeClaimed = SafeCast.toUint104(_totalRewardsToBeClaimed + _claimReward);

    emit ClaimedPrize(
      msg.sender,
      _winner,
      _prizeRecipient,
      lastAwardedDrawId_,
      _tier,
      _prizeIndex,
      uint152(amount),
      _claimReward,
      _claimRewardRecipient
    );

    if (amount > 0) {
      prizeToken.safeTransfer(_prizeRecipient, amount);
    }

    return tierLiquidity.prizeSize;
  }

  /// @notice Withdraws earned rewards for the caller.
  /// @param _to The address to transfer the rewards to
  /// @param _amount The amount of rewards to withdraw
  function withdrawRewards(address _to, uint256 _amount) external {
    uint256 _available = _rewards[msg.sender];

    if (_amount > _available) {
      revert InsufficientRewardsError(_amount, _available);
    }

    unchecked {
      _rewards[msg.sender] = _available - _amount;
    }

    _totalWithdrawn = SafeCast.toUint128(_totalWithdrawn + _amount);
    _totalRewardsToBeClaimed = SafeCast.toUint104(_totalRewardsToBeClaimed - _amount);

    // skip transfer if recipient is the prize pool (tokens stay in this contract)
    if (_to != address(this)) {
      prizeToken.safeTransfer(_to, _amount);
    }

    emit WithdrawRewards(msg.sender, _to, _amount, _available);
  }

  /// @notice Allows anyone to deposit directly into the Prize Pool reserve.
  /// @dev Ensure caller has sufficient balance and has approved the Prize Pool to transfer the tokens
  /// @param _amount The amount of tokens to increase the reserve by
  function contributeReserve(uint96 _amount) external notShutdown {
    _reserve += _amount;
    _directlyContributedReserve += _amount;
    prizeToken.safeTransferFrom(msg.sender, address(this), _amount);
    emit ContributedReserve(msg.sender, _amount);
  }

  /* ============ External Read Functions ============ */

  /// @notice Returns the winning random number for the last awarded draw.
  /// @return The winning random number
  function getWinningRandomNumber() external view returns (uint256) {
    return _winningRandomNumber;
  }

  /// @notice Returns the last awarded draw id.
  /// @return The last awarded draw id
  function getLastAwardedDrawId() external view returns (uint24) {
    return _lastAwardedDrawId;
  }

  /// @notice Returns the total prize tokens contributed by a particular vault between the given draw ids, inclusive.
  /// @param _vault The address of the vault
  /// @param _startDrawIdInclusive Start draw id inclusive
  /// @param _endDrawIdInclusive End draw id inclusive
  /// @return The total prize tokens contributed by the given vault
  function getContributedBetween(
    address _vault,
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) external view returns (uint256) {
    return
      _vaultAccumulator[_vault].getDisbursedBetween(
        _startDrawIdInclusive,
        _endDrawIdInclusive
      );
  }

  /// @notice Returns the total prize tokens donated to the prize pool
  /// @param _startDrawIdInclusive Start draw id inclusive
  /// @param _endDrawIdInclusive End draw id inclusive
  /// @return The total prize tokens donated to the prize pool
  function getDonatedBetween(
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) external view returns (uint256) {
    return
      _vaultAccumulator[DONATOR].getDisbursedBetween(
        _startDrawIdInclusive,
        _endDrawIdInclusive
      );
  }

  /// @notice Returns the newest observation for the total accumulator
  /// @return The newest observation
  function getTotalAccumulatorNewestObservation() external view returns (Observation memory) {
    return _totalAccumulator.newestObservation();
  }

  /// @notice Returns the newest observation for the specified vault accumulator
  /// @param _vault The vault to check
  /// @return The newest observation for the vault
  function getVaultAccumulatorNewestObservation(address _vault) external view returns (Observation memory) {
    return _vaultAccumulator[_vault].newestObservation();
  }

  /// @notice Computes the expected duration prize accrual for a tier.
  /// @param _tier The tier to check
  /// @return The number of draws
  function getTierAccrualDurationInDraws(uint8 _tier) external view returns (uint24) {
    return
      uint24(TierCalculationLib.estimatePrizeFrequencyInDraws(getTierOdds(_tier, numberOfTiers)));
  }

  /// @notice The total amount of prize tokens that have been withdrawn as fees or prizes
  /// @return The total amount of prize tokens that have been withdrawn as fees or prizes
  function totalWithdrawn() external view returns (uint256) {
    return _totalWithdrawn;
  }

  /// @notice Returns the amount of tokens that will be added to the reserve when next draw to award is awarded.
  /// @dev Intended for Draw manager to use after a draw has closed but not yet been awarded.
  /// @return The amount of prize tokens that will be added to the reserve
  function pendingReserveContributions() external view returns (uint256) {
    uint8 _numTiers = numberOfTiers;
    uint24 lastAwardedDrawId_ = _lastAwardedDrawId;

    (uint104 newReserve, ) = _computeNewDistributions(
      _numTiers,
      lastAwardedDrawId_ == 0 ? _numTiers : computeNextNumberOfTiers(claimCount),
      prizeTokenPerShare,
      getTotalContributedBetween(lastAwardedDrawId_ + 1, getDrawIdToAward())
    );

    return newReserve;
  }

  /// @notice Returns whether the winner has claimed the tier for the last awarded draw
  /// @param _vault The vault to check
  /// @param _winner The account to check
  /// @param _tier The tier to check
  /// @param _prizeIndex The prize index to check
  /// @return True if the winner claimed the tier for the last awarded draw, false otherwise.
  function wasClaimed(
    address _vault,
    address _winner,
    uint8 _tier,
    uint32 _prizeIndex
  ) external view returns (bool) {
    return _claimedPrizes[_vault][_winner][_lastAwardedDrawId][_tier][_prizeIndex];
  }

  /// @notice Returns whether the winner has claimed the tier for the specified draw
  /// @param _vault The vault to check
  /// @param _winner The account to check
  /// @param _drawId The draw ID to check
  /// @param _tier The tier to check
  /// @param _prizeIndex The prize index to check
  /// @return True if the winner claimed the tier for the specified draw, false otherwise.
  function wasClaimed(
    address _vault,
    address _winner,
    uint24 _drawId,
    uint8 _tier,
    uint32 _prizeIndex
  ) external view returns (bool) {
    return _claimedPrizes[_vault][_winner][_drawId][_tier][_prizeIndex];
  }

  /// @notice Returns the balance of rewards earned for the given address.
  /// @param _recipient The recipient to retrieve the reward balance for
  /// @return The balance of rewards for the given recipient
  function rewardBalance(address _recipient) external view returns (uint256) {
    return _rewards[_recipient];
  }

  /// @notice Computes and returns the next number of tiers based on the current prize claim counts. This number may change throughout the draw
  /// @return The next number of tiers
  function estimateNextNumberOfTiers() external view returns (uint8) {
    return computeNextNumberOfTiers(claimCount);
  }

  /* ============ Internal Functions ============ */

  /// @notice Computes how many tokens have been accounted for
  /// @return The balance of tokens that have been accounted for
  function accountedBalance() public view returns (uint256) {
    return _accountedBalance(_totalAccumulator.newestObservation());
  }

  /// @notice Returns the balance available at the time of shutdown, less rewards to be claimed.
  /// @dev This function will compute and store the current balance if it has not yet been set.
  /// @return balance The balance that is available for depositors to withdraw
  /// @return observation The observation used to compute the balance
  function getShutdownInfo() public returns (uint256 balance, Observation memory observation) {
    if (!isShutdown()) {
      return (balance, observation);
    }
    // if not initialized
    if (shutdownObservation.disbursed + shutdownObservation.available == 0) {
      observation = _totalAccumulator.newestObservation();
      shutdownObservation = observation;
      balance = _accountedBalance(observation) - _totalRewardsToBeClaimed;
      shutdownBalance = balance;
    } else {
      observation = shutdownObservation;
      balance = shutdownBalance;
    }
  }

  /// @notice Returns the open draw ID based on the current block timestamp.
  /// @dev Returns `1` if the first draw hasn't opened yet. This prevents any contributions from
  /// going to the inaccessible draw zero.
  /// @dev First draw has an ID of `1`. This means that if `_lastAwardedDrawId` is zero,
  /// we know that no draws have been awarded yet.
  /// @dev Capped at the shutdown draw ID if the prize pool has shutdown.
  /// @return The ID of the draw period that the current block is in
  function getOpenDrawId() public view returns (uint24) {
    uint24 shutdownDrawId = getShutdownDrawId();
    uint24 openDrawId = getDrawId(block.timestamp);
    return openDrawId > shutdownDrawId ? shutdownDrawId : openDrawId;
  }

  /// @notice Returns the open draw id for the given timestamp
  /// @param _timestamp The timestamp to get the draw id for
  /// @return The ID of the open draw that the timestamp is in
  function getDrawId(uint256 _timestamp) public view returns (uint24) {
    uint48 _firstDrawOpensAt = firstDrawOpensAt;
    return
      (_timestamp < _firstDrawOpensAt)
        ? 1
        : (uint24((_timestamp - _firstDrawOpensAt) / drawPeriodSeconds) + 1);
  }

  /// @notice Returns the next draw ID that can be awarded.
  /// @dev It's possible for draws to be missed, so the next draw ID to award
  /// may be more than one draw ahead of the last awarded draw ID.
  /// @return The next draw ID that can be awarded
  function getDrawIdToAward() public view returns (uint24) {
    uint24 openDrawId_ = getOpenDrawId();
    return (openDrawId_ - _lastAwardedDrawId) > 1 ? openDrawId_ - 1 : openDrawId_;
  }

  /// @notice Returns the time at which a draw opens / opened at.
  /// @param drawId The draw to get the timestamp for
  /// @return The start time of the draw in seconds
  function drawOpensAt(uint24 drawId) public view returns (uint48) {
    return firstDrawOpensAt + (drawId - 1) * drawPeriodSeconds;
  }

  /// @notice Returns the time at which a draw closes / closed at.
  /// @param drawId The draw to get the timestamp for
  /// @return The end time of the draw in seconds
  function drawClosesAt(uint24 drawId) public view returns (uint48) {
    return firstDrawOpensAt + drawId * drawPeriodSeconds;
  }

  /// @notice Checks if the given draw is finalized.
  /// @param drawId The draw to check
  /// @return True if the draw is finalized, false otherwise
  function isDrawFinalized(uint24 drawId) public view returns (bool) {
    return block.timestamp >= drawClosesAt(drawId + 1);
  }

  /// @notice Calculates the number of tiers given the number of prize claims
  /// @dev This function will use the claim count to determine the number of tiers, then add one for the canary tier.
  /// @param _claimCount The number of prize claims
  /// @return The estimated number of tiers + the canary tier
  function computeNextNumberOfTiers(uint32 _claimCount) public view returns (uint8) {
    if (_lastAwardedDrawId != 0) {
      // claimCount is expected to be the estimated number of claims for the current prize tier.
      uint8 nextNumberOfTiers = _estimateNumberOfTiersUsingPrizeCountPerDraw(_claimCount);
      // limit change to 1 tier
      uint8 _numTiers = numberOfTiers;
      if (nextNumberOfTiers > _numTiers) {
        nextNumberOfTiers = _numTiers + 1;
      } else if (nextNumberOfTiers < _numTiers) {
        nextNumberOfTiers = _numTiers - 1;
      }
      return nextNumberOfTiers;
    } else {
      return numberOfTiers;
    }
  }

  /// @notice Returns the given account and vault's portion of the shutdown balance.
  /// @param _vault The vault whose contributions are measured
  /// @param _account The account whose vault twab is measured
  /// @return The portion of the shutdown balance that the account is entitled to.
  function computeShutdownPortion(address _vault, address _account) public view returns (ShutdownPortion memory) {
    uint24 drawIdPriorToShutdown = getShutdownDrawId() - 1;
    uint24 startDrawIdInclusive = computeRangeStartDrawIdInclusive(drawIdPriorToShutdown, grandPrizePeriodDraws);

    (uint256 vaultContrib, uint256 totalContrib) = _getVaultShares(
      _vault,
      startDrawIdInclusive,
      drawIdPriorToShutdown
    );

    (uint256 _userTwab, uint256 _vaultTwabTotalSupply) = getVaultUserBalanceAndTotalSupplyTwab(
      _vault,
      _account,
      startDrawIdInclusive,
      drawIdPriorToShutdown
    );

    if (_vaultTwabTotalSupply == 0) {
      return ShutdownPortion(0, 0);
    }

    return ShutdownPortion(vaultContrib * _userTwab, totalContrib * _vaultTwabTotalSupply);
  }

  /// @notice Returns the shutdown balance for a given vault and account. The prize pool must already be shutdown.
  /// @dev The shutdown balance is the amount of prize tokens that a user can claim after the prize pool has been shutdown.
  /// @dev The shutdown balance is calculated using the user's TWAB and the total supply TWAB, whose time ranges are the
  /// grand prize period prior to the shutdown timestamp.
  /// @param _vault The vault to check
  /// @param _account The account to check
  /// @return The shutdown balance for the given vault and account
  function shutdownBalanceOf(address _vault, address _account) public returns (uint256) {
    if (!isShutdown()) {
      return 0;
    }

    Observation memory withdrawalObservation = _withdrawalObservations[_vault][_account];
    ShutdownPortion memory shutdownPortion;
    uint256 balance;

    // if we haven't withdrawn yet, add the portion of the shutdown balance
    if ((withdrawalObservation.available + withdrawalObservation.disbursed) == 0) {
      (balance, withdrawalObservation) = getShutdownInfo();
      shutdownPortion = computeShutdownPortion(_vault, _account);
      _shutdownPortions[_vault][_account] = shutdownPortion;
    } else {
      shutdownPortion = _shutdownPortions[_vault][_account];
    }

    if (shutdownPortion.denominator == 0) {
      return 0;
    }

    // if there are new rewards
    // current "draw id to award" observation - last withdraw observation
    Observation memory newestObs = _totalAccumulator.newestObservation();
    balance += (newestObs.available + newestObs.disbursed) - (withdrawalObservation.available + withdrawalObservation.disbursed);

    return (shutdownPortion.numerator * balance) / shutdownPortion.denominator;
  }

  /// @notice Withdraws the shutdown balance for a given vault and sender
  /// @param _vault The eligible vault to withdraw the shutdown balance from
  /// @param _recipient The address to send the shutdown balance to
  /// @return The amount of prize tokens withdrawn
  function withdrawShutdownBalance(address _vault, address _recipient) external returns (uint256) {
    if (!isShutdown()) {
      revert PrizePoolNotShutdown();
    }
    uint256 balance = shutdownBalanceOf(_vault, msg.sender);
    _withdrawalObservations[_vault][msg.sender] = _totalAccumulator.newestObservation();
    if (balance > 0) {
      prizeToken.safeTransfer(_recipient, balance);
      _totalWithdrawn += uint128(balance);
    }
    return balance;
  }

  /// @notice Returns the open draw ID at the time of shutdown.
  /// @return The draw id
  function getShutdownDrawId() public view returns (uint24) {
    return getDrawId(shutdownAt());
  }

  /// @notice Returns the timestamp at which the prize pool will be considered inactive and shutdown
  /// @return The timestamp at which the prize pool will be considered inactive
  function shutdownAt() public view returns (uint256) {
    uint256 twabShutdownAt = twabController.lastObservationAt();
    uint256 drawTimeoutAt_ = drawTimeoutAt();
    return drawTimeoutAt_ < twabShutdownAt ? drawTimeoutAt_ : twabShutdownAt;
  }

  /// @notice Returns whether the prize pool has been shutdown
  /// @return True if shutdown, false otherwise
  function isShutdown() public view returns (bool) {
    return block.timestamp >= shutdownAt();
  }

  /// @notice Returns the timestamp at which the prize pool will be considered inactive
  /// @return The timestamp at which the prize pool has timed out and becomes inactive
  function drawTimeoutAt() public view returns (uint256) { 
    return drawClosesAt(_lastAwardedDrawId + drawTimeout);
  }

  /// @notice Returns the total prize tokens contributed between the given draw ids, inclusive.
  /// @param _startDrawIdInclusive Start draw id inclusive
  /// @param _endDrawIdInclusive End draw id inclusive
  /// @return The total prize tokens contributed by all vaults
  function getTotalContributedBetween(
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) public view returns (uint256) {
    return
      _totalAccumulator.getDisbursedBetween(
        _startDrawIdInclusive,
        _endDrawIdInclusive
      );
  }

  /// @notice Checks if the given user has won the prize for the specified tier in the given vault.
  /// @param _vault The address of the vault to check
  /// @param _user The address of the user to check for the prize
  /// @param _tier The tier for which the prize is to be checked
  /// @param _prizeIndex The prize index to check. Must be less than prize count for the tier
  /// @return A boolean value indicating whether the user has won the prize or not
  function isWinner(
    address _vault,
    address _user,
    uint8 _tier,
    uint32 _prizeIndex
  ) public view returns (bool) {
    uint24 lastAwardedDrawId_ = _lastAwardedDrawId;

    if (lastAwardedDrawId_ == 0) {
      revert NoDrawsAwarded();
    }
    if (_tier >= numberOfTiers) {
      revert InvalidTier(_tier, numberOfTiers);
    }

    SD59x18 tierOdds = getTierOdds(_tier, numberOfTiers);
    uint24 startDrawIdInclusive = computeRangeStartDrawIdInclusive(lastAwardedDrawId_, uint24(TierCalculationLib.estimatePrizeFrequencyInDraws(tierOdds)));

    uint32 tierPrizeCount = uint32(TierCalculationLib.prizeCount(_tier));

    if (_prizeIndex >= tierPrizeCount) {
      revert InvalidPrizeIndex(_prizeIndex, tierPrizeCount, _tier);
    }

    uint256 userSpecificRandomNumber = TierCalculationLib.calculatePseudoRandomNumber(
      lastAwardedDrawId_,
      _vault,
      _user,
      _tier,
      _prizeIndex,
      _winningRandomNumber
    );
    
    SD59x18 vaultPortion = getVaultPortion(
      _vault,
      startDrawIdInclusive,
      lastAwardedDrawId_
    );

    (uint256 _userTwab, uint256 _vaultTwabTotalSupply) = getVaultUserBalanceAndTotalSupplyTwab(
      _vault,
      _user,
      startDrawIdInclusive,
      lastAwardedDrawId_
    );

    return
      TierCalculationLib.isWinner(
        userSpecificRandomNumber,
        _userTwab,
        _vaultTwabTotalSupply,
        vaultPortion,
        tierOdds
      );
  }

  /// @notice Compute the start draw id for a range given the end draw id and range size
  /// @param _endDrawIdInclusive The end draw id (inclusive) of the range
  /// @param _rangeSize The size of the range
  /// @return The start draw id (inclusive) of the range
  function computeRangeStartDrawIdInclusive(uint24 _endDrawIdInclusive, uint24 _rangeSize) public pure returns (uint24) {
    if (_rangeSize != 0) {
      return _rangeSize > _endDrawIdInclusive ? 1 : _endDrawIdInclusive - _rangeSize + 1;
    } else {
      revert RangeSizeZero();
    }
  }

  /// @notice Returns the time-weighted average balance (TWAB) and the TWAB total supply for the specified user in
  /// the given vault over a specified period.
  /// @dev This function calculates the TWAB for a user by calling the getTwabBetween function of the TWAB controller
  /// for a specified period of time.
  /// @param _vault The address of the vault for which to get the TWAB.
  /// @param _user The address of the user for which to get the TWAB.
  /// @param _startDrawIdInclusive The starting draw for the range (inclusive)
  /// @param _endDrawIdInclusive The end draw for the range (inclusive)
  /// @return twab The TWAB for the specified user in the given vault over the specified period.
  /// @return twabTotalSupply The TWAB total supply over the specified period.
  function getVaultUserBalanceAndTotalSupplyTwab(
    address _vault,
    address _user,
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) public view returns (uint256 twab, uint256 twabTotalSupply) {
    uint48 _startTimestamp = drawOpensAt(_startDrawIdInclusive);
    uint48 _endTimestamp = drawClosesAt(_endDrawIdInclusive);
    twab = twabController.getTwabBetween(_vault, _user, _startTimestamp, _endTimestamp);
    twabTotalSupply = twabController.getTotalSupplyTwabBetween(
      _vault,
      _startTimestamp,
      _endTimestamp
    );
  }

  /// @notice Calculates the portion of the vault's contribution to the prize pool over a specified duration in draws.
  /// @param _vault The address of the vault for which to calculate the portion.
  /// @param _startDrawIdInclusive The starting draw ID (inclusive) of the draw range to calculate the contribution portion for.
  /// @param _endDrawIdInclusive The ending draw ID (inclusive) of the draw range to calculate the contribution portion for.
  /// @return The portion of the vault's contribution to the prize pool over the specified duration in draws.
  function getVaultPortion(
    address _vault,
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) public view returns (SD59x18) {
    if (_vault == DONATOR) {
      return sd(0);
    }

    (uint256 vaultContributed, uint256 totalContributed) = _getVaultShares(_vault, _startDrawIdInclusive, _endDrawIdInclusive);

    if (totalContributed == 0) {
      return sd(0);
    }

    return sd(
      SafeCast.toInt256(
        vaultContributed
      )
    ).div(sd(SafeCast.toInt256(totalContributed)));
  }

  function _getVaultShares(
    address _vault,
    uint24 _startDrawIdInclusive,
    uint24 _endDrawIdInclusive
  ) internal view returns (uint256 shares, uint256 totalSupply) {
    uint256 totalContributed = _totalAccumulator.getDisbursedBetween(
      _startDrawIdInclusive,
      _endDrawIdInclusive
    );

    uint256 totalDonated = _vaultAccumulator[DONATOR].getDisbursedBetween(_startDrawIdInclusive, _endDrawIdInclusive);

    totalSupply = totalContributed - totalDonated;

    shares = _vaultAccumulator[_vault].getDisbursedBetween(
      _startDrawIdInclusive,
      _endDrawIdInclusive
    );
  }

  function _accountedBalance(Observation memory _observation) internal view returns (uint256) {
    // obs.disbursed includes the reserve, prizes, and prize liquidity
    // obs.disbursed is the total amount of tokens all-time contributed by vaults and released. These tokens may:
    //    - still be held for future prizes
    //    - have been given as prizes
    //    - have been captured as fees

    // obs.available is the total number of tokens that WILL be disbursed in the future.
    // _directlyContributedReserve are tokens that have been contributed directly to the reserve
    // totalWithdrawn represents all tokens that have been withdrawn as prizes or rewards

    return (_observation.available + _observation.disbursed) + uint256(_directlyContributedReserve) - uint256(_totalWithdrawn);
  }

  /// @notice Modifier that requires the prize pool not to be shutdown
  modifier notShutdown() {
    if (isShutdown()) {
      revert PrizePoolShutdown();
    }
    _;
  }
}
