/**
 * Created by Pragma Labs
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity 0.8.22;

import { Creditor } from "../lib/accounts-v2/src/abstracts/Creditor.sol";
import { DebtToken, ERC20, ERC4626 } from "./DebtToken.sol";
import { FixedPointMathLib } from "../lib/solmate/src/utils/FixedPointMathLib.sol";
import { IAccount } from "./interfaces/IAccount.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { ILendingPool } from "./interfaces/ILendingPool.sol";
import { ITranche } from "./interfaces/ITranche.sol";
import { LendingPoolErrors } from "./libraries/Errors.sol";
import { LendingPoolGuardian } from "./guardians/LendingPoolGuardian.sol";
import { LogExpMath } from "./libraries/LogExpMath.sol";
import { SafeCastLib } from "../lib/solmate/src/utils/SafeCastLib.sol";
import { SafeTransferLib } from "../lib/solmate/src/utils/SafeTransferLib.sol";

/**
 * @title Arcadia LendingPool.
 * @author Pragma Labs
 * @notice The Lending pool is responsible for the:
 * - Accounting of the liabilities of borrowers via the debtTokens (ERC4626).
 * - Accounting of the liquidity of the Liquidity Providers, via one or more Tranche(s) (ERC4626).
 * - Management of issuing and repaying debt.
 * - Management of interest payments.
 * - Settlement of liquidations and default events.
 */
