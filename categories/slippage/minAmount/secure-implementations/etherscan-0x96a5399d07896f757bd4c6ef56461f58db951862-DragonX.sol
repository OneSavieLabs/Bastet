// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

// OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Library
import "./lib/DragonStake.sol";
import "./lib/Constants.sol";
import "./lib/Types.sol";
import "./lib/interfaces/ITitanX.sol";

/**
 * @title The DragonX Contranct
 * @author The DragonX devs
 */
contract DragonX is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ITitanX;

    // -----------------------------------------
    // Type declarations
    // -----------------------------------------

    // -----------------------------------------
    // State variables
    // -----------------------------------------
    /**
     * @notice The TitanX buy contract address.
     * Set at runtime, this address allows for upgrading the buy contract version.
     */
    address public titanBuyAddress;

    /**
     * @notice The DragonX buy and burn contract address.
     * Set at runtime, this allows for upgrading the DragonX buy and burn contract.
     */
    address public dragonBuyAndBurnAddress;

    /**
     * @notice The start time of the mint phase, expressed in UTC seconds.
     * Indicates when the minting phase for tokens begins.
     */
    uint256 public mintPhaseBegin;

    /**
     * @notice The end time of the mint phase, expressed in UTC seconds.
     * Indicates when the minting phase for tokens ends.
     */
    uint256 public mintPhaseEnd;

    /**
     * @notice mint ratios from launch for 84 days (12 weeks)
     */
    uint256 public constant mintRatioWeekOne = BASIS;
    uint256 public constant mintRatioWeekTwo = BASIS;
    uint256 public constant mintRatioWeekThree = 9500;
    uint256 public constant mintRatioWeekFour = 9000;
    uint256 public constant mintRatioWeekFive = 8500;
    uint256 public constant mintRatioWeekSix = 8000;
    uint256 public constant mintRatioWeekSeven = 7500;
    uint256 public constant mintRatioWeekEight = 7000;
    uint256 public constant mintRatioWeekNine = 6500;
    uint256 public constant mintRatioWeekTen = 6000;
    uint256 public constant mintRatioWeekEleven = 5500;
    uint256 public constant mintRatioWeekTwelve = 5000;

    /**
     * @notice The time when it's possible to open a new TitanX stake after the cooldown.
     * This cooldown period controls the frequency of new stakes being initiated.
     */
    uint256 public nextStakeTs;

    /**
     * @notice The number of DragonStake contracts that have been deployed.
     * Tracks how many DragonStake contracts exist within the system.
     */
    uint256 public numDragonStakeContracts;

    /**
     * @notice The address of the currently active DragonStake contract instance.
     * This contract is used for initiating new TitanX stakes.
     */
    address public activeDragonStakeContract;

    /**
     * @notice A mapping from an ID to a deployed instance of the DragonStake contract.
     * The index starts at zero. Use a loop to iterate through instances, e.g., for(uint256 idx = 0; idx < numDragonStakeContracts; idx++).
     */
    mapping(uint256 => address) public dragonStakeContracts;

    /**
     * @notice The amount of TitanX currently held by this contract and not used in stakes.
     * Represents the reserve of TitanX tokens that are available but not currently staked.
     */
    uint256 public vault;

    /**
     * @notice The total amount of Titan staked by DragonX
     */
    uint256 public totalTitanStaked;

    /**
     * @notice The total amount of Titan unstaked by DragonX
     */
    uint256 public totalTitanUnstaked;

    /**
     * @notice The total amount of ETH claimed by DragonX
     */
    uint256 public totalEthClaimed;

    /**
     * Indicates that the initial liquidity has been minted
     */
    InitialLiquidityMinted public initalLiquidityMinted;

    /**
     * @dev Mapping of amounts allocated to the genesis address held by this contract.
     * - address(0): Represents the ETH allocated.
     * - address(TitanX): Represents the TitanX tokens allocated.
     * - address(this): Represents the DragonX tokens allocated.
     */
    mapping(address => uint256) private _genesisVault;

    /**
     * @dev Mapping of address to bool indicating if an address is allowed to send ETH
     * to DragonX limiting EOA addresses from accidently sending ETH to DragonX
     */
    mapping(address => bool) private _receiveEthAllowlist;

    /**
     * @dev Mapping of address to bool indicating if an address is a DragonStake instance
     */
    mapping(address => bool) private _dragonStakeAllowlist;

    // -----------------------------------------
    // Events
    // -----------------------------------------
    /**
     * @dev Event emitted when a new Dragon stake instance is created.
     * @param stakeContractId Unique identifier of the stake contract.
     * @param stakeContractAddress Address of the newly created stake contract.
     */
    event DragonStakeInstanceCreated(
        uint256 indexed stakeContractId,
        address indexed stakeContractAddress
    );

    /**
     * @notice Emitted when staking rewards are claimed.
     * @param caller The address of the caller who initiated the transaction.
     * @param totalClaimed The total amount of ETH claimed.
     * @param titanBuy Amount transfered to TitanBuy.
     * @param dragonBuyAndBurn Amount transfered to DragonBuyAndBurn
     * @param genesis Amount accounted to genesis
     * @param incentiveFee Incentive see send to caller
     * (this might include the incentice for calling triggerPayouts on TitanX)
     */
    event Claimed(
        address indexed caller,
        uint256 indexed totalClaimed,
        uint256 titanBuy,
        uint256 dragonBuyAndBurn,
        uint256 genesis,
        uint256 incentiveFee
    );

    /**
     * @notice Emitted when a new TitanX stake is opened by Dragonx
     * @param dragonStakeAddress The DragonStake instance used for this stake
     * @param amount The amount staked
     */
    event TitanStakeStarted(address indexed dragonStakeAddress, uint256 amount);

    /**
     * @notice Emitted when TitanX stakes are ended by Dragonx
     * @param dragonStakeAddress The DragonStake instance used for this action
     * @param amount The amount unstaked
     */
    event TitanStakesEnded(address indexed dragonStakeAddress, uint256 amount);

    // -----------------------------------------
    // Errors
    // -----------------------------------------
    /**
     * @dev Error emitted when a user tries to mint but the minting phase has not started.
     * This prevents actions related to minting before the official commencement of the minting period.
     */
    error MintingNotYetActive();

    /**
     * @dev Error when a user tries to mint but the minting phase has ended.
     * This ensures minting operations are restricted to the designated minting timeframe.
     */
    error MintingPeriodOver();

    /**
     * @dev Emitted when a user tries to mint but the TitanX allowance for this contract is too low.
     * Indicates that the contract does not have enough TitanX tokens allocated to it for the minting operation.
     */
    error InsufficientTitanXAllowance();

    /**
     * @dev Emitted when a user tries to mint without having enough TitanX tokens.
     * This ensures that users have a sufficient balance of TitanX tokens to perform the minting operation.
     */
    error InsufficientTitanXBalance();

    /**
     * @dev Error emitted when the stake function is currently in the cooldown period and cannot be called.
     * This enforces a waiting period before the stake function can be executed again.
     */
    error CooldownPeriodActive();

    /**
     * @dev Emitted when no additional stakes can be opened.
     * This is triggered when the maximum limit of open stakes is reached.
     */
    error NoAdditionalStakesAllowed();

    /**
     * @dev Error emitted when there is no ETH claimable by the function caller.
     * This ensures that the claim operation is only performed when there is ETH available to be claimed.
     */
    error NoEthClaimable();

    /**
     * @dev Error emitted when there are no tokens available to stake.
     * This ensures that the staking operation is only executed when there are tokens to be staked.
     */
    error NoTokensToStake();

    /**
     * @dev Error emitted when there is no need for creating a new Dragon stake instance.
     * This occurs when attempting to create a redundant Dragon stake instance.
     */
    error NoNeedForNewDragonStakeInstance();

    /**
     * @dev Error emitted when an invalid address is given to a function.
     * This occurs when the genesis address manages an address and passes address(0) by accident.
     */
    error InvalidAddress();

    /**
     * @dev Error emitted when a user attempts to mint but the initial liquidity has net yet been mined
     */
    error LiquidityNotMintedYet();

    /**
     * @dev Thrown when the function caller is not authorized or expected.
     */
    error InvalidCaller();

    // -----------------------------------------
    // Modifiers
    // -----------------------------------------
    /**
     * @dev Modifier to restrict function access to allowed DragonStake contracts.
     *
     * This modifier ensures that the function can only be called by addresses that are
     * present in the `_dragonStakeAllowlist`. If the calling address is not on the allowlist,
     * the transaction will revert with the message "not allowed".
     * @notice Use this modifier to restrict function access to specific addresses only.
     */
    modifier onlyDragonStake() {
        require(_dragonStakeAllowlist[_msgSender()], "not allowed");
        _;
    }

    // -----------------------------------------
    // Constructor
    // -----------------------------------------
    /**
     * @notice Constructor for the DragonX ERC20 Token Contract.
     * @dev Initializes the contract, sets up the minting phase, and deploys the first DragonStake instance.
     *      - Inherits from ERC20 and sets token name to "DragonX" and symbol to "DRAGONX".
     *      - Calculates and sets the start and end times for the minting phase based on current time.
     *      - Sets the time for the next restake opportunity.
     *      - Deploys the first DragonStake contract instance.
     *      - Transfers ownership to contract deployer.
     *      - Set the initial TitanBuy and DragonBuyAndBurn contract addresses.
     * @param titanBuyAddress_ The address of the TitanBuy contract instance.
     * @param dragonBuyAndBurnAdddress_ The address of the DragonBuyAndBurn contract instance.
     */
    constructor(
        address titanBuyAddress_,
        address dragonBuyAndBurnAdddress_
    ) ERC20("DragonX", "DRAGONX") Ownable(msg.sender) {
        if (titanBuyAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (dragonBuyAndBurnAdddress_ == address(0)) {
            revert InvalidAddress();
        }

        // Deploy stake contract instance setting DragonX as its owner
        _deployDragonStakeInstance();

        // Set contract addresses
        titanBuyAddress = titanBuyAddress_;
        dragonBuyAndBurnAddress = dragonBuyAndBurnAdddress_;

        // set other states
        initalLiquidityMinted = InitialLiquidityMinted.No;

        // Allow TitanX to send ETH to DragonX (incentive fee)
        _receiveEthAllowlist[TITANX_ADDRESS] = true;
    }

    // -----------------------------------------
    // Receive function
    // -----------------------------------------
    /**
     * @dev Receive function to handle plain Ether transfers.
     * Reverts if the sender is not one of the DragonStake contracts.
     */
    receive() external payable {
        require(_receiveEthAllowlist[msg.sender], "Sender not authorized");
    }

    // -----------------------------------------
    // Fallback function
    // -----------------------------------------
    /**
     * @dev Fallback function to handle non-function calls or Ether transfers if receive() doesn't exist.
     * Always revert
     */
    fallback() external {
        revert("Fallback triggered");
    }

    // -----------------------------------------
    // External functions
    // -----------------------------------------
    /**
     * This function enables the minting of DragonX tokens in exchange for TitanX.
     * Users can transfer TitanX to the DragonX contract to mint an equivalent amount of DragonX tokens.
     * The minting process is available only during a specified time frame.
     * When minting, 8% of the total minted DragonX supply and 8% of the TitanX used for minting
     * are allocated to the genesis address. The remaining TitanX is retained within the contract.
     * Minting starts once the initial liquidity has been minted (indicating all other contracts)
     * have been deployed and initialized successfully by the genesis address.
     * @param amount The amount of DragonX tokens to be minted.
     */
    function mint(uint256 amount) external {
        // Cache state variables
        uint256 mintPhaseBegin_ = mintPhaseBegin;

        // To avoid being frontrun, minting creating DragonX tokens will only
        // be able once the inital liqudiity ahs been created
        if (initalLiquidityMinted != InitialLiquidityMinted.Yes) {
            revert LiquidityNotMintedYet();
        }

        // Check if the minting phase is currently active
        if (block.timestamp < mintPhaseBegin_) {
            revert MintingNotYetActive();
        }

        if (block.timestamp > mintPhaseEnd) {
            revert MintingPeriodOver();
        }

        ITitanX titanX = ITitanX(TITANX_ADDRESS);
        // Ensure the user has sufficient TitanX and has granted enough allowance
        if (titanX.allowance(_msgSender(), address(this)) < amount) {
            revert InsufficientTitanXAllowance();
        }
        if (titanX.balanceOf(_msgSender()) < amount) {
            revert InsufficientTitanXBalance();
        }

        // Transfer TitanX from the user to this contract
        titanX.safeTransferFrom(_msgSender(), address(this), amount);

        uint256 ratio;
        if (block.timestamp < mintPhaseBegin_ + 7 days) {
            // week 1
            ratio = mintRatioWeekOne;
        } else if (block.timestamp < mintPhaseBegin_ + 14 days) {
            // week 2
            ratio = mintRatioWeekTwo;
        } else if (block.timestamp < mintPhaseBegin_ + 21 days) {
            // week 3
            ratio = mintRatioWeekThree;
        } else if (block.timestamp < mintPhaseBegin_ + 28 days) {
            // week 4
            ratio = mintRatioWeekFour;
        } else if (block.timestamp < mintPhaseBegin_ + 35 days) {
            // week 5
            ratio = mintRatioWeekFive;
        } else if (block.timestamp < mintPhaseBegin_ + 42 days) {
            // week 6
            ratio = mintRatioWeekSix;
        } else if (block.timestamp < mintPhaseBegin_ + 49 days) {
            // week 7
            ratio = mintRatioWeekSeven;
        } else if (block.timestamp < mintPhaseBegin_ + 56 days) {
            // week 8
            ratio = mintRatioWeekEight;
        } else if (block.timestamp < mintPhaseBegin_ + 63 days) {
            // weeek 9
            ratio = mintRatioWeekNine;
        } else if (block.timestamp < mintPhaseBegin_ + 70 days) {
            // week 10
            ratio = mintRatioWeekTen;
        } else if (block.timestamp < mintPhaseBegin_ + 77 days) {
            // week 11
            ratio = mintRatioWeekEleven;
        } else {
            // week 12
            ratio = mintRatioWeekTwelve;
        }

        // calculate the amount to mint
        uint256 mintAmount = (amount * ratio) / BASIS;

        // Mint an equivalent amount of DragonX tokens
        _mint(_msgSender(), mintAmount);

        // Calculate and mint the genesis 8% share (of total supply minted)
        uint256 dragonGenesisShare = (mintAmount * 800) / BASIS;
        _mint(address(this), dragonGenesisShare);

        // Allocate 8% of DragonX to the genesis vault
        _genesisVault[address(this)] += dragonGenesisShare;

        // Allocate 8% of total TitanX send to DragonX to genesis vault
        uint256 titanGenesisShare = (amount * 800) / BASIS;
        _genesisVault[address(titanX)] += titanGenesisShare;

        // Retain the remaining TitanX within the contract's vault
        vault += amount - titanGenesisShare;
    }

    /**
     * This function allows users to open a new TitanX stake through the DragonX contract.
     * Each stake runs for the maximum duration, and upon completion, the TitanX is burned.
     *
     * A stake can be opened when either of the following conditions is met:
     * 1. The vault has sufficient TitanX tokens to achieve the maximum 'bigger pays better' bonus.
     * 2. If the vault doesn't have enough tokens, the function can be invoked after a cooldown
     *    period of 1 week. This delay allows the accumulation of sufficient TitanX to gain
     *    the 'bigger pays better' bonus.
     */
    function stake() external {
        DragonStake dragonStake = DragonStake(
            payable(activeDragonStakeContract)
        );

        if (dragonStake.openedStakes() >= TITANX_MAX_STAKE_PER_WALLET) {
            revert NoAdditionalStakesAllowed();
        }

        updateVault();

        // Cache state variables
        uint256 vault_ = vault;

        if (vault_ == 0) {
            revert NoTokensToStake();
        }

        if (vault_ >= TITANX_BPB_MAX_TITAN) {
            // Start a stake using the currently active DragonStake instance
            _startStake();

            // Schedule the next possible stake after a 7-day cooldown period
            nextStakeTs = block.timestamp + 7 days;
        } else {
            // If the vault lacks sufficient TitanX, a stake can be opened only
            // after a cooldown period of 7 days to allow for token accumulation.
            if (block.timestamp < nextStakeTs) {
                revert CooldownPeriodActive();
            }

            // Start a new stake using the currently active DragonStake instance
            _startStake();

            // Schedule the next possible stake after a 7-day cooldown period.
            nextStakeTs = block.timestamp + 7 days;
        }
    }

    /**
     * Claim Function for ETH Rewards
     * This function claims ETH rewards based on TitanX stakes and allocates them according to predefined shares.
     * @dev The function performs the following operations:
     *      1. Retrieves the claimable ETH amount from TitanX stakes.
     *      2. Validates if there is any ETH to claim, and reverts if none is available.
     *      3. Claims the available ETH payouts.
     *      4. Calculates and distributes the ETH according to predefined shares:
     *         - 8% is allocated as a genesis share.
     *         - 3% is sent as a tip to the caller of the function.
     *         - 44.5% is used for buying and burning DragonX tokens.
     *         - The remaining 44.5% is used for buying and burning TitanX tokens.
     *      5. Updates the respective vaults with their allocated shares.
     *      6. Sends the tip to the caller of the function.
     */
    function claim() external nonReentrant returns (uint256 claimedAmount) {
        //prevent contract accounts (bots) from calling this function
        if (msg.sender != tx.origin) {
            revert InvalidCaller();
        }

        // Trigger payouts on TitanX
        // This potentially sends an incentive fee to DragonX
        // The incentive fee is transparently forwarded to the caller
        uint256 ethBalanceBefore = address(this).balance;
        ITitanX(TITANX_ADDRESS).triggerPayouts();
        uint256 triggerPayoutsIncentiveFee = address(this).balance -
            ethBalanceBefore;

        // Retrieve the total claimable ETH amount.
        for (uint256 idx; idx < numDragonStakeContracts; idx++) {
            DragonStake dragonStake = DragonStake(
                payable(dragonStakeContracts[idx])
            );
            claimedAmount += dragonStake.claim();
        }

        // Check if there is any claimable ETH, revert if none.
        if (claimedAmount == 0) {
            revert NoEthClaimable();
        }

        // Calculate the genesis share (8%).
        uint256 genesisShare = (claimedAmount * 800) / BASIS;

        // Calculate the tip for the caller (3%).
        uint256 incentiveFee = (claimedAmount * INCENTIVE_FEE) / BASIS;

        // Calculate the Buy and Burn share for DragonX (44.5%).
        uint256 buyAndBurnDragonX = (claimedAmount * 4450) / BASIS;

        // Calculate the Buy and Burn share for TitanX (remainder, ~44.5%).
        uint256 buyTitanX = claimedAmount -
            genesisShare -
            buyAndBurnDragonX -
            incentiveFee;

        // Update the genesis vault with the genesis share.
        _genesisVault[address(0)] += genesisShare;

        // Send to the Buy and Burn contract for DragonX.
        Address.sendValue(payable(dragonBuyAndBurnAddress), buyAndBurnDragonX);

        // Send to the buy contract for TitanX.
        Address.sendValue(payable(titanBuyAddress), buyTitanX);

        // Send the tip to the function caller.
        address sender = _msgSender();
        Address.sendValue(
            payable(sender),
            incentiveFee + triggerPayoutsIncentiveFee
        );

        // update state
        totalEthClaimed += claimedAmount;

        // Emit event
        emit Claimed(
            sender,
            claimedAmount,
            buyTitanX,
            buyAndBurnDragonX,
            genesisShare,
            incentiveFee + triggerPayoutsIncentiveFee
        );
    }

    /**
     * @notice Factory function to deploy a new DragonStake contract instance.
     * @dev This function deploys a new DragonStake instance if the number of open stakes in the current
     *      active instance exceeds the maximum allowed per wallet.
     *      It reverts with NoNeedForNewDragonStakeInstance if the condition is not met.
     *      Only callable externally.
     */
    function deployNewDragonStakeInstance() external {
        DragonStake dragonStake = DragonStake(
            payable(activeDragonStakeContract)
        );

        // Check if the maximum number of stakes per wallet has been reached
        if (dragonStake.openedStakes() < TITANX_MAX_STAKE_PER_WALLET) {
            revert NoNeedForNewDragonStakeInstance();
        }

        // Deploy a new DragonStake instance
        _deployDragonStakeInstance();
    }

    /**
     * @notice Mints the initial liquidity for the DragonX token.
     * @dev This function mints a specified amount of tokens and sets up the minting phases.
     * It can only be called once by the authorized address.
     * @param amount The amount of DragonX tokens to be minted for initial liquidity.
     */
    function mintInitialLiquidity(uint256 amount) external {
        // Cache state variables
        address dragonBuyAndBurnAddress_ = dragonBuyAndBurnAddress;

        // Verify that the caller is authorized to mint initial liquidity
        require(msg.sender == dragonBuyAndBurnAddress_, "not authorized");

        // Ensure that initial liquidity hasn't been minted before
        require(
            initalLiquidityMinted == InitialLiquidityMinted.No,
            "already minted"
        );

        // Mint the specified amount of DragonX tokens to the authorized address
        _mint(dragonBuyAndBurnAddress_, amount);

        // Update the state to reflect that initial liquidity has been minted
        initalLiquidityMinted = InitialLiquidityMinted.Yes;

        // Set up the minting phase timings
        uint256 currentTimestamp = block.timestamp;
        uint256 secondsUntilMidnight = 86400 - (currentTimestamp % 86400);

        // The mint phase is open for 84 days (12 weeks) and begins at midnight
        // once contracts are fully set up
        uint256 mintPhaseBegin_ = currentTimestamp + secondsUntilMidnight;

        // Update storage
        mintPhaseBegin = mintPhaseBegin_;

        // Set mint phase end
        mintPhaseEnd = mintPhaseBegin_ + 84 days;

        // Allow the first stake after 7 days of mint-phase begin
        nextStakeTs = mintPhaseBegin_ + 7 days;
    }

    /**
     *  Token Burn Function
     * @notice Allows a token holder to burn all of their tokens.
     * @dev Burns the entire token balance of the caller. This function calls `_burn`
     *      with the caller's address and their full token balance.
     *      This function can be called by any token holder wishing to burn their tokens.
     *      Tokens burned are permanently removed from the circulation.
     * @custom:warning WARNING: This function will irreversibly burn all tokens in the caller's account.
     * Ensure you understand the consequences before calling.
     */
    function burn() external {
        address sender = _msgSender();
        _burn(sender, balanceOf(sender));
    }

    /**
     * @notice Calculates the total number of stakes opened across all DragonStake contract instances.
     * @dev This function iterates over all the DragonStake contract instances recorded in the contract:
     *      1. For each DragonStake contract, it gets a reference to the contract instance.
     *      2. It then calls the `openedStakes` function on each instance to get the number of opened stakes.
     *      3. These values are summed up to calculate the total number of stakes opened across all instances.
     * @return totalStakes The total number of stakes opened across all DragonStake contract instances.
     */
    function totalStakesOpened() external view returns (uint256 totalStakes) {
        // Iterate over all DragonStake contract instances
        for (uint256 idx; idx < numDragonStakeContracts; idx++) {
            // Get a reference to each DragonStake contract
            DragonStake dragonStake = DragonStake(
                payable(dragonStakeContracts[idx])
            );

            // Add the stakes opened by this DragonStake instance
            totalStakes += dragonStake.openedStakes();
        }
    }

    /**
     * @dev Calculate the incentive fee a user will receive for calling the claim function.
     * This function computes the fee based on the total amount of Ethereum claimable
     * and a predefined incentive fee rate.
     *
     * @notice Used to determine the fee awarded for claiming Ethereum.
     *
     * @return fee The calculated incentive fee, represented as a uint256.
     * This value is calculated by taking the product of `totalEthClaimable()` and
     * `INCENTIVE_FEE`, then dividing by `BASIS` to normalize the fee calculation.
     */
    function incentiveFeeForClaim() external view returns (uint256 fee) {
        fee = (totalEthClaimable() * INCENTIVE_FEE) / BASIS;
    }

    /**
     * @dev Checks all DragonStake contract instances to determine if any stake has reached maturity.
     *      Iterates through each DragonStake contract instance and checks for stakes that have reached maturity.
     *      If a stake has reached maturity in a particular instance, it returns true along with the instance's address and the ID.
     *      If no stakes have reached maturity in any instance, it returns false and a zero address and zero for the ID.
     * @return hasStakesToEnd A boolean indicating if there is at least one stake that has reached maturity.
     * @return instanceAddress The address of the DragonStake contract instance that has a stake which reached maturity.
     * @return sId The ID of the stake which reached maturity
     *         Returns zero address if no such instance is found.
     * @notice This function is used to identify if and where stakes have reached maturity across multiple contract instances.
     */
    function stakeReachedMaturity()
        external
        view
        returns (bool hasStakesToEnd, address instanceAddress, uint256 sId)
    {
        // Iterate over all DragonStake contract instances
        for (uint256 idx; idx < numDragonStakeContracts; idx++) {
            address instance = dragonStakeContracts[idx];

            // Get a reference to each DragonStake contract
            DragonStake dragonStake = DragonStake(payable(instance));

            (bool reachedMaturity, uint256 id) = dragonStake
                .stakeReachedMaturity();

            // Exit if this instance contains a stake that reached maturity
            if (reachedMaturity) {
                return (true, instance, id);
            }
        }

        return (false, address(0), 0);
    }

    /**
     * @dev Sets the address used for buying and burning DRAGONX tokens.
     * @notice This function can only be called by the contract owner.
     * @param dragonBuyAndBurn The address to be set for the DRAGONX buy and burn operation.
     * If this address is the zero address, the transaction is reverted.
     * @custom:throws InvalidAddress if the provided address is the zero address.
     */
    function setDragonBuyAndBurnAddress(
        address dragonBuyAndBurn
    ) external onlyOwner {
        if (dragonBuyAndBurn == address(0)) {
            revert InvalidAddress();
        }
        dragonBuyAndBurnAddress = dragonBuyAndBurn;
    }

    /**
     * @dev Sets the address used for buying TITANX tokens.
     * @notice This function can only be called by the contract owner.
     * @param titanBuy The address to be set for the TITANX buy operation.
     * If this address is the zero address, the transaction is reverted.
     * @custom:throws InvalidAddress if the provided address is the zero address.
     */
    function setTitanBuyAddress(address titanBuy) external onlyOwner {
        if (titanBuy == address(0)) {
            revert InvalidAddress();
        }
        titanBuyAddress = titanBuy;
    }

    /**
     * @notice Transfers the accumulated balance of a specified asset from the Genesis Vault to the owner.
     * @dev This function allows the contract owner to claim assets accumulated in the Genesis Vault. It supports both Ether and ERC20 tokens.
     *      The function performs the following operations:
     *        1. Retrieves the balance of the specified asset from the `_genesisVault`.
     *        2. Sets the balance of the asset in the vault to zero, effectively resetting it.
     *        3. Checks that the retrieved balance is greater than zero, and reverts if it's not.
     *        4. If the asset is Ether (denoted by `asset` being the zero address), it transfers the Ether to the owner using `Address.sendValue`.
     *        5. If the asset is an ERC20 token, it transfers the token amount to the owner using `safeTransfer` from the ERC20 token's contract.
     * @param asset The address of the asset to be claimed. A zero address indicates Ether, and a non-zero address indicates an ERC20 token.
     */
    function claimGenesis(address asset) external onlyOwner {
        uint256 balance = _genesisVault[asset];
        _genesisVault[asset] = 0;

        require(balance > 0, "no balance");
        if (asset == address(0)) {
            Address.sendValue(payable(owner()), balance);
        } else {
            IERC20 erc20 = IERC20(asset);
            erc20.safeTransfer(owner(), balance);
        }
    }

    /**
     * @dev Updates the state when a TitanX stake has ended and the tokens are unstaked.
     *
     * This function should be called after unstaking TitanX tokens. It updates the vault
     * and the total amount of TitanX tokens that have been unstaked. This function can only
     * be called by an address that is allowed to end stakes (enforced by the `onlyDragonStake` modifier).
     *
     * @param amountUnstaked The amount of TitanX tokens that have been unstaked.
     * @notice This function is callable externally but restricted to allowed addresses (DragonStake contracts).
     * @notice It emits the `TitanStakesEnded` event after updating the total unstaked amount.
     */
    function stakeEnded(uint256 amountUnstaked) external onlyDragonStake {
        // Update vault (TitanX is transfered to DragonX)
        updateVault();

        // Update state
        totalTitanUnstaked += amountUnstaked;

        // Emit event
        emit TitanStakesEnded(_msgSender(), amountUnstaked);
    }

    // -----------------------------------------
    // Public functions
    // -----------------------------------------
    /**
     * @notice Updates the vault balance based on the current TITANX token balance.
     * @dev This function calculates the vault balance by subtracting the initial
     *      balance of TITANX tokens stored in `_genesisVault` from the current balance of
     *      TITANX tokens held by this contract.
     *      Steps involved in the function:
     *        1. Create an instance of the IERC20 interface for the TITANX token.
     *        2. Fetch the current TITANX token balance of this contract.
     *        3. Subtract the initial TITANX token balance (recorded in `_genesisVault`)
     *           from the current balance.
     *        4. Update the `vault` variable with the resulting value.
     *      The `vault` variable represents the net amount of TITANX tokens that have
     *      been accumulated in this contract since its inception (excluding the initial amount).
     *      This function should be called to reflect the latest state of the vault balance.
     */
    function updateVault() public {
        IERC20 titanX = IERC20(TITANX_ADDRESS);
        uint256 balance = titanX.balanceOf(address(this));

        vault = balance - _genesisVault[address(titanX)];
    }

    /**
     * @notice Calculates the total amount of ETH claimable from all DragonStake contract instances.
     * @dev Iterates through all deployed DragonStake contract instances and sums up the ETH claimable from each.
     *      This function is read-only and can be called externally.
     * @return claimable The total amount of ETH claimable across all DragonStake contract instances.
     */
    function totalEthClaimable() public view returns (uint256 claimable) {
        // Iterate over all DragonStake contract instances
        for (uint256 idx; idx < numDragonStakeContracts; idx++) {
            // Get a reference to each DragonStake contract
            DragonStake dragonStake = DragonStake(
                payable(dragonStakeContracts[idx])
            );

            // Add the claimable ETH from each DragonStake to the total
            claimable += dragonStake.totalEthClaimable();
        }
    }

    // -----------------------------------------
    // Internal functions
    // -----------------------------------------

    // -----------------------------------------
    // Private functions
    // -----------------------------------------
    /**
     * @dev Private function to deploy a DragonStake contract instance.
     *      It deploys a new DragonStake contract using create2 for deterministic addresses,
     *      and updates the activeDragonStakeContract and dragonStakeContracts mapping.
     *      An event DragonStakeInstanceCreated is emitted after successful deployment.
     *      This function is called by the deployNewDragonStakeInstance function.
     */
    function _deployDragonStakeInstance() private {
        // Deploy an instance of dragon staking contract
        bytes memory bytecode = type(DragonStake).creationCode;
        uint256 stakeContractId = numDragonStakeContracts;

        // Create a unique salt for deployment
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), stakeContractId)
        );

        // Deploy a new DragonStake contract instance
        address newDragonStakeContract = Create2.deploy(0, salt, bytecode);

        // Set new contract as active
        activeDragonStakeContract = newDragonStakeContract;

        // Update storage
        dragonStakeContracts[stakeContractId] = newDragonStakeContract;

        // Allow the DragonStake instance to send ETH to DragonX
        _receiveEthAllowlist[newDragonStakeContract] = true;

        // For functions limited to DragonStake
        _dragonStakeAllowlist[newDragonStakeContract] = true;

        // Emit an event to track the creation of a new stake contract
        emit DragonStakeInstanceCreated(
            stakeContractId,
            newDragonStakeContract
        );

        // Increment the counter for DragonStake contracts
        numDragonStakeContracts += 1;
    }

    /**
     * @dev Private function to start a new stake using the currently active DragonStake instance.
     *      It transfers all TitanX tokens held by this contract to the active DragonStake instance
     *      and then initiates a new stake with the total amount transferred.
     *      This function is meant to be called internally by other contract functions.
     */
    function _startStake() private {
        // Cache state variables
        address activeDragonStakeContract_ = activeDragonStakeContract;

        // Initialize TitanX contract reference
        ITitanX titanX = ITitanX(TITANX_ADDRESS);
        DragonStake dragonStake = DragonStake(
            payable(activeDragonStakeContract_)
        );
        uint256 amountToStake = vault;
        vault = 0;

        // Transfer TitanX tokens to the active DragonStake contract
        titanX.safeTransfer(activeDragonStakeContract_, amountToStake);

        // Open a new stake with the total amount transferred
        dragonStake.stake();

        // Update states
        totalTitanStaked += amountToStake;

        // Emit event
        emit TitanStakeStarted(activeDragonStakeContract_, amountToStake);
    }
}