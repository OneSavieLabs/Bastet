// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControl } from "./utils/AccessControl.sol";
import { ETHOS_PROFILE } from "./utils/Constants.sol";
import { IEthosProfile } from "./interfaces/IEthosProfile.sol";
import { InsufficientInitialLiquidity, InactiveMarket, InsufficientFunds, FeeTransferFailed, InsufficientVotesOwned, InsufficientVotesToSell, InvalidProfileId, MarketAlreadyExists, MarketCreationErrorCode, MarketCreationUnauthorized, MarketDoesNotExist, SlippageLimitExceeded, InvalidMarketConfigOption, UnauthorizedGraduation, UnauthorizedWithdrawal, MarketNotGraduated, ZeroAddressNotAllowed } from "./errors/ReputationMarketErrors.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ReputationMarket
 * @dev This contract establishes Reputation Markets, allowing buying and selling of "trust" and "distrust" votes for specific
 * Ethos profiles, reflecting the perceived reputation of the profile's owner. The vote prices fluctuate dynamically based on
 * demand, where an increase in trust votes implies higher reputation, and an increase in distrust votes implies lower reputation.
 * This setup allows participants to potentially profit by speculating on a profile's future reputation.
 *
 * The vote pricing model functions like a prediction market with perpetual duration, inversely adjusting trust and distrust
 * prices. As the trust price rises, the distrust price decreases by an equal amount, with both prices summing to a set maximum.
 * This mechanism reflects the balance of sentiment, allowing users to gauge a profile's perceived trustworthiness as a percentage.
 * Unlike traditional prediction markets, this model has no end date or decision criteria, operating continuously until market graduation.
 *
 * Graduation: the intent is that upon graduation, each holder of trust and distrust votes receives equivalent ERC-20 tokens
 * representing their position. These tokens will be freely tradable, without the reciprocal pricing mechanism of this contract.
 * A price floor will be established by Ethos, offering to buy back the new ERC-20 tokens at their final vote price upon graduation,
 * ensuring participants don't incur losses due to the transition. Only Ethos, through a designated contract, will be authorized to
 * graduate markets and withdraw funds to initiate this conversion process. This conversion contract is not yet implemented.
 *
 * Market configurations offer different initial setups to control the volatility and stability of reputation markets.
 * With the default configuration, a low number of initial votes can cause significant price fluctuations, leading to a highly
 * volatile market. To provide flexibility, we offer additional configurations (e.g., deluxe, premium) with varying initial
 * vote counts and liquidity. These configurations allow market creators to choose the market's volatility level: lower initial
 * votes result in faster price changes, while higher initial votes enable smoother, gradual price adjustments. Ethos admins can
 * add or remove configurations without modifying the core contract, enabling ongoing experimentation with different market structures.
 */