contract LendingPool is LendingPoolGuardian, Creditor, DebtToken, ILendingPool {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    /* //////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////// */

    // Seconds per year, leap years ignored.
    uint256 internal constant YEARLY_SECONDS = 31_536_000;
    // Contract address of the Arcadia Account Factory.
    address internal immutable ACCOUNT_FACTORY;
    // Contract address of the Liquidator contract.
    address internal immutable LIQUIDATOR;
    // The unit for fixed point numbers with 4 decimals precision.
    uint256 internal constant ONE_4 = 10_000;
    // Maximum total liquidation penalty, 4 decimal precision.
    uint256 internal constant MAX_TOTAL_PENALTY = 1100;

    /* //////////////////////////////////////////////////////////////
                                STORAGE
    ////////////////////////////////////////////////////////////// */

    // The current interest rate, 18 decimals precision.
    uint80 public interestRate;
    // The interest rate when utilisation is 0.
    // 18 decimals precision.
    uint72 internal baseRatePerYear;
    // The slope of the first curve, defined as the delta in interest rate for a delta in utilisation of 100%.
    // 18 decimals precision.
    uint72 internal lowSlopePerYear;
    // The slope of the second curve, defined as the delta in interest rate for a delta in utilisation of 100%.
    // 18 decimals precision.
    uint72 internal highSlopePerYear;
    // The optimal capital utilisation, where we go from the first curve to the steeper second curve.
    // 4 decimal precision.
    uint16 internal utilisationThreshold;
    // Last timestamp that interests were realized.
    uint32 internal lastSyncedTimestamp;
    // Fee issued upon taking debt, 4 decimals precision (10 equals 0.001 or 0.1%), capped at 255 (2.55%).
    uint8 public originationFee;
    // Sum of all the interest weights of the tranches + treasury.
    uint24 internal totalInterestWeight;
    // Fraction (interestWeightTreasury / totalInterestWeight) of the interest fees that go to the treasury.
    uint16 internal interestWeightTreasury;
    // Fraction (liquidationWeightTreasury / totalLiquidationWeight) of the liquidation fees that goes to the treasury.
    uint16 internal liquidationWeightTreasury;
    // Fraction (liquidationWeightTranche / totalLiquidationWeight) of the liquidation fees that goes to the most Junior Tranche.
    uint16 internal liquidationWeightTranche;

    // Total amount of `underlying asset` that is claimable by the LPs. Does not take into account pending interests.
    uint128 internal totalRealisedLiquidity;
    // The minimum amount of collateral that must be held in an Account before a position can be opened.
    uint96 internal minimumMargin;

    // Address of the protocol treasury.
    address internal treasury;
    // Number of auctions that are currently in progress.
    uint16 internal auctionsInProgress;
    // Maximum amount of `underlying asset` that is paid as fee to the initiator/terminator of a liquidation.
    uint80 internal maxReward;
    // Minimum initiation and termination reward, relative to the minimumMargin, 4 decimal precision.
    uint16 internal minRewardWeight;
    // Fee paid to the Liquidation Initiator.
    // Defined as a fraction of the openDebt with 4 decimals precision.
    // Absolute fee can be further capped to a max amount by the creditor.
    uint16 internal initiationWeight;
    // Penalty the Account owner has to pay to the Creditor on top of the open Debt for being liquidated.
    // Defined as a fraction of the openDebt with 4 decimals precision.
    uint16 internal penaltyWeight;
    // Fee paid to the address that is ending an auction.
    // Defined as a fraction of the openDebt with 4 decimals precision.
    uint16 internal terminationWeight;

    // Array of the interest weights of each Tranche.
    // Fraction (interestWeightTranches[i] / totalInterestWeight) of the interest fees that go to Tranche i.
    uint16[] internal interestWeightTranches;
    // Array of the contract addresses of the Tranches.
    address[] internal tranches;

    // Map tranche => status.
    mapping(address => bool) internal isTranche;
    // Map tranche => interestWeight.
    // Fraction (interestWeightTranches[i] / totalInterestWeight) of the interest fees that go to Tranche i.
    mapping(address => uint256) internal interestWeight;
    // Map tranche => realisedLiquidity.
    // Amount of `underlying asset` that is claimable by the liquidity providers.
    // Does not take into account pending interests.
    mapping(address => uint256) internal realisedLiquidityOf;
    // Map Account => owner => beneficiary => amount.
    // Stores the credit allowances for a beneficiary per Account and per Owner.
    mapping(address => mapping(address => mapping(address => uint256))) public creditAllowance;

    /* //////////////////////////////////////////////////////////////
                                EVENTS
    ////////////////////////////////////////////////////////////// */

    event AuctionStarted(address indexed account, address indexed creditor, uint128 openDebt);
    event AuctionFinished(
        address indexed account,
        address indexed creditor,
        uint256 startDebt,
        uint256 initiationReward,
        uint256 terminationReward,
        uint256 penalty,
        uint256 badDebt,
        uint256 surplus
    );
    event Borrow(
        address indexed account, address indexed by, address to, uint256 amount, uint256 fee, bytes3 indexed referrer
    );
    event CreditApproval(address indexed account, address indexed owner, address indexed beneficiary, uint256 amount);
    event InterestSynced(uint256 interest);
    event InterestWeightTrancheUpdated(address indexed tranche, uint8 indexed trancheIndex, uint16 interestWeight);
    event LiquidationWeightTrancheUpdated(uint16 liquidationWeight);
    event PoolStateUpdated(uint256 totalDebt, uint256 totalLiquidity, uint80 interestRate);
    event Repay(address indexed account, address indexed from, uint256 amount);
    event TranchePopped(address tranche);
    event TreasuryWeightsUpdated(uint16 interestWeight, uint16 liquidationWeight);

    /* //////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Checks if caller is the Liquidator.
     */
    modifier onlyLiquidator() {
        if (LIQUIDATOR != msg.sender) revert LendingPoolErrors.Unauthorized();
        _;
    }

    /**
     * @notice Checks if caller is a Tranche.
     */
    modifier onlyTranche() {
        if (!isTranche[msg.sender]) revert LendingPoolErrors.Unauthorized();
        _;
    }

    /**
     * @notice Syncs interest to LPs and treasury and updates the interest rate.
     */
    modifier processInterests() {
        _syncInterests();
        _;
        // _updateInterestRate() modifies the state (effect), but can safely be called after interactions.
        // Cannot be exploited by re-entrancy attack.
        _updateInterestRate(realisedDebt, totalRealisedLiquidity);
    }

    /* //////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice The constructor for a lending pool.
     * @param riskManager_ The address of the new Risk Manager.
     * @param asset_ The underlying ERC20 token of the Lending Pool.
     * @param treasury_ The address of the protocol treasury.
     * @param accountFactory The contract address of the Arcadia Account Factory.
     * @param liquidator The contract address of the Liquidator.
     * @dev The name and symbol of the DebtToken are automatically generated, based on the name and symbol of the underlying token.
     */
    constructor(address riskManager_, ERC20 asset_, address treasury_, address accountFactory, address liquidator)
        LendingPoolGuardian()
        Creditor(riskManager_)
        DebtToken(asset_)
    {
        treasury = treasury_;
        ACCOUNT_FACTORY = accountFactory;
        LIQUIDATOR = liquidator;
    }

    /* //////////////////////////////////////////////////////////////
                            TRANCHES LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Adds a tranche to the Lending Pool.
     * @param tranche The address of the Tranche.
     * @param interestWeight_ The interest weight of the specific Tranche.
     * @dev The order of the tranches is important, the most senior tranche is added first at index 0, the most junior at the last index.
     * @dev Each Tranche is an ERC4626 contract.
     * @dev The interest weight of each Tranche determines the relative share of the yield (interest payments) that goes to its Liquidity providers.
     */
    function addTranche(address tranche, uint16 interestWeight_) external onlyOwner processInterests {
        if (auctionsInProgress > 0) revert LendingPoolErrors.AuctionOngoing();
        if (isTranche[tranche]) revert LendingPoolErrors.TrancheAlreadyExists();

        totalInterestWeight += interestWeight_;
        interestWeightTranches.push(interestWeight_);
        interestWeight[tranche] = interestWeight_;

        uint8 trancheIndex = uint8(tranches.length);
        tranches.push(tranche);
        isTranche[tranche] = true;

        emit InterestWeightTrancheUpdated(tranche, trancheIndex, interestWeight_);
    }

    /**
     * @notice Changes the interest weight of a specific Tranche.
     * @param index The index of the Tranche for which a new interest weight is being set.
     * @param interestWeight_ The new interest weight of the Tranche at the index.
     * @dev The interest weight of each Tranche determines the relative share of yield (interest payments) that goes to its Liquidity providers.
     */
    function setInterestWeightTranche(uint256 index, uint16 interestWeight_) external onlyOwner processInterests {
        if (index >= tranches.length) revert LendingPoolErrors.NonExistingTranche();
        totalInterestWeight = totalInterestWeight - interestWeightTranches[index] + interestWeight_;
        interestWeightTranches[index] = interestWeight_;
        address tranche = tranches[index];
        interestWeight[tranche] = interestWeight_;

        emit InterestWeightTrancheUpdated(tranche, uint8(index), interestWeight_);
    }

    /**
     * @notice Changes the liquidation weight of the most Junior Tranche.
     * @param liquidationWeight The new liquidation weight of the Tranche at the highest index.
     * @dev The liquidation weight determines the relative share of liquidation fees that goes to the most Junior Tranche.
     */
    function setLiquidationWeightTranche(uint16 liquidationWeight) external onlyOwner {
        emit LiquidationWeightTrancheUpdated(liquidationWeightTranche = liquidationWeight);
    }

    /**
     * @notice Removes the Tranche at the last index (most junior).
     * @param index The index of the last Tranche.
     * @param tranche The address of the last Tranche.
     * @dev This function can only be called by the function _processDefault(uint256 assets),
     * when there is a default as big as (or bigger than) the complete amount of liquidity of the most junior Tranche.
     * @dev Passing the input parameters to the function saves gas compared to reading the address and index of the last Tranche from storage.
     * No need to check if index and Tranche are indeed of the last tranche since function is only called by _processDefault.
     */
    function _popTranche(uint256 index, address tranche) internal {
        unchecked {
            totalInterestWeight -= interestWeightTranches[index];
        }
        isTranche[tranche] = false;
        interestWeightTranches.pop();
        tranches.pop();
        interestWeight[tranche] = 0;

        emit TranchePopped(tranche);
    }

    /* ///////////////////////////////////////////////////////////////
                    TREASURY FEE CONFIGURATION
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Changes the interest and liquidation weight of the Treasury.
     * @param interestWeight_ The new interestWeight of the treasury.
     * @param liquidationWeight The new liquidationWeight of the treasury.
     * @dev The interestWeight determines the relative share of the yield (interest payments) that goes to the protocol treasury.
     * @dev Setting interestWeightTreasury to a very high value will cause the treasury to collect all interest fees from that moment on.
     * Although this will affect the future profits of liquidity providers, no funds nor realized interest are at risk for LPs.
     */
    function setTreasuryWeights(uint16 interestWeight_, uint16 liquidationWeight) external onlyOwner processInterests {
        totalInterestWeight = totalInterestWeight - interestWeightTreasury + interestWeight_;

        emit TreasuryWeightsUpdated(
            interestWeightTreasury = interestWeight_, liquidationWeightTreasury = liquidationWeight
        );
    }

    /**
     * @notice Sets new treasury address.
     * @param treasury_ The new address of the treasury.
     */
    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    /**
     * @notice Sets the new origination fee.
     * @param originationFee_ The new origination fee.
     * @dev originationFee is limited by being a uint8 -> max value is 2.55%
     * 4 decimal precision (10 = 0.1%).
     */
    function setOriginationFee(uint8 originationFee_) external onlyOwner {
        originationFee = originationFee_;
    }

    /* //////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Deposit assets in the Lending Pool.
     * @param assets The amount of assets of the underlying ERC20 tokens being deposited.
     * @param from The address of the Liquidity Provider who deposits the underlying ERC20 token via a Tranche.
     * @dev This function can only be called by Tranches.
     */
    function depositInLendingPool(uint256 assets, address from)
        external
        whenDepositNotPaused
        onlyTranche
        processInterests
    {
        // Need to transfer before minting or ERC777s could reenter.
        // Address(this) is trusted -> no risk on re-entrancy attack after transfer.
        asset.safeTransferFrom(from, address(this), assets);

        unchecked {
            realisedLiquidityOf[msg.sender] += assets;
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(assets + totalRealisedLiquidity);
        }
    }

    /**
     * @notice Donate assets to the Lending Pool.
     * @param trancheIndex The index of the tranche to donate to.
     * @param assets The amount of assets of the underlying ERC20 tokens being deposited.
     * @dev Can be used by anyone to donate assets to the Lending Pool.
     * It is supposed to serve as a way to compensate the jrTranche after an
     * auction didn't get sold and was manually liquidated after cutoffTime.
     * @dev Inflation attacks by the first depositor in the Tranches have to be prevented with virtual assets/shares.
     */
    function donateToTranche(uint256 trancheIndex, uint256 assets) external whenDepositNotPaused processInterests {
        if (assets == 0) revert LendingPoolErrors.ZeroAmount();

        address tranche = tranches[trancheIndex];

        // Need to transfer before donating or ERC777s could reenter.
        // Address(this) is trusted -> no risk on re-entrancy attack after transfer.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        unchecked {
            realisedLiquidityOf[tranche] += assets; //[̲̅$̲̅(̲̅ ͡° ͜ʖ ͡°̲̅)̲̅$̲̅]
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(assets + totalRealisedLiquidity);
        }
    }

    /**
     * @notice Withdraw assets from the Lending Pool.
     * @param assets The amount of assets of the underlying ERC20 tokens being withdrawn.
     * @param receiver The address of the receiver of the underlying ERC20 tokens.
     * @dev This function can be called by anyone with an open balance (realisedLiquidityOf[address] bigger than 0),
     * which can be both Tranches as other address (treasury, Liquidation Initiators, Liquidated Account Owner...).
     */
    function withdrawFromLendingPool(uint256 assets, address receiver)
        external
        whenWithdrawNotPaused
        processInterests
    {
        if (realisedLiquidityOf[msg.sender] < assets) revert LendingPoolErrors.AmountExceedsBalance();

        unchecked {
            realisedLiquidityOf[msg.sender] -= assets;
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(totalRealisedLiquidity - assets);
        }

        asset.safeTransfer(receiver, assets);
    }

    /* //////////////////////////////////////////////////////////////
                            LENDING LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Approve a beneficiary to take out debt against an Arcadia Account.
     * @param beneficiary The address of the beneficiary who can take out debt backed by an Arcadia Account.
     * @param amount The amount of underlying ERC20 tokens to be lent out.
     * @param account The address of the Arcadia Account backing the debt.
     */
    function approveBeneficiary(address beneficiary, uint256 amount, address account) external {
        // If Account is not an actual address of an Arcadia Account, ownerOfAccount(address) will return the zero address.
        if (IFactory(ACCOUNT_FACTORY).ownerOfAccount(account) != msg.sender) revert LendingPoolErrors.Unauthorized();

        creditAllowance[account][msg.sender][beneficiary] = amount;

        emit CreditApproval(account, msg.sender, beneficiary, amount);
    }

    /**
     * @notice Takes out debt backed by collateral in an Arcadia Account.
     * @param amount The amount of underlying ERC20 tokens to be lent out.
     * @param account The address of the Arcadia Account backing the debt.
     * @param to The address who receives the lent out underlying tokens.
     * @param referrer A unique identifier of the referrer, who will receive part of the fees generated by this transaction.
     * @dev The sender might be different than the owner if they have the proper allowances.
     */
    function borrow(uint256 amount, address account, address to, bytes3 referrer)
        external
        whenBorrowNotPaused
        processInterests
    {
        // If Account is not an actual address of an Account, ownerOfAccount(address) will return the zero address.
        address accountOwner = IFactory(ACCOUNT_FACTORY).ownerOfAccount(account);
        if (accountOwner == address(0)) revert LendingPoolErrors.IsNotAnAccount();

        uint256 amountWithFee = amount + amount.mulDivUp(originationFee, ONE_4);

        // Check allowances to take debt.
        if (accountOwner != msg.sender) {
            uint256 allowed = creditAllowance[account][accountOwner][msg.sender];
            if (allowed != type(uint256).max) {
                creditAllowance[account][accountOwner][msg.sender] = allowed - amountWithFee;
            }
        }

        // Mint debt tokens to the Account.
        _deposit(amountWithFee, account);

        // Add origination fee to the treasury.
        unchecked {
            if (amountWithFee - amount > 0) {
                totalRealisedLiquidity = SafeCastLib.safeCastTo128(amountWithFee + totalRealisedLiquidity - amount);
                realisedLiquidityOf[treasury] += amountWithFee - amount;
            }
        }

        // UpdateOpenPosition checks that the Account indeed has opened a margin account for this Lending Pool and
        // checks that it is still healthy after the debt is increased with amountWithFee.
        // Reverts in Account if one of the checks fails.
        uint256 accountVersion = IAccount(account).increaseOpenPosition(maxWithdraw(account));
        if (!isValidVersion[accountVersion]) revert LendingPoolErrors.InvalidVersion();

        // Transfer fails if there is insufficient liquidity in the pool.
        asset.safeTransfer(to, amount);

        emit Borrow(account, msg.sender, to, amount, amountWithFee - amount, referrer);
    }

    /**
     * @notice Repays debt.
     * @param amount The amount of underlying ERC20 tokens to be repaid.
     * @param account The contract address of the Arcadia Account backing the debt.
     * @dev if Account is not an actual address of an Arcadia Account, maxWithdraw(account) will always return 0.
     * Function will not revert, but amount is always 0.
     * @dev Anyone (EOAs and contracts) can repay debt in the name of an Account.
     */
    function repay(uint256 amount, address account) external whenRepayNotPaused processInterests {
        uint256 accountDebt = maxWithdraw(account);
        amount = accountDebt > amount ? amount : accountDebt;

        // Need to transfer before burning debt or ERC777s could reenter.
        // Address(this) is trusted -> no risk on re-entrancy attack after transfer.
        asset.safeTransferFrom(msg.sender, address(this), amount);

        _withdraw(amount, address(this), account);

        emit Repay(account, msg.sender, amount);
    }

    /**
     * @notice Repays debt via an auction.
     * @param startDebt The amount of debt of the Account the moment the liquidation was initiated.
     * @param minimumMargin_ The minimum margin of the Account.
     * @param amount The amount repaid by a bidder during the auction.
     * @param account The contract address of the Arcadia Account backing the debt.
     * @param bidder The address of the bidder.
     * @return earlyTerminate Bool indicating whether the full amount of debt was repaid.
     * @dev This function allows a liquidator to repay a specified amount of debt for a user.
     */
    function auctionRepay(uint256 startDebt, uint256 minimumMargin_, uint256 amount, address account, address bidder)
        external
        whenLiquidationNotPaused
        onlyLiquidator
        processInterests
        returns (bool earlyTerminate)
    {
        // Need to transfer before burning debt or ERC777s could reenter.
        // Address(this) is trusted -> no risk on re-entrancy attack after transfer.
        asset.safeTransferFrom(bidder, address(this), amount);

        uint256 accountDebt = maxWithdraw(account);
        if (accountDebt == 0) revert LendingPoolErrors.IsNotAnAccountWithDebt();
        if (accountDebt <= amount) {
            // The amount recovered by selling assets during the auction is bigger than the total debt of the Account.
            // -> Terminate the auction and make the surplus available to the Account-Owner.
            earlyTerminate = true;
            unchecked {
                _settleLiquidationHappyFlow(account, startDebt, minimumMargin_, bidder, (amount - accountDebt));
            }
            amount = accountDebt;
        }

        _withdraw(amount, address(this), account);

        emit Repay(account, bidder, amount);
    }

    /* //////////////////////////////////////////////////////////////
                        LEVERAGED ACTIONS LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Execute and interact with external logic on leverage.
     * @param amountBorrowed The amount of underlying ERC20 tokens to be lent out.
     * @param account The address of the Arcadia Account backing the debt.
     * @param actionTarget The address of the Action Target to call.
     * @param actionData A bytes object containing three actionAssetData structs, an address array and a bytes array.
     * @param referrer A unique identifier of the referrer, who will receive part of the fees generated by this transaction.
     * @dev The sender might be different than the owner if they have the proper allowances.
     * @dev accountManagementAction() works similar to flash loans, this function optimistically calls external logic and checks for the Account state at the very end.
     */
    function flashAction(
        uint256 amountBorrowed,
        address account,
        address actionTarget,
        bytes calldata actionData,
        bytes3 referrer
    ) external whenBorrowNotPaused processInterests {
        // If Account is not an actual address of a Account, ownerOfAccount(address) will return the zero address.
        address accountOwner = IFactory(ACCOUNT_FACTORY).ownerOfAccount(account);
        if (accountOwner == address(0)) revert LendingPoolErrors.IsNotAnAccount();

        uint256 amountBorrowedWithFee = amountBorrowed + amountBorrowed.mulDivUp(originationFee, ONE_4);

        // Check allowances to take debt.
        if (accountOwner != msg.sender) {
            // Since calling accountManagementAction() gives the sender full control over all assets in the Account,
            // Only Beneficiaries with maximum allowance can call the flashAction function.
            if (creditAllowance[account][accountOwner][msg.sender] != type(uint256).max) {
                revert LendingPoolErrors.Unauthorized();
            }
        }

        // Mint debt tokens to the Account, debt must be minted before the actions in the Account are performed.
        _deposit(amountBorrowedWithFee, account);

        // Add origination fee to the treasury.
        unchecked {
            if (amountBorrowedWithFee - amountBorrowed > 0) {
                totalRealisedLiquidity += SafeCastLib.safeCastTo128(amountBorrowedWithFee - amountBorrowed);
                realisedLiquidityOf[treasury] += amountBorrowedWithFee - amountBorrowed;
            }
        }

        // Need to update the actionTimestamp before transferring tokens,
        // or ERC777s could reenter to frontrun Account transfers.
        IAccount(account).updateActionTimestampByCreditor();

        // Send Borrowed funds to the actionTarget.
        asset.safeTransfer(actionTarget, amountBorrowed);

        // The Action Target will use the borrowed funds (optionally with additional assets withdrawn from the Account)
        // to execute one or more actions (swap, deposit, mint...).
        // Next the action Target will deposit any of the remaining funds or any of the recipient token
        // resulting from the actions back into the Account.
        // As last step, after all assets are deposited back into the Account a final health check is done:
        // The Collateral Value of all assets in the Account is bigger than the total liabilities against the Account (including the debt taken during this function).
        // flashActionByCreditor also checks that the Account indeed has opened a margin account for this Lending Pool.
        {
            uint256 accountVersion = IAccount(account).flashActionByCreditor(actionTarget, actionData);
            if (!isValidVersion[accountVersion]) revert LendingPoolErrors.InvalidVersion();
        }

        unchecked {
            emit Borrow(
                account, msg.sender, actionTarget, amountBorrowed, amountBorrowedWithFee - amountBorrowed, referrer
            );
        }
    }

    /* //////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Returns the total amount of outstanding debt in the underlying asset.
     * @return totalDebt The total debt in underlying assets.
     */
    function totalAssets() public view override returns (uint256 totalDebt) {
        // Avoid a second calculation of unrealised debt (expensive)
        // if interests are already synced this block.
        if (lastSyncedTimestamp != uint32(block.timestamp)) {
            totalDebt = realisedDebt + calcUnrealisedDebt();
        } else {
            totalDebt = realisedDebt;
        }
    }

    /**
     * @notice Returns the total redeemable amount of liquidity in the underlying asset.
     * @return totalLiquidity_ The total redeemable amount of liquidity in the underlying asset.
     */
    function totalLiquidity() external view returns (uint256 totalLiquidity_) {
        // Avoid a second calculation of unrealised debt (expensive)
        // if interests are already synced this block.
        if (lastSyncedTimestamp != uint32(block.timestamp)) {
            // The total liquidity equals the sum of the realised liquidity, and the pending interests.
            unchecked {
                totalLiquidity_ = totalRealisedLiquidity + calcUnrealisedDebt();
            }
        } else {
            totalLiquidity_ = totalRealisedLiquidity;
        }
    }

    /**
     * @notice Returns the redeemable amount of liquidity in the underlying asset of an address.
     * @param owner_ The address of the liquidity provider.
     * @return assets The redeemable amount of liquidity in the underlying asset.
     * @dev This function syncs the interests to prevent calculating UnrealisedDebt twice when depositing/withdrawing through the Tranches.
     * @dev After calling this function, the interest rate will not be updated until the next processInterests() call.
     */
    function liquidityOfAndSync(address owner_) external returns (uint256 assets) {
        _syncInterests();
        assets = realisedLiquidityOf[owner_];
    }

    /**
     * @notice Returns the redeemable amount of liquidity in the underlying asset of an address.
     * @param owner_ The address of the liquidity provider.
     * @return assets The redeemable amount of liquidity in the underlying asset.
     */
    function liquidityOf(address owner_) external view returns (uint256 assets) {
        // Avoid a second calculation of unrealised debt (expensive).
        // if interests are already synced this block.
        if (lastSyncedTimestamp != uint32(block.timestamp)) {
            // The total liquidity of a tranche equals the sum of the realised liquidity
            // of the tranche, and its pending interests.
            uint256 interest = calcUnrealisedDebt().mulDivDown(interestWeight[owner_], totalInterestWeight);
            unchecked {
                assets = realisedLiquidityOf[owner_] + interest;
            }
        } else {
            assets = realisedLiquidityOf[owner_];
        }
    }

    /**
     * @notice Skims any surplus funds in the LendingPool to the treasury.
     * @dev In normal conditions (when there are no ongoing auctions), the total Claimable Liquidity should be equal
     * to the sum of the available funds (the balanceOf() the underlying asset) in the pool and the total open debt.
     * In practice the actual sum of available funds and total open debt will always be bigger than the total Claimable Liquidity.
     * This because of the rounding errors of the ERC4626 calculations (conversions between assets and shares),
     * or because someone accidentally sent funds directly to the pool instead of depositing via a Tranche.
     * This functions makes the surplus available to the Treasury (otherwise they would be lost forever).
     * @dev In case you accidentally sent funds to the pool, contact the current treasury manager.
     */
    function skim() external processInterests {
        // During auction initiation, debt tokens representing the liquidation incentives are minted at start of the auction
        // yet not accounted for in the totalRealisedLiquidity.
        // -> skim function must be blocked during auctions.
        if (auctionsInProgress != 0) revert LendingPoolErrors.AuctionOngoing();

        // Pending interests are synced via the processInterests modifier.
        uint256 delta = asset.balanceOf(address(this)) + realisedDebt - totalRealisedLiquidity;

        // Add difference to the treasury.
        unchecked {
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(delta + totalRealisedLiquidity);
            realisedLiquidityOf[treasury] += delta;
        }
    }

    /* //////////////////////////////////////////////////////////////
                            INTERESTS LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Syncs all unrealised debt (= interest for LP and treasury).
     * @dev Calculates the unrealised debt since last sync, and realises it by minting an equal amount of
     * debt tokens to all debt holders and interests to LPs and the treasury.
     */
    function _syncInterests() internal {
        // Only Sync interests once per block.
        if (lastSyncedTimestamp != uint32(block.timestamp)) {
            uint256 unrealisedDebt = calcUnrealisedDebt();
            lastSyncedTimestamp = uint32(block.timestamp);

            // Sync interests for borrowers.
            unchecked {
                realisedDebt += unrealisedDebt;
            }

            // Sync interests for LPs and Protocol Treasury.
            _syncInterestsToLiquidityProviders(unrealisedDebt);

            emit InterestSynced(unrealisedDebt);
        }
    }

    /**
     * @notice Calculates the unrealised debt (interests).
     * @return unrealisedDebt The unrealised debt.
     * @dev To calculate the unrealised debt over an amount of time, you need to calculate D[(1+r)^x-1].
     * The base of the exponential: 1 + r, is a 18 decimals fixed point number
     * with r the yearly interest rate.
     * The exponent of the exponential: x, is a 18 decimals fixed point number.
     * The exponent x is calculated as: the amount of seconds passed since last sync timestamp divided by
     * the average of seconds per year.
     */
    function calcUnrealisedDebt() public view returns (uint256 unrealisedDebt) {
        unchecked {
            //gas: Can't overflow for reasonable interest rates.
            uint256 base = 1e18 + interestRate;

            // gas: Only overflows when (block.timestamp - lastSyncedBlockTimestamp) > 1e59
            // in practice: exponent in LogExpMath lib is limited to 130e18,
            // Corresponding to a delta of timestamps of 4099680000 (or 130 years),
            // much bigger than any realistic time difference between two syncs.
            uint256 exponent = ((block.timestamp - lastSyncedTimestamp) * 1e18) / YEARLY_SECONDS;

            // gas: Taking an imaginary worst-case scenario with max interest of 1000%
            // over a period of 5 years.
            // This won't overflow as long as openDebt < 3402823669209384912995114146594816
            // which is 3.4 million billion *10**18 decimals.
            unrealisedDebt = (realisedDebt * (LogExpMath.pow(base, exponent) - 1e18)) / 1e18;
        }

        return SafeCastLib.safeCastTo128(unrealisedDebt);
    }

    /**
     * @notice Syncs interest payments to the liquidity providers and the treasury.
     * @param assets The total amount of underlying assets to be paid out as interests.
     * @dev The interest weight of each Tranche determines the relative share of yield (interest payments)
     * that goes to its liquidity providers.
     * @dev If the total interest weight is 0, all interests will go to the treasury.
     */
    function _syncInterestsToLiquidityProviders(uint256 assets) internal {
        uint256 remainingAssets = assets;

        uint256 totalInterestWeight_ = totalInterestWeight;
        if (totalInterestWeight_ > 0) {
            uint256 realisedLiquidity;
            uint256 trancheShare;
            uint256 trancheLength = tranches.length;
            for (uint256 i; i < trancheLength; ++i) {
                realisedLiquidity = realisedLiquidityOf[tranches[i]];
                // Don't pay interests to Tranches without liquidity.
                // Interests will go to treasury instead.
                if (realisedLiquidity == 0) continue;
                trancheShare = assets.mulDivDown(interestWeightTranches[i], totalInterestWeight_);
                unchecked {
                    realisedLiquidityOf[tranches[i]] = realisedLiquidity + trancheShare;
                    remainingAssets -= trancheShare;
                }
            }
        }
        unchecked {
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(totalRealisedLiquidity + assets);

            // Add the remainingAssets to the treasury balance.
            realisedLiquidityOf[treasury] += remainingAssets;
        }
    }

    /* //////////////////////////////////////////////////////////////
                        INTEREST RATE LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Sets the interest configuration parameters.
     * @param baseRatePerYear_ The base interest rate per year.
     * @param lowSlopePerYear_ The slope of the interest rate per year when the utilization rate is below the utilization threshold.
     * @param highSlopePerYear_ The slope of the interest rate per year when the utilization rate exceeds the utilization threshold.
     * @param utilisationThreshold_ The utilization threshold for determining the interest rate slope change.
     * @dev We cannot use a struct to store all variables, since this would cause the contract size to exceed the maximum size.
     */
    function setInterestParameters(
        uint72 baseRatePerYear_,
        uint72 lowSlopePerYear_,
        uint72 highSlopePerYear_,
        uint16 utilisationThreshold_
    ) external processInterests onlyOwner {
        baseRatePerYear = baseRatePerYear_;
        lowSlopePerYear = lowSlopePerYear_;
        highSlopePerYear = highSlopePerYear_;
        utilisationThreshold = utilisationThreshold_;
    }

    /**
     * @notice Updates the interest rate.
     * @dev Any address can call this, it will sync unrealised interests and update the interest rate.
     */
    function updateInterestRate() external processInterests { }

    /**
     * @notice Updates the interest rate.
     * @param totalDebt Total amount of debt.
     * @param totalLiquidity_ Total amount of Liquidity (sum of borrowed out assets and assets still available in the Lending Pool).
     */
    function _updateInterestRate(uint256 totalDebt, uint256 totalLiquidity_) internal {
        uint256 utilisation; // 4 decimals precision
        unchecked {
            // This doesn't overflow since totalDebt is a uint128: uint128 * 10_000 < type(uint256).max.
            if (totalLiquidity_ > 0) utilisation = totalDebt * ONE_4 / totalLiquidity_;
        }

        emit PoolStateUpdated(totalDebt, totalLiquidity_, interestRate = _calculateInterestRate(utilisation));
    }

    /**
     * @notice Calculates the interest rate.
     * @param utilisation Utilisation rate, 4 decimal precision.
     * @return interestRate_ The current interest rate, 18 decimal precision.
     * @dev The interest rate is a function of the utilisation of the Lending Pool.
     * We use two linear curves: one below the optimal utilisation with low slope and a steep one above.
     */
    function _calculateInterestRate(uint256 utilisation) internal view returns (uint80 interestRate_) {
        // While repays are paused, interest rate is set to 0.
        if (repayPaused) return 0;

        unchecked {
            if (utilisation >= utilisationThreshold) {
                // lsIR (1e22) = uT (1e4) * ls (1e18).
                uint256 lowSlopeInterest = uint256(utilisationThreshold) * lowSlopePerYear;
                // hsIR (1e22) = (u - uT) (1e4) * hs (e18).
                uint256 highSlopeInterest = uint256(utilisation - utilisationThreshold) * highSlopePerYear;
                // i (1e18) =  (lsIR (e22) + hsIR (1e22)) / 1e4 + bs (1e18).
                interestRate_ = uint80((lowSlopeInterest + highSlopeInterest) / ONE_4 + baseRatePerYear);
            } else {
                // i (1e18) = (u (1e4) * ls (1e18)) / 1e4 + br (1e18).
                interestRate_ = uint80(utilisation * lowSlopePerYear / ONE_4 + baseRatePerYear);
            }
        }
    }

    /* //////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Initiates the liquidation process for an Account.
     * @param initiator The address of the liquidation initiator.
     * @param minimumMargin_ The minimum margin of the Account.
     * @return startDebt The initial debt of the liquidated Account.
     * @dev This function is only callable by an Arcadia Account with debt.
     * The liquidation process involves assessing the Account's debt and calculating liquidation incentives,
     * which are considered as extra debt.
     * The extra debt is then minted towards the Account to encourage the liquidation process and bring the Account to a healthy state.
     * @dev Only Accounts with non-zero balances can have debt, and debtTokens are non-transferrable.
     * @dev If the provided Account has a debt balance of 0, the function reverts with the error "IsNotAnAccountWithDebt."
     */
    function startLiquidation(address initiator, uint256 minimumMargin_)
        external
        override
        whenLiquidationNotPaused
        processInterests
        returns (uint256 startDebt)
    {
        // Only Accounts can have debt, and debtTokens are non-transferrable.
        // Hence by checking that the balance of the msg.sender is not 0,
        // we know that the sender is indeed an Account and has debt.
        startDebt = maxWithdraw(msg.sender);
        if (startDebt == 0) revert LendingPoolErrors.IsNotAnAccountWithDebt();

        // Calculate liquidation incentives which have to be paid by the Account owner and are minted
        // as extra debt to the Account.
        (uint256 initiationReward, uint256 terminationReward, uint256 liquidationPenalty) =
            _calculateRewards(startDebt, minimumMargin_);

        // Mint the liquidation incentives as extra debt towards the Account.
        _deposit(initiationReward + liquidationPenalty + terminationReward, msg.sender);

        // Increase the realised liquidity for the initiator.
        // The other incentives will only be added as realised liquidity for the respective actors
        // after the auction is finished.
        realisedLiquidityOf[initiator] += initiationReward;
        totalRealisedLiquidity = SafeCastLib.safeCastTo128(totalRealisedLiquidity + initiationReward);

        // If this is the sole ongoing auction, prevent any deposits and withdrawals in the most jr tranche
        if (auctionsInProgress == 0 && tranches.length > 0) {
            unchecked {
                ITranche(tranches[tranches.length - 1]).setAuctionInProgress(true);
            }
        }

        unchecked {
            ++auctionsInProgress;
        }

        // Emit event
        emit AuctionStarted(msg.sender, address(this), uint128(startDebt));
    }

    /**
     * @notice Ends the liquidation process for a specific Account and settles the liquidation incentives.
     * @param account The address of the Account undergoing liquidation settlement.
     * @param startDebt The initial debt amount of the liquidated Account.
     * @param minimumMargin_ The minimum margin of the Account.
     * @param terminator The address of the liquidation terminator.
     * @dev In the happy flow, the auction proceeds are sufficient to pay off enough debt
     *  to bring the Account in a healthy position, and pay out all liquidation incentives to the
     *  relevant actors.
     */
    function settleLiquidationHappyFlow(address account, uint256 startDebt, uint256 minimumMargin_, address terminator)
        external
        whenLiquidationNotPaused
        onlyLiquidator
        processInterests
    {
        _settleLiquidationHappyFlow(account, startDebt, minimumMargin_, terminator, 0);
    }

    /**
     * @notice Ends the liquidation process for a specific Account and settles the liquidation incentives.
     * @param account The address of the Account undergoing liquidation settlement.
     * @param startDebt The initial debt amount of the liquidated Account.
     * @param minimumMargin_ The minimum margin of the Account.
     * @param terminator The address of the liquidation terminator.
     * @param surplus The surplus amount obtained from the liquidation process.
     * @dev In the happy flow, the auction proceeds are sufficient to pay off enough debt
     *  to bring the Account in a healthy position, and pay out all liquidation incentives to the
     *  relevant actors.
     * @dev The following pending incentives are made claimable:
     *   - The "terminationReward", going towards the terminator of the auction.
     *   - The "liquidationFee", going towards LPs and the Treasury.
     *   - If there are still remaining assets after paying off all debt and incentives,
     *   the surplus goes towards the owner of the account.
     */
    function _settleLiquidationHappyFlow(
        address account,
        uint256 startDebt,
        uint256 minimumMargin_,
        address terminator,
        uint256 surplus
    ) internal {
        (uint256 initiationReward, uint256 terminationReward, uint256 liquidationPenalty) =
            _calculateRewards(startDebt, minimumMargin_);

        // Pay out the "liquidationPenalty" to the most Junior Tranche and Treasury.
        _syncLiquidationFee(liquidationPenalty);

        totalRealisedLiquidity =
            SafeCastLib.safeCastTo128(totalRealisedLiquidity + terminationReward + liquidationPenalty + surplus);

        unchecked {
            // Pay out any surplus to the current Account Owner.
            if (surplus > 0) realisedLiquidityOf[IAccount(account).owner()] += surplus;
            // Pay out the "terminationReward" to the "terminator".
            realisedLiquidityOf[terminator] += terminationReward;
        }

        _endLiquidation();

        emit AuctionFinished(
            account, address(this), startDebt, initiationReward, terminationReward, liquidationPenalty, 0, surplus
        );
    }

    /**
     * @notice Ends the liquidation process for a specific Account and settles the liquidation incentives/bad debt.
     * @param account The address of the Account undergoing liquidation settlement.
     * @param startDebt The initial debt amount of the liquidated Account.
     * @param minimumMargin_ The minimum margin of the Account.
     * @param terminator The address of the auction terminator.
     * @dev In the unhappy flow, the auction proceeds are not sufficient to pay out all liquidation incentives
     *  and maybe not even to pay off all debt.
     * @dev The order in which incentives are not paid out/ bad debt is settled is fixed:
     *   - First, the "liquidationFee", going towards LPs and the Treasury is not paid out.
     *   - Next, the "terminationReward", going towards the terminator of the auction is not paid out.
     *   - Next, the underlying assets of LPs in the most junior Tranche are written off pro rata.
     *   - Next, the underlying assets of LPs in the second most junior Tranche are written off pro rata.
     *   - etc.
     */
    function settleLiquidationUnhappyFlow(
        address account,
        uint256 startDebt,
        uint256 minimumMargin_,
        address terminator
    ) external whenLiquidationNotPaused onlyLiquidator processInterests {
        (uint256 initiationReward, uint256 terminationReward, uint256 liquidationPenalty) =
            _calculateRewards(startDebt, minimumMargin_);

        // Any remaining debt that was not recovered during the auction must be written off.
        // Depending on the size of the remaining debt, different stakeholders will be impacted.
        uint256 debtShares = balanceOf[account];
        uint256 openDebt = convertToAssets(debtShares);
        uint256 badDebt;
        if (openDebt > terminationReward + liquidationPenalty) {
            // "openDebt" is bigger than pending liquidation incentives.
            // No incentives will be paid out, and a default event is triggered.
            unchecked {
                badDebt = openDebt - terminationReward - liquidationPenalty;
            }

            totalRealisedLiquidity = uint128(totalRealisedLiquidity - badDebt);
            _processDefault(badDebt);
        } else {
            uint256 remainder = liquidationPenalty + terminationReward - openDebt;
            if (openDebt >= liquidationPenalty) {
                // "openDebt" is bigger than the "liquidationPenalty" but smaller than the total pending liquidation incentives.
                // Don't pay out the "liquidationPenalty" to Lps, partially pay out the "terminator".
                realisedLiquidityOf[terminator] += remainder;
            } else {
                // "openDebt" is smaller than the "liquidationPenalty".
                // Fully pay out the "terminator" and partially pay out the "liquidationPenalty".
                realisedLiquidityOf[terminator] += terminationReward;
                _syncLiquidationFee(remainder - terminationReward);
            }
            totalRealisedLiquidity = SafeCastLib.safeCastTo128(totalRealisedLiquidity + remainder);
        }

        // Remove the remaining debt from the Account now that it is written off from the liquidation incentives/Liquidity Providers.
        _burn(account, debtShares);
        realisedDebt -= openDebt;
        emit Withdraw(msg.sender, account, account, openDebt, debtShares);

        _endLiquidation();

        emit AuctionFinished(
            account, address(this), startDebt, initiationReward, terminationReward, liquidationPenalty, badDebt, 0
        );
    }

    /**
     * @notice Ends the liquidation.
     * @dev Unlocks the most junior Tranche if there are no other liquidations ongoing.
     */
    function _endLiquidation() internal {
        // Decrement the number of auctions in progress.
        unchecked {
            --auctionsInProgress;
        }

        // Hook to the most junior Tranche.
        if (auctionsInProgress == 0 && tranches.length > 0) {
            unchecked {
                ITranche(tranches[tranches.length - 1]).setAuctionInProgress(false);
            }
        }
    }

    /**
     * @notice Handles the accounting in case of bad debt (Account became undercollateralised).
     * @param badDebt The total amount of underlying assets that need to be written off as bad debt.
     * @dev The order of the Tranches is important, the most senior Tranche is at index 0, the most junior at the last index.
     * @dev The most junior tranche will lose its underlying assets first. If all liquidity of a certain Tranche is written off,
     * the complete tranche is locked and removed. If there is still remaining bad debt, the next Tranche starts losing capital.
     * @dev If all Tranches are written off and there is still remaining badDebt, the accounting of the pool no longer holds
     * (sum of all realisedLiquidityOf() balances is bigger then totalRealisedLiquidity).
     * In this case no new Tranches should be added to restart the LendingPool and any remaining funds should be withdrawn.
     */
    function _processDefault(uint256 badDebt) internal {
        address tranche;
        uint256 maxBurnable;
        uint256 length = tranches.length;
        for (uint256 i = length; i > 0;) {
            unchecked {
                --i;
            }
            tranche = tranches[i];
            maxBurnable = realisedLiquidityOf[tranche];
            if (badDebt < maxBurnable) {
                // Deduct badDebt from the balance of the most junior Tranche.
                unchecked {
                    realisedLiquidityOf[tranche] -= badDebt;
                }
                break;
            } else {
                // Unhappy flow, should never occur in practice!
                // badDebt is bigger than the balance of most junior Tranche -> tranche is completely wiped out
                // and temporarily locked (no new deposits or withdraws possible).
                // DAO or insurance might refund (Part of) the losses, and add Tranche back.
                realisedLiquidityOf[tranche] = 0;
                _popTranche(i, tranche);
                unchecked {
                    badDebt -= maxBurnable;
                }
                ITranche(tranche).lock();
                // Hook to the new most junior Tranche to inform that auctions are ongoing.
                if (i != 0) ITranche(tranches[i - 1]).setAuctionInProgress(true);
            }
        }
    }

    /**
     * @notice Syncs liquidation penalties to the most Junior Tranche and the treasury.
     * @param assets The total amount of underlying assets to be paid out as liquidation fee.
     * @dev The liquidationWeightTranche and liquidationWeightTreasury determines the relative share of yield (liquidation penalties)
     * that goes to the most Junior Tranche and the treasury.
     * @dev If the total liquidation weight is 0, the liquidation fee is added to the treasury.
     */
    function _syncLiquidationFee(uint256 assets) internal {
        // Cache storage variables.
        uint256 length = tranches.length;
        uint256 weightTranche = liquidationWeightTranche;
        uint256 totalWeight;
        unchecked {
            totalWeight = weightTranche + liquidationWeightTreasury;
        }

        // Sync fee to the most Junior Tranche (last index).
        if (totalWeight > 0 && length > 0) {
            uint256 realisedLiquidity = realisedLiquidityOf[tranches[length - 1]];
            // Don't pay fees to a Tranche without liquidity.
            // Interests will go to treasury instead.
            if (realisedLiquidity > 0) {
                uint256 trancheFee = assets.mulDivDown(weightTranche, totalWeight);
                unchecked {
                    realisedLiquidityOf[tranches[length - 1]] = realisedLiquidity + trancheFee;
                    assets -= trancheFee;
                }
            }
        }

        // Add the remaining fee to the treasury balance.
        unchecked {
            realisedLiquidityOf[treasury] += assets;
        }
    }

    /**
     * @notice Calculates the rewards and penalties for the liquidation process based on the given debt amount.
     * @param debt The debt amount of the Account at the time of liquidation initiation.
     * @param minimumMargin_ The minimum margin of the Account.
     * @return initiationReward The reward for the liquidation initiator, capped by the maximum initiator reward.
     * @return terminationReward The reward for closing the liquidation process, capped by the maximum termination reward.
     * @return liquidationPenalty The penalty paid by the Account owner towards the liquidity providers and the protocol treasury.
     * @dev The rewards for the initiator and terminator should at least cover the gas costs.
     * -> minimumMargin should be set big enough such that "minimumMargin * minRewardWeight" can cover any possible gas cost to initiate/terminate the liquidation.
     * @dev Since the initiation/termination costs do not increase with position size, the initiator and terminator rewards can be capped to a maximum value.
     */
    function _calculateRewards(uint256 debt, uint256 minimumMargin_)
        internal
        view
        returns (uint256 initiationReward, uint256 terminationReward, uint256 liquidationPenalty)
    {
        uint256 maxReward_ = maxReward;
        // The minimum reward, for both the initiation- and terminationReward, is defined as a fixed percentage of the minimumMargin.
        uint256 minReward = minimumMargin_.mulDivUp(minRewardWeight, ONE_4);

        // Initiation reward must be between minReward and maxReward.
        initiationReward = debt.mulDivDown(initiationWeight, ONE_4);
        initiationReward = initiationReward > minReward ? initiationReward : minReward;
        initiationReward = initiationReward > maxReward_ ? maxReward_ : initiationReward;

        // Termination reward must be between minReward and maxReward.
        terminationReward = debt.mulDivDown(terminationWeight, ONE_4);
        terminationReward = terminationReward > minReward ? terminationReward : minReward;
        terminationReward = terminationReward > maxReward_ ? maxReward_ : terminationReward;

        liquidationPenalty = debt.mulDivUp(penaltyWeight, ONE_4);
    }

    /*///////////////////////////////////////////////////////////////
                        MANAGE AUCTION SETTINGS
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the liquidation parameters.
     * @param initiationWeight_ Reward paid to the Liquidation Initiator.
     * @param penaltyWeight_ Penalty paid by the Account owner to the Creditor.
     * @param terminationWeight_ Reward paid to the Liquidation closer.
     * @param minRewardWeight_ The minimum reward that is paid to the initiator/terminator of a liquidation.
     * @param maxReward_ The maximum reward that is paid to the initiator/terminator of a liquidation.
     * @dev Each weight has 4 decimals precision (50 equals 0,005 or 0,5%).
     * @dev Each weight sets the % of the debt that is paid as reward to the initiator and terminator of a liquidation.
     * This reward is capped in absolute value by the maxReward respectively maxReward.
     * @dev We cannot use a struct to store all variables, since this would cause the contract size to exceed the maximum size.
     */
    function setLiquidationParameters(
        uint16 initiationWeight_,
        uint16 penaltyWeight_,
        uint16 terminationWeight_,
        uint16 minRewardWeight_,
        uint80 maxReward_
    ) external onlyOwner {
        // When auctions are ongoing, it is not allowed to modify the auction parameters,
        // as that would corrupt the rewards and penalties calculated by _calculateRewards().
        if (auctionsInProgress != 0) revert LendingPoolErrors.AuctionOngoing();

        // Total penalties/rewards, paid by the Account cannot exceed MAX_TOTAL_PENALTY.
        if (uint256(initiationWeight_) + penaltyWeight_ + terminationWeight_ > MAX_TOTAL_PENALTY) {
            revert LendingPoolErrors.LiquidationWeightsTooHigh();
        }

        // Sum of the initiationReward and terminationReward cannot exceed minimumMargin of the Account.
        // -> minRewardWeight is capped to 50%.
        if (minRewardWeight_ > 5000) revert LendingPoolErrors.LiquidationWeightsTooHigh();

        // Store new parameters.
        initiationWeight = initiationWeight_;
        penaltyWeight = penaltyWeight_;
        terminationWeight = terminationWeight_;
        minRewardWeight = minRewardWeight_;
        maxReward = maxReward_;
    }

    /**
     * @notice Sets the minimum amount of collateral that must be held in an Account before a position can be opened.
     * @param minimumMargin_ The new minimumMargin.
     * @dev The minimum margin should be a conservative upper estimate of the maximal gas cost to liquidate a position (fixed cost, independent of openDebt).
     * The minimumMargin prevents dusting attacks, and ensures that upon liquidations positions are big enough to cover
     * network transaction costs while remaining attractive to liquidate.
     */
    function setMinimumMargin(uint96 minimumMargin_) external onlyOwner {
        minimumMargin = minimumMargin_;
    }

    /* //////////////////////////////////////////////////////////////
                            ACCOUNT LOGIC
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Sets a new Risk Manager.
     * @param riskManager_ The address of the new Risk Manager.
     */
    function setRiskManager(address riskManager_) external onlyOwner {
        _setRiskManager(riskManager_);
    }

    /**
     * @notice Enables or disables a certain Account version to be used as margin account.
     * @param accountVersion the Account version to be enabled/disabled.
     * @param valid The validity of the respective accountVersion.
     */
    function setAccountVersion(uint256 accountVersion, bool valid) external onlyOwner {
        _setAccountVersion(accountVersion, valid);
    }

    /**
     * @inheritdoc Creditor
     */
    function openMarginAccount(uint256 accountVersion)
        external
        view
        override
        returns (bool success, address numeraire, address liquidator_, uint256 minimumMargin_)
    {
        if (isValidVersion[accountVersion]) {
            success = true;
            numeraire = address(asset);
            liquidator_ = LIQUIDATOR;
            minimumMargin_ = minimumMargin;
        }
    }

    /**
     * @inheritdoc Creditor
     */
    function closeMarginAccount(address account) external view override {
        if (maxWithdraw(account) != 0) revert LendingPoolErrors.OpenPositionNonZero();
    }

    /**
     * @inheritdoc Creditor
     */
    function getOpenPosition(address account) external view override returns (uint256 openPosition) {
        openPosition = maxWithdraw(account);
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    ////////////////////////////////////////////////////////////// */
    /**
     * @notice Returns the configuration of the interest rate slopes.
     * @return baseRatePerYear The base interest rate per year.
     * @return lowSlopePerYear The slope of the interest rate per year when the utilization rate is below the utilization threshold.
     * @return highSlopePerYear The slope of the interest rate per year when the utilization rate exceeds the utilization threshold.
     * @return utilisationThreshold The utilization threshold for determining the interest rate slope change.
     */
    function getInterestRateConfig() external view returns (uint72, uint72, uint72, uint16) {
        return (baseRatePerYear, lowSlopePerYear, highSlopePerYear, utilisationThreshold);
    }

    /**
     * @notice Returns the liquidation parameters.
     * @return initiationWeight Reward paid to the Liquidation Initiator.
     * @return penaltyWeight Penalty paid by the Account owner to the Creditor.
     * @return terminationWeight Reward paid to the Liquidation closer.
     * @return minRewardWeight The minimum reward that is paid to the initiator/terminator of a liquidation.
     * @return maxReward The maximum reward that is paid to the initiator/terminator of a liquidation.
     */
    function getLiquidationParameters() external view returns (uint16, uint16, uint16, uint16, uint80) {
        return (initiationWeight, penaltyWeight, terminationWeight, minRewardWeight, maxReward);
    }
}