contract ReputationMarket is AccessControl, UUPSUpgradeable, ReentrancyGuard {
  /**
   * @dev Constructor that disables initializers when the implementation contract is deployed.
   * This prevents the implementation contract from being initialized, which is important for
   * security since the implementation contract should never be used directly, only through
   * delegatecall from the proxy.
   */
  constructor() {
    _disableInitializers();
  }

  using Math for uint256;
  // --- Structs ---
  struct Market {
    uint256[2] votes;
    uint256 basePrice;
  }
  struct MarketInfo {
    uint256 profileId;
    uint256 trustVotes;
    uint256 distrustVotes;
  }

  /**
   * @notice Configuration parameters for initializing new reputation markets
   * @dev Used to define different tiers of market initialization options
   * @param initialLiquidity The amount of ETH required to create a market with this config
   * @param initialVotes The starting number of votes for both trust and distrust positions
   */
  struct MarketConfig {
    uint256 initialLiquidity;
    uint256 initialVotes;
    uint256 basePrice;
  }

  struct MarketUpdateInfo {
    uint256 voteTrust;
    uint256 voteDistrust;
    uint256 positivePrice;
    uint256 negativePrice;
    uint256 lastUpdateBlock;
  }
  // --- Constants ---
  uint256 public constant DEFAULT_PRICE = 0.01 ether;
  uint256 public constant MINIMUM_BASE_PRICE = 0.0001 ether;
  uint256 private constant TRUST = 1;
  uint256 private constant DISTRUST = 0;
  /**
   * @dev The multiplier for converting slippage basis points to a percentage.
   * 1 basis point = 0.01%.
   */
  uint256 private constant SLIPPAGE_POINTS_BASE = 10000;
  uint256 private constant BASIS_POINTS_BASE = 10000;
  uint256 private constant MAX_PROTOCOL_FEE_BASIS_POINTS = 500; // 5%
  uint256 private constant MAX_DONATION_BASIS_POINTS = 500; // 5%

  // --- State Variables ---
  /**
   * @dev Entry and exit fees (in basis points) allow flexible revenue generation for the protocol.
   * Both fees are adjustable up to a capped maximum to ensure stable, predictable market costs for users.
   */
  uint256 public entryProtocolFeeBasisPoints;
  uint256 public exitProtocolFeeBasisPoints;
  address public protocolFeeAddress;
  /**
   * @dev Donations, also referred to as rewards, create incentives for profile owners who open reputation markets for themselves.
   * These rewards compensate owners for the reputational risk and effort involved in promoting adoption of the market.
   */
  uint256 public donationBasisPoints;

  // authorized market creation options; index 0 is the default config
  MarketConfig[] public marketConfigs;

  // profileId => isPositive => votes
  mapping(uint256 => Market) private markets;
  // profileId => funds currently invested in each market
  mapping(uint256 => uint256) public marketFunds;
  // profileId => graduated (markets that have graduated)
  mapping(uint256 => bool) public graduatedMarkets;
  // profileId => MarketUpdateInfo
  mapping(uint256 => MarketUpdateInfo) public lastMarketUpdates;
  // msg.sender => profileId => isPositive => votes
  mapping(address => mapping(uint256 => Market)) private votesOwned;
  // profileId => participant address
  // append only; don't bother removing. Use isParticipant to check if they've sold all their votes.
  mapping(uint256 => address[]) public participants;
  // profileId => participant => isParticipant
  mapping(uint256 => mapping(address => bool)) public isParticipant;
  // recipient address => donation amount
  mapping(address => uint256) public donationEscrow;
  // profileId => recipient address
  mapping(uint256 => address) public donationRecipient;

  // Mapping to store the allow list of profileIds that can create their market.
  // profileId => isAllowed bool;
  mapping(uint256 => bool) private creationAllowedProfileIds;

  // This is used to control whether anyone can create a market or only the contract admin or addresses in the allow list.
  bool private enforceCreationAllowList;

  event MarketCreated(uint256 indexed profileId, address indexed creator, MarketConfig config);
  event MarketConfigAdded(uint256 indexed configIndex, MarketConfig config);
  event MarketConfigRemoved(uint256 indexed configIndex, MarketConfig config);
  event VotesBought(
    uint256 indexed profileId,
    address indexed buyer,
    bool indexed isPositive,
    uint256 amount,
    uint256 funds,
    uint256 boughtAt,
    uint256 minVotePrice,
    uint256 maxVotePrice
  );
  event VotesSold(
    uint256 indexed profileId,
    address indexed seller,
    bool indexed isPositive,
    uint256 amount,
    uint256 funds,
    uint256 soldAt,
    uint256 minVotePrice,
    uint256 maxVotePrice
  );
  event MarketUpdated(
    uint256 indexed profileId,
    uint256 indexed voteTrust,
    uint256 indexed voteDistrust,
    uint256 trustPrice,
    uint256 distrustPrice,
    int256 deltaVoteTrust,
    int256 deltaVoteDistrust,
    int256 deltaTrustPrice,
    int256 deltaDistrustPrice,
    uint256 blockNumber,
    uint256 updatedAt
  );
  event DonationWithdrawn(address indexed recipient, uint256 amount);
  event DonationRecipientUpdated(
    uint256 indexed profileId,
    address indexed oldRecipient,
    address indexed newRecipient
  );
  event MarketGraduated(uint256 indexed profileId);
  event MarketFundsWithdrawn(uint256 indexed profileId, address indexed withdrawer, uint256 amount);

  /**
   * @notice Ensures the market is not graduated (still active for trading)
   * @dev Modifier used to restrict trading functions to only active markets
   * @param profileId The ID of the market to check
   */
  modifier activeMarket(uint256 profileId) {
    if (graduatedMarkets[profileId]) {
      revert InactiveMarket(profileId);
    }
    _;
  }

  /**
   * @dev initializer in place of constructor.
   * @param owner Owner address.
   * @param admin Admin address.
   * @param expectedSigner ExpectedSigner address.
   * @param signatureVerifier SignatureVerifier address.
   * @param contractAddressManagerAddr ContractAddressManagerAddr address.
   */
  function initialize(
    address owner,
    address admin,
    address expectedSigner,
    address signatureVerifier,
    address contractAddressManagerAddr
  ) external initializer {
    __accessControl_init(
      owner,
      admin,
      expectedSigner,
      signatureVerifier,
      contractAddressManagerAddr
    );
    __UUPSUpgradeable_init();
    enforceCreationAllowList = true;
    // Default market configurations:

    // Default tier
    // - Minimum viable liquidity for small/new markets
    // - 0.002 ETH initial liquidity
    // - 1 vote each for trust/distrust (volatile price at low volume)
    marketConfigs.push(
      MarketConfig({
        initialLiquidity: 2 * DEFAULT_PRICE,
        initialVotes: 1,
        basePrice: DEFAULT_PRICE
      })
    );

    // Deluxe tier
    // - Moderate liquidity for established profiles
    // - 0.05 ETH initial liquidity
    // - 1,000 votes each for trust/distrust (moderate price stability)
    marketConfigs.push(
      MarketConfig({
        initialLiquidity: 50 * DEFAULT_PRICE,
        initialVotes: 1000,
        basePrice: DEFAULT_PRICE
      })
    );

    // Premium tier
    // - High liquidity for stable price discovery
    // - 0.1 ETH initial liquidity
    // - 10,000 votes each for trust/distrust (highly stable price)
    marketConfigs.push(
      MarketConfig({
        initialLiquidity: 100 * DEFAULT_PRICE,
        initialVotes: 10000,
        basePrice: DEFAULT_PRICE
      })
    );
  }

  /**
   * @notice restricts upgrading to owner
   * @param newImplementation address of new implementation contract
   */
  function _authorizeUpgrade(
    address newImplementation
  ) internal override onlyOwner onlyNonZeroAddress(newImplementation) {
    // Intentionally left blank to ensure onlyOwner and zeroCheck modifiers run
  }

  // --- Market Creation ---

  /**
   * @notice Creates a new reputation market for a profile using the default market configuration
   * @dev This is a convenience function that calls createMarketWithConfig with index 0
   */
  function createMarket() public payable whenNotPaused {
    createMarketWithConfig(0);
  }

  /**
   * @notice Creates a new reputation market for a profile using a specific market configuration
   * @dev Only callable by users for their own profiles when allowed; see createMarketWithConfigAdmin for creating markets on behalf of others
   * @param marketConfigIndex The index of the market configuration to use
   */
  function createMarketWithConfig(uint256 marketConfigIndex) public payable whenNotPaused {
    uint256 senderProfileId = _getProfileIdForAddress(msg.sender);

    // Verify sender can create market
    if (enforceCreationAllowList && !creationAllowedProfileIds[senderProfileId]) {
      revert MarketCreationUnauthorized(
        MarketCreationErrorCode.PROFILE_NOT_AUTHORIZED,
        msg.sender,
        senderProfileId
      );
    }
    _createMarket(senderProfileId, msg.sender, marketConfigIndex);
  }

  /**
   * @notice Creates a new reputation market for a profile using a specific market configuration
   * @dev Only callable by admins, can create markets for any address/profile
   * @param marketOwner Create this market on behalf of this owner; will look up their profile and send donations
   * @param marketConfigIndex The index of the market configuration to use
   */
  function createMarketWithConfigAdmin(
    address marketOwner,
    uint256 marketConfigIndex
  ) public payable whenNotPaused onlyAdmin {
    uint256 profileId = _getProfileIdForAddress(marketOwner);
    _createMarket(profileId, marketOwner, marketConfigIndex);
  }

  /**
   * @dev Internal function to handle market creation logic
   * @param profileId The ID of the profile to create a market for
   * @param recipient The address of the market owner (will receive donations)
   * @param marketConfigIndex The index of the market configuration to use
   */
  function _createMarket(
    uint256 profileId,
    address recipient,
    uint256 marketConfigIndex
  ) private nonReentrant {
    // ensure a market doesn't already exist for this profile
    if (markets[profileId].votes[TRUST] != 0 || markets[profileId].votes[DISTRUST] != 0) {
      revert MarketAlreadyExists(profileId);
    }

    // ensure the specified config option is valid
    if (marketConfigIndex >= marketConfigs.length) {
      revert InvalidMarketConfigOption("Invalid config index");
    }

    // ensure the user has provided enough initial liquidity
    uint256 initialLiquidityRequired = marketConfigs[marketConfigIndex].initialLiquidity;
    if (msg.value < initialLiquidityRequired) {
      revert InsufficientInitialLiquidity();
    }

    // Create the new market using the specified config
    markets[profileId].votes[TRUST] = marketConfigs[marketConfigIndex].initialVotes;
    markets[profileId].votes[DISTRUST] = marketConfigs[marketConfigIndex].initialVotes;
    markets[profileId].basePrice = marketConfigs[marketConfigIndex].basePrice;

    donationRecipient[profileId] = recipient;

    // Tally market funds
    marketFunds[profileId] = initialLiquidityRequired;

    // Refund any remaining funds
    _sendEth(msg.value - initialLiquidityRequired);
    emit MarketCreated(profileId, msg.sender, marketConfigs[marketConfigIndex]);
    _emitMarketUpdate(profileId);
  }

  // --- Market Configuration ---

  /**
   * @dev Adds a new market configuration option to support different volatility preferences
   * @param initialLiquidity Required initial ETH (must exceed DEFAULT_PRICE)
   * @param initialVotes Initial vote count (higher = more stable pricing)
   * @return The index of the new market config
   */
  function addMarketConfig(
    uint256 initialLiquidity,
    uint256 initialVotes,
    uint256 basePrice
  ) public onlyAdmin whenNotPaused returns (uint256) {
    // minimum liquidity is at least 100% of the default price maximum; didn't need it's own constant
    if (initialLiquidity < DEFAULT_PRICE) revert InvalidMarketConfigOption("Min liquidity not met");

    if (initialVotes == 0) revert InvalidMarketConfigOption("Votes cannot be zero");

    if (basePrice < MINIMUM_BASE_PRICE) revert InvalidMarketConfigOption("Insufficient base price");

    marketConfigs.push(
      MarketConfig({
        initialLiquidity: initialLiquidity,
        initialVotes: initialVotes,
        basePrice: basePrice
      })
    );

    uint256 configIndex = marketConfigs.length - 1;
    emit MarketConfigAdded(configIndex, marketConfigs[configIndex]);
    return configIndex;
  }

  /**
   * @dev Removes a market configuration option while maintaining at least one config
   * @param configIndex The index of the config to remove
   */
  function removeMarketConfig(uint256 configIndex) public onlyAdmin whenNotPaused {
    // Cannot remove if only one config remains
    if (marketConfigs.length <= 1) {
      revert InvalidMarketConfigOption("Must keep one config");
    }

    // Check if the index is valid
    if (configIndex >= marketConfigs.length) {
      revert InvalidMarketConfigOption("index not found");
    }

    emit MarketConfigRemoved(configIndex, marketConfigs[configIndex]);

    // If this is not the last element, swap with the last element
    uint256 lastIndex = marketConfigs.length - 1;
    if (configIndex != lastIndex) {
      marketConfigs[configIndex] = marketConfigs[lastIndex];
    }

    // Remove the last element
    marketConfigs.pop();
  }

  /**
   * @dev Disables the allow list enforcement
   * Anyone may create a market for their own profile.
   * @param value true if profile can create their market, false otherwise.
   */
  function setAllowListEnforcement(bool value) public onlyAdmin whenNotPaused {
    enforceCreationAllowList = value;
  }

  /**
   * @dev Sets the user's ability to create a market.
   * @param profileId The profileId of the user to allow/disallow market creation.
   * @param value is profileId allowed to create a market
   */
  function setUserAllowedToCreateMarket(
    uint256 profileId,
    bool value
  ) public onlyAdmin whenNotPaused {
    creationAllowedProfileIds[profileId] = value;
  }

  // --- Core Trading Functions ---

  /**
   * @dev Buys votes for a given market.
   * @param profileId The profileId of the market to buy votes for.
   * @param isPositive Whether the votes are trust or distrust.
   * @param expectedVotes The expected number of votes to buy. This is used as the basis for the slippage check.
   * @param slippageBasisPoints The slippage tolerance in basis points (1 basis point = 0.01%).
   */
  function buyVotes(
    uint256 profileId,
    bool isPositive,
    uint256 expectedVotes,
    uint256 slippageBasisPoints
  ) public payable whenNotPaused activeMarket(profileId) nonReentrant {
    _checkMarketExists(profileId);

    // Determine how many votes can be bought with the funds provided
    (
      uint256 votesBought,
      uint256 fundsPaid,
      ,
      uint256 protocolFee,
      uint256 donation,
      uint256 minVotePrice,
      uint256 maxVotePrice
    ) = _calculateBuy(markets[profileId], isPositive, msg.value);

    _checkSlippageLimit(votesBought, expectedVotes, slippageBasisPoints);

    // Apply fees first
    applyFees(protocolFee, donation, profileId);

    // Update market state
    markets[profileId].votes[isPositive ? TRUST : DISTRUST] += votesBought;
    votesOwned[msg.sender][profileId].votes[isPositive ? TRUST : DISTRUST] += votesBought;

    // Add buyer to participants if not already a participant
    if (!isParticipant[profileId][msg.sender]) {
      participants[profileId].push(msg.sender);
      isParticipant[profileId][msg.sender] = true;
    }

    // Calculate and refund remaining funds
    uint256 refund = msg.value - fundsPaid;
    if (refund > 0) _sendEth(refund);

    // tally market funds
    marketFunds[profileId] += fundsPaid;
    emit VotesBought(
      profileId,
      msg.sender,
      isPositive,
      votesBought,
      fundsPaid,
      block.timestamp,
      minVotePrice,
      maxVotePrice
    );
    _emitMarketUpdate(profileId);
  }

  function sellVotes(
    uint256 profileId,
    bool isPositive,
    uint256 amount
  ) public whenNotPaused activeMarket(profileId) nonReentrant {
    _checkMarketExists(profileId);

    // calculate the amount of votes to sell and the funds received
    (
      uint256 votesSold,
      uint256 fundsReceived,
      ,
      uint256 protocolFee,
      uint256 minVotePrice,
      uint256 maxVotePrice
    ) = _calculateSell(markets[profileId], profileId, isPositive, amount);

    // update the market state
    markets[profileId].votes[isPositive ? TRUST : DISTRUST] -= votesSold;
    votesOwned[msg.sender][profileId].votes[isPositive ? TRUST : DISTRUST] -= votesSold;

    // apply protocol fees
    applyFees(protocolFee, 0, profileId);

    // send the proceeds to the seller
    _sendEth(fundsReceived);
    // tally market funds
    marketFunds[profileId] -= fundsReceived;
    emit VotesSold(
      profileId,
      msg.sender,
      isPositive,
      votesSold,
      fundsReceived,
      block.timestamp,
      minVotePrice,
      maxVotePrice
    );
    _emitMarketUpdate(profileId);
  }

  // ---Rewards & Donations---
  /**
   * @dev Updates the donation recipient for a market
   * @notice Only the current donation recipient can update the recipient
   * @notice The new recipient must have the same Ethos profileId as the market
   * @param profileId The profile ID of the market to update
   * @param newRecipient The new address to receive donations
   */
  function updateDonationRecipient(uint256 profileId, address newRecipient) public whenNotPaused {
    if (newRecipient == address(0)) revert ZeroAddress();

    // if the new donation recipient has a balance, do not allow overwriting
    // this is so rare, do we really need a custom error?
    require(donationEscrow[newRecipient] == 0, "Donation recipient has balance");

    // Ensure the sender is the current donation recipient
    if (msg.sender != donationRecipient[profileId]) revert InvalidProfileId();

    // Ensure the new recipient has the same Ethos profileId
    uint256 recipientProfileId = _ethosProfileContract().verifiedProfileIdForAddress(newRecipient);
    if (recipientProfileId != profileId) revert InvalidProfileId();

    // Update the donation recipient reference
    donationRecipient[profileId] = newRecipient;
    // Swap the current donation balance to the new recipient
    donationEscrow[newRecipient] += donationEscrow[msg.sender];
    donationEscrow[msg.sender] = 0;
    emit DonationRecipientUpdated(profileId, msg.sender, newRecipient);
  }

  /**
   * @dev Allows a user to withdraw their accumulated donations from escrow
   * @return amount The amount withdrawn
   */
  function withdrawDonations() public whenNotPaused returns (uint256) {
    uint256 amount = donationEscrow[msg.sender];
    if (amount == 0) {
      revert InsufficientFunds();
    }

    // Reset escrow balance before transfer to prevent reentrancy
    donationEscrow[msg.sender] = 0;

    // Transfer the funds
    (bool success, ) = msg.sender.call{ value: amount }("");
    if (!success) revert FeeTransferFailed("Donation withdrawal failed");

    emit DonationWithdrawn(msg.sender, amount);
    return amount;
  }

  // --- Fee Management ---

  /**
   * @notice Sets the donation percentage in basis points
   * @param basisPoints The new donation percentage in basis points, maximum 500 (5%)
   */
  function setDonationBasisPoints(uint256 basisPoints) public onlyAdmin whenNotPaused {
    if (basisPoints > MAX_DONATION_BASIS_POINTS) {
      revert InvalidMarketConfigOption("Donation exceeds maximum");
    }
    donationBasisPoints = basisPoints;
  }

  /**
   * @dev Sets the protocol fee in basis points (1 basis point = 0.01%)
   * @param basisPoints The new fee in basis points, maximum 500 (5%)
   */
  function setEntryProtocolFeeBasisPoints(uint256 basisPoints) public onlyAdmin whenNotPaused {
    // must specify a protocol fee address before enabling entry fees
    if (protocolFeeAddress == address(0)) revert ZeroAddress();
    if (basisPoints > MAX_PROTOCOL_FEE_BASIS_POINTS) {
      revert InvalidMarketConfigOption("Fee exceeds maximum");
    }
    entryProtocolFeeBasisPoints = basisPoints;
  }

  /**
   * @notice Sets the exit protocol fee in basis points
   * @param basisPoints The new fee in basis points, maximum 500 (5%)
   */
  function setExitProtocolFeeBasisPoints(uint256 basisPoints) public onlyAdmin whenNotPaused {
    // must specify a protocol fee address before enabling exit fees
    if (protocolFeeAddress == address(0)) revert ZeroAddress();
    if (basisPoints > MAX_PROTOCOL_FEE_BASIS_POINTS) {
      revert InvalidMarketConfigOption("Fee exceeds maximum");
    }
    exitProtocolFeeBasisPoints = basisPoints;
  }

  /**
   * @notice Sets the address that receives protocol fees
   * @param newProtocolFeeAddress The address to receive protocol fees
   */
  function setProtocolFeeAddress(address newProtocolFeeAddress) public onlyAdmin whenNotPaused {
    if (newProtocolFeeAddress == address(0)) {
      revert ZeroAddress();
    }
    protocolFeeAddress = newProtocolFeeAddress;
  }

  // --- Market Graduation & Withdrawal ---

  /**
   * @notice Graduates a market, marking it as inactive for trading
   * @param profileId The ID of the market to graduate
   */
  function graduateMarket(uint256 profileId) public whenNotPaused activeMarket(profileId) {
    address authorizedAddress = contractAddressManager.getContractAddressForName(
      "GRADUATION_WITHDRAWAL"
    );
    if (msg.sender != authorizedAddress) {
      revert UnauthorizedGraduation();
    }
    _checkMarketExists(profileId);
    graduatedMarkets[profileId] = true;
    emit MarketGraduated(profileId);
  }

  /**
   * @notice Withdraws funds from a graduated market
   * @dev Only callable by the authorized graduation withdrawal address
   * @param profileId The ID of the graduated market to withdraw from
   */
  function withdrawGraduatedMarketFunds(uint256 profileId) public whenNotPaused {
    address authorizedAddress = contractAddressManager.getContractAddressForName(
      "GRADUATION_WITHDRAWAL"
    );
    if (msg.sender != authorizedAddress) {
      revert UnauthorizedWithdrawal();
    }
    _checkMarketExists(profileId);
    if (!graduatedMarkets[profileId]) {
      revert MarketNotGraduated();
    }
    if (marketFunds[profileId] == 0) {
      revert InsufficientFunds();
    }

    _sendEth(marketFunds[profileId]);
    emit MarketFundsWithdrawn(profileId, msg.sender, marketFunds[profileId]);
    marketFunds[profileId] = 0;
  }

  // --- View Functions ---

  /**
   * @notice Gets the current state of a market
   * @param profileId The profile ID of the market to query
   * @return MarketInfo struct containing market state
   */
  function getMarket(uint256 profileId) public view returns (MarketInfo memory) {
    return
      MarketInfo({
        profileId: profileId,
        trustVotes: markets[profileId].votes[TRUST],
        distrustVotes: markets[profileId].votes[DISTRUST]
      });
  }

  function getMarketConfigCount() public view returns (uint256) {
    return marketConfigs.length;
  }

  /**
   * @notice Gets the number of participants in a market
   * @param profileId The profile ID of the market
   * @return The number of participants
   */
  function getParticipantCount(uint256 profileId) public view returns (uint256) {
    _checkMarketExists(profileId);
    return participants[profileId].length;
  }

  /**
   * @notice Gets a user's vote holdings in a market
   * @param user The address of the user
   * @param profileId The profile ID of the market
   * @return MarketInfo struct containing user's vote counts
   */
  function getUserVotes(address user, uint256 profileId) public view returns (MarketInfo memory) {
    return
      MarketInfo({
        profileId: profileId,
        trustVotes: votesOwned[user][profileId].votes[TRUST],
        distrustVotes: votesOwned[user][profileId].votes[DISTRUST]
      });
  }

  /**
   * @notice Gets the current price of votes for a market position
   * @param profileId The profile ID of the market
   * @param isPositive Whether to get trust (true) or distrust (false) vote price
   * @return The current price per vote in wei
   */
  function getVotePrice(uint256 profileId, bool isPositive) public view returns (uint256) {
    _checkMarketExists(profileId);
    return _calcVotePrice(markets[profileId], isPositive);
  }

  /**
   * @dev Checks if the user is allowed to create a market.
   * @param profileId The profileId of the user to check.
   * @return True if the profile is allowed to create a market, false otherwise.
   */
  function isAllowedToCreateMarket(uint256 profileId) public view returns (bool) {
    return creationAllowedProfileIds[profileId];
  }

  /**
   * @notice Simulates buying votes to preview the transaction outcome
   * @dev Used to calculate expected slippage before executing a buy transaction.
   *      The simulation shows price impact and helps users determine appropriate
   *      slippage tolerance.
   * @param profileId The ID of the market to simulate buying from
   * @param isPositive Whether to buy trust (true) or distrust (false) votes
   * @param funds The amount of funds to simulate spending
   * @return votesBought The number of votes that would be received
   * @return fundsPaid The total amount that would be paid including fees
   * @return newVotePrice The new price per vote after the simulated purchase
   * @return protocolFee The protocol fee that would be charged
   * @return donation The donation amount that would be given to market owner
   * @return minVotePrice The minimum vote price during the transaction
   * @return maxVotePrice The maximum vote price during the transaction
   */
  function simulateBuy(
    uint256 profileId,
    bool isPositive,
    uint256 funds
  )
    public
    view
    activeMarket(profileId)
    returns (
      uint256 votesBought,
      uint256 fundsPaid,
      uint256 newVotePrice,
      uint256 protocolFee,
      uint256 donation,
      uint256 minVotePrice,
      uint256 maxVotePrice
    )
  {
    _checkMarketExists(profileId);
    (
      votesBought,
      fundsPaid,
      newVotePrice,
      protocolFee,
      donation,
      minVotePrice,
      maxVotePrice
    ) = _calculateBuy(markets[profileId], isPositive, funds);
  }

  /**
   * @notice Simulates selling votes to preview the transaction outcome
   * @dev Used to calculate expected slippage before executing a sell transaction.
   *      The simulation shows price impact and helps users determine appropriate
   *      slippage tolerance.
   * @param profileId The ID of the market to simulate selling from
   * @param isPositive Whether to sell trust (true) or distrust (false) votes
   * @param amount The number of votes to simulate selling
   * @return votesSold The number of votes that would be sold
   * @return fundsReceived The total amount that would be received after fees
   * @return newVotePrice The new price per vote after the simulated sale
   * @return protocolFee The protocol fee that would be charged
   * @return minVotePrice The minimum vote price during the transaction
   * @return maxVotePrice The maximum vote price during the transaction
   */
  function simulateSell(
    uint256 profileId,
    bool isPositive,
    uint256 amount
  )
    public
    view
    activeMarket(profileId)
    returns (
      uint256 votesSold,
      uint256 fundsReceived,
      uint256 newVotePrice,
      uint256 protocolFee,
      uint256 minVotePrice,
      uint256 maxVotePrice
    )
  {
    _checkMarketExists(profileId);
    (
      votesSold,
      fundsReceived,
      newVotePrice,
      protocolFee,
      minVotePrice,
      maxVotePrice
    ) = _calculateSell(markets[profileId], profileId, isPositive, amount);
  }

  // --- Internal Helper Functions ---

  function _emitMarketUpdate(uint256 profileId) private {
    _checkMarketExists(profileId);
    uint256 currentPositivePrice = getVotePrice(profileId, true);
    uint256 currentNegativePrice = getVotePrice(profileId, false);

    MarketUpdateInfo storage lastUpdate = lastMarketUpdates[profileId];

    int256 deltaVoteTrust;
    int256 deltaVoteDistrust;
    int256 deltaPositivePrice;
    int256 deltaNegativePrice;

    if (lastUpdate.lastUpdateBlock != 0) {
      deltaVoteTrust = int256(markets[profileId].votes[TRUST]) - int256(lastUpdate.voteTrust);
      deltaVoteDistrust =
        int256(markets[profileId].votes[DISTRUST]) -
        int256(lastUpdate.voteDistrust);
      deltaPositivePrice = int256(currentPositivePrice) - int256(lastUpdate.positivePrice);
      deltaNegativePrice = int256(currentNegativePrice) - int256(lastUpdate.negativePrice);
    } else {
      deltaVoteTrust = int256(markets[profileId].votes[TRUST]);
      deltaVoteDistrust = int256(markets[profileId].votes[DISTRUST]);
      deltaPositivePrice = int256(currentPositivePrice);
      deltaNegativePrice = int256(currentNegativePrice);
    }

    emit MarketUpdated(
      profileId,
      markets[profileId].votes[TRUST],
      markets[profileId].votes[DISTRUST],
      currentPositivePrice,
      currentNegativePrice,
      deltaVoteTrust,
      deltaVoteDistrust,
      deltaPositivePrice,
      deltaNegativePrice,
      block.number,
      block.timestamp
    );

    // Update the lastMarketUpdates mapping
    lastMarketUpdates[profileId] = MarketUpdateInfo({
      voteTrust: markets[profileId].votes[TRUST],
      voteDistrust: markets[profileId].votes[DISTRUST],
      positivePrice: currentPositivePrice,
      negativePrice: currentNegativePrice,
      lastUpdateBlock: block.number
    });
  }

  /**
   * @notice Sends ETH to the message sender
   * @param amount The amount of ETH to send
   * @dev Reverts if the transfer fails
   */
  function _sendEth(uint256 amount) private {
    (bool success, ) = payable(msg.sender).call{ value: amount }("");
    require(success, "ETH transfer failed");
  }

  /**
   * @dev Gets the verified profile ID for an address, reverts if none exists
   * @param userAddress The address to look up
   * @return profileId The verified profile ID for the address
   */
  function _getProfileIdForAddress(address userAddress) private view returns (uint256) {
    if (userAddress == address(0)) {
      revert ZeroAddressNotAllowed();
    }
    uint256 profileId = _ethosProfileContract().verifiedProfileIdForAddress(userAddress);
    if (profileId == 0) {
      revert InvalidProfileId();
    }
    return profileId;
  }

  /**
   * @notice Calculates the buy or sell price for votes based on market state
   * @dev Uses bonding curve formula: price = (votes * basePrice) / totalVotes
   * Markets are double sided, so the price of trust and distrust votes always sum to the base price
   * @param market The market state to calculate price for
   * @param isPositive Whether to calculate trust (true) or distrust (false) vote price
   * @return The calculated vote price
   */
  function _calcVotePrice(Market memory market, bool isPositive) private pure returns (uint256) {
    uint256 totalVotes = market.votes[TRUST] + market.votes[DISTRUST];
    return (market.votes[isPositive ? TRUST : DISTRUST] * market.basePrice) / totalVotes;
  }

  /**
   * @notice Calculates the outcome of a buy transaction
   * @dev Simulates the entire buy process including:
   *      - Price impact calculation using bonding curve
   *      - Fee calculations (protocol fee and donation)
   *      - Slippage protection via min/max price tracking
   * @param market Current market state
   * @param isPositive Whether buying trust (true) or distrust (false) votes
   * @param funds Amount of ETH being spent
   * @return votesBought Number of votes that will be received
   * @return fundsPaid Total amount paid including fees
   * @return newVotePrice Final price per vote after purchase
   * @return protocolFee Protocol fee amount
   * @return donation Donation amount for market owner
   * @return minVotePrice Minimum price during transaction
   * @return maxVotePrice Maximum price during transaction
   */
  function _calculateBuy(
    Market memory market,
    bool isPositive,
    uint256 funds
  )
    private
    view
    returns (
      uint256 votesBought,
      uint256 fundsPaid,
      uint256 newVotePrice,
      uint256 protocolFee,
      uint256 donation,
      uint256 minVotePrice,
      uint256 maxVotePrice
    )
  {
    uint256 fundsAvailable;
    (fundsAvailable, protocolFee, donation) = previewFees(funds, true);
    uint256 votePrice = _calcVotePrice(market, isPositive);

    uint256 minPrice = votePrice;
    uint256 maxPrice;

    if (fundsAvailable < votePrice) {
      revert InsufficientFunds();
    }

    while (fundsAvailable >= votePrice) {
      fundsAvailable -= votePrice;
      fundsPaid += votePrice;
      votesBought++;

      market.votes[isPositive ? TRUST : DISTRUST] += 1;
      votePrice = _calcVotePrice(market, isPositive);
    }
    fundsPaid += protocolFee + donation;

    maxPrice = votePrice;

    return (votesBought, fundsPaid, votePrice, protocolFee, donation, minPrice, maxPrice);
  }

  /**
   * @notice Calculates the outcome of a sell transaction
   * @dev Simulates the entire sell process including:
   *      - Price impact calculation using bonding curve
   *      - Fee calculations (protocol fee only, no donation on sells)
   *      - Slippage protection via min/max price tracking
   *      - Prevents selling when market would be depleted
   * @param market Current market state
   * @param profileId ID of the market
   * @param isPositive Whether selling trust (true) or distrust (false) votes
   * @param amount Number of votes to sell
   * @return votesSold Number of votes that will be sold
   * @return fundsReceived Amount received after fees
   * @return newVotePrice Final price per vote after sale
   * @return protocolFee Protocol fee amount
   * @return minVotePrice Minimum price during transaction
   * @return maxVotePrice Maximum price during transaction
   */
  function _calculateSell(
    Market memory market,
    uint256 profileId,
    bool isPositive,
    uint256 amount
  )
    private
    view
    returns (
      uint256 votesSold,
      uint256 fundsReceived,
      uint256 newVotePrice,
      uint256 protocolFee,
      uint256 minVotePrice,
      uint256 maxVotePrice
    )
  {
    uint256 votesAvailable = votesOwned[msg.sender][profileId].votes[isPositive ? TRUST : DISTRUST];

    if (votesAvailable < amount) {
      revert InsufficientVotesOwned(profileId, msg.sender);
    }

    uint256 votePrice = _calcVotePrice(market, isPositive);

    uint256 maxPrice = votePrice;
    uint256 minPrice;

    while (votesSold < amount) {
      if (market.votes[isPositive ? TRUST : DISTRUST] <= 1) {
        revert InsufficientVotesToSell(profileId);
      }

      market.votes[isPositive ? TRUST : DISTRUST] -= 1;
      votePrice = _calcVotePrice(market, isPositive);
      fundsReceived += votePrice;
      votesSold++;
    }
    (fundsReceived, protocolFee, ) = previewFees(fundsReceived, false);
    minPrice = votePrice;

    return (votesSold, fundsReceived, votePrice, protocolFee, minPrice, maxPrice);
  }

  /* @notice Verifies a market exists for the given profile ID
   * @param profileId The ID of the profile to check
   * @dev Required before any market interaction to prevent operations on non-existent markets
   */
  function _checkMarketExists(uint256 profileId) private view {
    if (markets[profileId].votes[TRUST] == 0 && markets[profileId].votes[DISTRUST] == 0) {
      revert MarketDoesNotExist(profileId);
    }
  }

  /* @notice Verifies a profile exists and is active in the Ethos Profile system
   * @param profileId The ID of the profile to check
   * @dev Prevents market operations involving invalid or archived profiles
   */
  function _checkProfileExists(uint256 profileId) private view {
    if (profileId == 0) {
      revert InvalidProfileId();
    }
    (bool exists, bool archived) = _ethosProfileContract().profileExistsAndArchivedForId(profileId);
    if (!exists || archived) {
      revert InvalidProfileId();
    }
  }

  /* @notice Gets the caller's verified Ethos profile ID
   * @return The profile ID for msg.sender
   */
  function _checkAddressHasProfile() private view returns (uint256) {
    return _ethosProfileContract().verifiedProfileIdForAddress(msg.sender);
  }

  /* @notice Validates that received votes meet minimum expectations
   * @param actual Actual votes received from transaction
   * @param expected Expected votes to receive
   * @param slippageBasisPoints Maximum allowed slippage (1 basis point = 0.01%)
   * @dev Protects users from receiving fewer votes than expected due to price movement
   */
  function _checkSlippageLimit(
    uint256 actual,
    uint256 expected,
    uint256 slippageBasisPoints
  ) private pure {
    uint256 minimumVotes = expected.mulDiv(
      SLIPPAGE_POINTS_BASE - slippageBasisPoints,
      SLIPPAGE_POINTS_BASE,
      Math.Rounding.Ceil
    );
    if (actual < minimumVotes) {
      revert SlippageLimitExceeded(actual, expected, slippageBasisPoints);
    }
  }

  /* @notice Gets interface for interacting with Ethos Profile system
   * @return IEthosProfile interface for profile operations
   */
  function _ethosProfileContract() private view returns (IEthosProfile) {
    return IEthosProfile(contractAddressManager.getContractAddressForName(ETHOS_PROFILE));
  }

  /**
   * @notice Processes protocol fees and donations for a market transaction
   * @dev Handles both protocol fee transfer and donation escrow updates.
   *      Protocol fees go to protocol fee address immediately.
   *      Donations are held in escrow until withdrawn by recipient.
   * @param protocolFee Amount of protocol fee to collect
   * @param donation Amount to add to donation escrow
   * @param marketOwnerProfileId Profile ID of market owner receiving donation
   * @return fees Total fees processed
   */
  function applyFees(
    uint256 protocolFee,
    uint256 donation,
    uint256 marketOwnerProfileId
  ) private returns (uint256 fees) {
    donationEscrow[donationRecipient[marketOwnerProfileId]] += donation;
    if (protocolFee > 0) {
      (bool success, ) = protocolFeeAddress.call{ value: protocolFee }("");
      if (!success) revert FeeTransferFailed("Protocol fee deposit failed");
    }
    fees = protocolFee + donation;
  }

  /**
   * @notice Calculates fees for a market transaction
   * @dev Entry transactions (buys) incur both protocol fees and donations
   *      Exit transactions (sells) only incur protocol fees
   *      Fees are calculated in basis points (1 basis point = 0.01%)
   *      Maximum fee limits are enforced
   * @param amount Transaction amount to calculate fees for
   * @param isEntry True for buy transactions, false for sell transactions
   * @return funds Amount after fees deducted
   * @return protocolFee Protocol fee amount
   * @return donation Donation amount for market owner
   */
  function previewFees(
    uint256 amount,
    bool isEntry
  ) private view returns (uint256 funds, uint256 protocolFee, uint256 donation) {
    if (isEntry) {
      protocolFee = (amount * entryProtocolFeeBasisPoints) / BASIS_POINTS_BASE;
      donation = (amount * donationBasisPoints) / BASIS_POINTS_BASE;
    } else {
      protocolFee = (amount * exitProtocolFeeBasisPoints) / BASIS_POINTS_BASE;
    }
    funds = amount - protocolFee - donation;
  }
}