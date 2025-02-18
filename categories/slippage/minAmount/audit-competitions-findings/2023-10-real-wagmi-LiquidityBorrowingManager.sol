// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./abstract/LiquidityManager.sol";
import "./abstract/OwnerSettings.sol";
import "./abstract/DailyRateAndCollateral.sol";
import "./libraries/ErrLib.sol";

/**
 * @title LiquidityBorrowingManager
 * @dev This contract manages the borrowing liquidity functionality for WAGMI Leverage protocol.
 * It inherits from LiquidityManager, OwnerSettings, DailyRateAndCollateral, and ReentrancyGuard contracts.
 */
contract LiquidityBorrowingManager is
    LiquidityManager,
    OwnerSettings,
    DailyRateAndCollateral,
    ReentrancyGuard
{
    using { Keys.removeKey, Keys.addKeyIfNotExists } for bytes32[];
    using { ErrLib.revertError } for bool;

    /// @title BorrowParams
    /// @notice This struct represents the parameters required for borrowing.
    struct BorrowParams {
        /// @notice The pool fee level for the internal swap
        uint24 internalSwapPoolfee;
        /// @notice The address of the token that will be sold to obtain the loan currency
        address saleToken;
        /// @notice The address of the token that will be held
        address holdToken;
        /// @notice The minimum amount of holdToken that must be obtained
        uint256 minHoldTokenOut;
        /// @notice The maximum amount of collateral that can be provided for the loan
        uint256 maxCollateral;
        /// @notice The SwapParams struct representing the external swap parameters
        SwapParams externalSwap;
        /// @notice An array of LoanInfo structs representing multiple loans
        LoanInfo[] loans;
    }
    /// @title BorrowingInfo
    /// @notice This struct represents the borrowing information for a borrower.
    struct BorrowingInfo {
        address borrower;
        address saleToken;
        address holdToken;
        /// @notice The amount of fees owed by the creditor
        uint256 feesOwed;
        /// @notice The amount borrowed by the borrower
        uint256 borrowedAmount;
        /// @notice The amount of liquidation bonus
        uint256 liquidationBonus;
        /// @notice The accumulated loan rate per share
        uint256 accLoanRatePerSeconds;
        /// @notice The daily rate collateral balance multiplied by COLLATERAL_BALANCE_PRECISION
        uint256 dailyRateCollateralBalance;
    }
    /// @notice This struct used for caching variables inside a function 'borrow'
    struct BorrowCache {
        uint256 dailyRateCollateral;
        uint256 accLoanRatePerSeconds;
        uint256 borrowedAmount;
        uint256 holdTokenBalance;
    }
    /// @notice Struct representing the extended borrowing information.
    struct BorrowingInfoExt {
        /// @notice The main borrowing information.
        BorrowingInfo info;
        /// @notice An array of LoanInfo structs representing multiple loans
        LoanInfo[] loans;
        /// @notice The balance of the collateral.
        int256 collateralBalance;
        /// @notice The estimated lifetime of the loan.
        uint256 estimatedLifeTime;
        /// borrowing Key
        bytes32 key;
    }

    /// @title RepayParams
    /// @notice This struct represents the parameters required for repaying a loan.
    struct RepayParams {
        /// @notice The activation of the emergency liquidity restoration mode (available only to the lender)
        bool isEmergency;
        /// @notice The pool fee level for the internal swap
        uint24 internalSwapPoolfee;
        /// @notice The external swap parameters for the repayment transaction
        SwapParams externalSwap;
        /// @notice The unique borrowing key associated with the loan
        bytes32 borrowingKey;
        /// @notice The slippage allowance for the swap in basis points (1/10th of a percent)
        uint256 swapSlippageBP1000;
    }
    /// borrowingKey=>LoanInfo
    mapping(bytes32 => LoanInfo[]) public loansInfo;
    /// borrowingKey=>BorrowingInfo
    mapping(bytes32 => BorrowingInfo) public borrowingsInfo;
    /// borrower => BorrowingKeys[]
    mapping(address => bytes32[]) public userBorrowingKeys;
    /// NonfungiblePositionManager tokenId => BorrowingKeys[]
    mapping(uint256 => bytes32[]) public tokenIdToBorrowingKeys;

    ///  token => FeesAmt
    mapping(address => uint256) private platformsFeesInfo;

    /// Indicates that a borrower has made a new loan
    event Borrow(
        address borrower,
        bytes32 borrowingKey,
        uint256 borrowedAmount,
        uint256 borrowingCollateral,
        uint256 liquidationBonus,
        uint256 dailyRatePrepayment
    );
    /// Indicates that a borrower has repaid their loan, optionally with the help of a liquidator
    event Repay(address borrower, address liquidator, bytes32 borrowingKey);
    /// Indicates that a loan has been closed due to an emergency situation
    event EmergencyLoanClosure(address borrower, address lender, bytes32 borrowingKey);
    /// Indicates that the protocol has collected fee tokens
    event CollectProtocol(address recipient, address[] tokens, uint256[] amounts);
    /// Indicates that the daily interest rate for holding token(for specific pair) has been updated
    event UpdateHoldTokenDailyRate(address saleToken, address holdToken, uint256 value);
    /// Indicates that a borrower has increased their collateral balance for a loan
    event IncreaseCollateralBalance(address borrower, bytes32 borrowingKey, uint256 collateralAmt);
    /// Indicates that a new borrower has taken over the debt from an old borrower
    event TakeOverDebt(
        address oldBorrower,
        address newBorrower,
        bytes32 oldBorrowingKey,
        bytes32 newBorrowingKey
    );

    error TooLittleReceivedError(uint256 minOut, uint256 out);

    /// @dev Modifier to check if the current block timestamp is before or equal to the deadline.
    modifier checkDeadline(uint256 deadline) {
        (_blockTimestamp() > deadline).revertError(ErrLib.ErrorCode.TOO_OLD_TRANSACTION);
        _;
    }

    function _blockTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    constructor(
        address _underlyingPositionManagerAddress,
        address _underlyingQuoterV2,
        address _underlyingV3Factory,
        bytes32 _underlyingV3PoolInitCodeHash
    )
        LiquidityManager(
            _underlyingPositionManagerAddress,
            _underlyingQuoterV2,
            _underlyingV3Factory,
            _underlyingV3PoolInitCodeHash
        )
    {}

    /**
     * @dev Adds or removes a swap call params to the whitelist.
     * @param swapTarget The address of the target contract for the swap call.
     * @param funcSelector The function selector of the swap call.
     * @param isAllowed A boolean indicating whether the swap call is allowed or not.
     */
    function setSwapCallToWhitelist(
        address swapTarget,
        bytes4 funcSelector,
        bool isAllowed
    ) external onlyOwner {
        (swapTarget == VAULT_ADDRESS ||
            swapTarget == address(this) ||
            swapTarget == address(underlyingPositionManager) ||
            funcSelector == IERC20.transferFrom.selector).revertError(ErrLib.ErrorCode.FORBIDDEN);
        whitelistedCall[swapTarget][funcSelector] = isAllowed;
    }

    /**
     * @notice This function allows the owner to collect protocol fees for multiple tokens
     * and transfer them to a specified recipient.
     * @dev Only the contract owner can call this function.
     * @param recipient The address of the recipient who will receive the collected fees.
     * @param tokens An array of addresses representing the tokens for which fees will be collected.
     */
    function collectProtocol(address recipient, address[] calldata tokens) external onlyOwner {
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ) {
            address token = tokens[i];
            uint256 amount = platformsFeesInfo[token] / Constants.COLLATERAL_BALANCE_PRECISION;
            if (amount > 0) {
                platformsFeesInfo[token] = 0;
                amounts[i] = amount;
                Vault(VAULT_ADDRESS).transferToken(token, recipient, amount);
            }
            unchecked {
                ++i;
            }
        }

        emit CollectProtocol(recipient, tokens, amounts);
    }

    /**
     * @notice This function is used to update the daily rate for holding token for specific pair.
     * @dev Only the daily rate operator can call this function.
     * @param saleToken The address of the sale token.
     * @param holdToken The address of the hold token.
     * @param value The new value of the daily rate for the hold token will be calculated based
     * on the volatility of the pair and the popularity of loans in it
     * @dev The value must be within the range of MIN_DAILY_RATE and MAX_DAILY_RATE.
     */
    function updateHoldTokenDailyRate(
        address saleToken,
        address holdToken,
        uint256 value
    ) external {
        (msg.sender != dailyRateOperator).revertError(ErrLib.ErrorCode.INVALID_CALLER);
        if (value > Constants.MAX_DAILY_RATE || value < Constants.MIN_DAILY_RATE) {
            revert InvalidSettingsValue(value);
        }
        // If the value is within the acceptable range, the function updates the currentDailyRate property
        // of the holdTokenRateInfo structure associated with the token pair.
        (, TokenInfo storage holdTokenRateInfo) = _updateTokenRateInfo(saleToken, holdToken);
        holdTokenRateInfo.currentDailyRate = value;
        emit UpdateHoldTokenDailyRate(saleToken, holdToken, value);
    }

    /**
     * @notice This function is used to check the daily rate collateral for a specific borrowing.
     * @param borrowingKey The key of the borrowing.
     * @return balance The balance of the daily rate collateral.
     * @return estimatedLifeTime The estimated lifetime of the collateral in seconds.
     */
    function checkDailyRateCollateral(
        bytes32 borrowingKey
    ) external view returns (int256 balance, uint256 estimatedLifeTime) {
        (, balance, estimatedLifeTime) = _getDebtInfo(borrowingKey);
        balance /= int256(Constants.COLLATERAL_BALANCE_PRECISION);
    }

    /**
     * @notice Get information about loans associated with a borrowing key
     * @dev This function retrieves an array of loan information for a given borrowing key.
     * The loans are stored in the loansInfo mapping, which is a mapping of borrowing keys to LoanInfo arrays.
     * @param borrowingKey The unique key associated with the borrowing
     * @return loans An array containing LoanInfo structs representing the loans associated with the borrowing key
     */
    function getLoansInfo(bytes32 borrowingKey) external view returns (LoanInfo[] memory loans) {
        loans = loansInfo[borrowingKey];
    }

    /**
     * @notice Retrieves the borrowing information for a specific NonfungiblePositionManager tokenId.
     * @param tokenId The unique identifier of the PositionManager token.
     * @return extinfo An array of BorrowingInfoExt structs representing the borrowing information.
     */
    function getLenderCreditsInfo(
        uint256 tokenId
    ) external view returns (BorrowingInfoExt[] memory extinfo) {
        bytes32[] memory borrowingKeys = tokenIdToBorrowingKeys[tokenId];
        extinfo = _getDebtsInfo(borrowingKeys);
    }

    /**
     * @notice Retrieves the debts information for a specific borrower.
     * @param borrower The address of the borrower.
     * @return extinfo An array of BorrowingInfoExt structs representing the borrowing information.
     */
    function getBorrowerDebtsInfo(
        address borrower
    ) external view returns (BorrowingInfoExt[] memory extinfo) {
        bytes32[] memory borrowingKeys = userBorrowingKeys[borrower];
        extinfo = _getDebtsInfo(borrowingKeys);
    }

    /**
     * @dev Returns the number of loans associated with a given NonfungiblePositionManager tokenId.
     * @param tokenId The ID of the token.
     * @return count The total number of loans associated with the tokenId.
     */
    function getLenderCreditsCount(uint256 tokenId) external view returns (uint256 count) {
        bytes32[] memory borrowingKeys = tokenIdToBorrowingKeys[tokenId];
        count = borrowingKeys.length;
    }

    /**
     * @dev Returns the number of borrowings for a given borrower.
     * @param borrower The address of the borrower.
     * @return count The total number of borrowings for the borrower.
     */
    function getBorrowerDebtsCount(address borrower) external view returns (uint256 count) {
        bytes32[] memory borrowingKeys = userBorrowingKeys[borrower];
        count = borrowingKeys.length;
    }

    /**
     * @dev Returns the current daily rate for holding token.
     * @param saleToken The address of the token being sold.
     * @param holdToken The address of the token being held.
     * @return currentDailyRate The current daily rate .
     */
    function getHoldTokenDailyRateInfo(
        address saleToken,
        address holdToken
    ) external view returns (uint256 currentDailyRate, TokenInfo memory holdTokenRateInfo) {
        (currentDailyRate, holdTokenRateInfo) = _getHoldTokenRateInfo(saleToken, holdToken);
    }

    /**
     * @dev Returns the fees information for multiple tokens in an array.
     * @param tokens An array of token addresses for which the fees are to be retrieved.
     * @return fees An array containing the fees for each token.
     */
    function getPlatformsFeesInfo(
        address[] calldata tokens
    ) external view returns (uint256[] memory fees) {
        fees = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ) {
            address token = tokens[i];
            uint256 amount = platformsFeesInfo[token] / Constants.COLLATERAL_BALANCE_PRECISION;
            fees[i] = amount;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Calculates the collateral amount required for a lifetime in seconds.
     *
     * @param borrowingKey The unique identifier of the borrowing.
     * @param lifetimeInSeconds The duration of the borrowing in seconds.
     * @return collateralAmt The calculated collateral amount that is needed.
     */
    function calculateCollateralAmtForLifetime(
        bytes32 borrowingKey,
        uint256 lifetimeInSeconds
    ) external view returns (uint256 collateralAmt) {
        // Retrieve the BorrowingInfo struct associated with the borrowing key
        BorrowingInfo memory borrowing = borrowingsInfo[borrowingKey];
        // Check if the borrowed position is existing
        if (borrowing.borrowedAmount > 0) {
            // Get the current daily rate for the hold token
            (uint256 currentDailyRate, ) = _getHoldTokenRateInfo(
                borrowing.saleToken,
                borrowing.holdToken
            );
            // Calculate the collateral amount per second
            uint256 everySecond = (
                FullMath.mulDivRoundingUp(
                    borrowing.borrowedAmount,
                    currentDailyRate * Constants.COLLATERAL_BALANCE_PRECISION,
                    1 days * Constants.BP
                )
            );
            // Calculate the total collateral amount for the borrowing lifetime
            collateralAmt = FullMath.mulDivRoundingUp(
                everySecond,
                lifetimeInSeconds,
                Constants.COLLATERAL_BALANCE_PRECISION
            );
            // Ensure that the collateral amount is at least 1
            if (collateralAmt == 0) collateralAmt = 1;
        }
    }

    /**
     * @notice This function is used to increase the daily rate collateral for a specific borrowing.
     * @param borrowingKey The unique identifier of the borrowing.
     * @param collateralAmt The amount of collateral to be added.
     */
    function increaseCollateralBalance(bytes32 borrowingKey, uint256 collateralAmt) external {
        BorrowingInfo storage borrowing = borrowingsInfo[borrowingKey];
        // Ensure that the borrowed position exists and the borrower is the message sender
        (borrowing.borrowedAmount == 0 || borrowing.borrower != address(msg.sender)).revertError(
            ErrLib.ErrorCode.INVALID_BORROWING_KEY
        );
        // Increase the daily rate collateral balance by the specified collateral amount
        borrowing.dailyRateCollateralBalance +=
            collateralAmt *
            Constants.COLLATERAL_BALANCE_PRECISION;
        _pay(borrowing.holdToken, msg.sender, VAULT_ADDRESS, collateralAmt);
        emit IncreaseCollateralBalance(msg.sender, borrowingKey, collateralAmt);
    }

    /**
     * @notice Take over debt by transferring ownership of a borrowing to the current caller
     * @dev This function allows the current caller to take over a debt from another borrower.
     * The function validates the borrowingKey and checks if the collateral balance is negative.
     * If the conditions are met, the function transfers ownership of the borrowing to the current caller,
     * updates the daily rate collateral balance, and pays the collateral amount to the vault.
     * Emits a `TakeOverDebt` event.
     * @param borrowingKey The unique key associated with the borrowing to be taken over
     * @param collateralAmt The amount of collateral to be provided by the new borrower
     */
    function takeOverDebt(bytes32 borrowingKey, uint256 collateralAmt) external {
        BorrowingInfo memory oldBorrowing = borrowingsInfo[borrowingKey];
        // Ensure that the borrowed position exists
        (oldBorrowing.borrowedAmount == 0).revertError(ErrLib.ErrorCode.INVALID_BORROWING_KEY);

        uint256 accLoanRatePerSeconds;
        uint256 minPayment;
        {
            // Update token rate info and retrieve the accumulated loan rate per second for holdToken
            (, TokenInfo storage holdTokenRateInfo) = _updateTokenRateInfo(
                oldBorrowing.saleToken,
                oldBorrowing.holdToken
            );
            accLoanRatePerSeconds = holdTokenRateInfo.accLoanRatePerSeconds;
            // Calculate the collateral balance and current fees for the oldBorrowing
            (int256 collateralBalance, uint256 currentFees) = _calculateCollateralBalance(
                oldBorrowing.borrowedAmount,
                oldBorrowing.accLoanRatePerSeconds,
                oldBorrowing.dailyRateCollateralBalance,
                accLoanRatePerSeconds
            );
            // Ensure that the collateral balance is greater than or equal to 0
            (collateralBalance >= 0).revertError(ErrLib.ErrorCode.FORBIDDEN);
            // Pick up platform fees from the oldBorrowing's holdToken and add them to the feesOwed
            currentFees = _pickUpPlatformFees(oldBorrowing.holdToken, currentFees);
            oldBorrowing.feesOwed += currentFees;
            // Calculate the minimum payment required based on the collateral balance
            minPayment = (uint256(-collateralBalance) / Constants.COLLATERAL_BALANCE_PRECISION) + 1;
            (collateralAmt <= minPayment).revertError(
                ErrLib.ErrorCode.COLLATERAL_AMOUNT_IS_NOT_ENOUGH
            );
        }
        // Retrieve the old loans associated with the borrowing key and remove them from storage
        LoanInfo[] memory oldLoans = loansInfo[borrowingKey];
        _removeKeysAndClearStorage(oldBorrowing.borrower, borrowingKey, oldLoans);
        // Initialize a new borrowing using the same saleToken, holdToken
        (
            uint256 feesDebt,
            bytes32 newBorrowingKey,
            BorrowingInfo storage newBorrowing
        ) = _initOrUpdateBorrowing(
                oldBorrowing.saleToken,
                oldBorrowing.holdToken,
                accLoanRatePerSeconds
            );
        // Add the new borrowing key and old loans to the newBorrowing
        _addKeysAndLoansInfo(newBorrowing.borrowedAmount > 0, borrowingKey, oldLoans);
        // Increase the borrowed amount, liquidation bonus, and fees owed of the newBorrowing based on the oldBorrowing
        newBorrowing.borrowedAmount += oldBorrowing.borrowedAmount;
        newBorrowing.liquidationBonus += oldBorrowing.liquidationBonus;
        newBorrowing.feesOwed += oldBorrowing.feesOwed;
        // oldBorrowing.dailyRateCollateralBalance is 0
        newBorrowing.dailyRateCollateralBalance +=
            (collateralAmt - minPayment) *
            Constants.COLLATERAL_BALANCE_PRECISION;
        //newBorrowing.accLoanRatePerSeconds = oldBorrowing.accLoanRatePerSeconds;
        _pay(oldBorrowing.holdToken, msg.sender, VAULT_ADDRESS, collateralAmt + feesDebt);
        emit TakeOverDebt(oldBorrowing.borrower, msg.sender, borrowingKey, newBorrowingKey);
    }

    /**
     * @notice Borrow function allows a user to borrow tokens by providing collateral and taking out loans.
     * The trader opens a long position by borrowing the liquidity of Uniswap V3 and extracting it into a pair of tokens,
     * one of which will be swapped into a desired(holdToken).The tokens will be kept in storage until the position is closed.
     * The margin is calculated on the basis that liquidity must be restored with any price movement.
     * The time the position is held is paid by the trader.
     * @dev Emits a Borrow event upon successful borrowing.
     * @param params The BorrowParams struct containing the necessary parameters for borrowing.
     * @param deadline The deadline timestamp after which the transaction is considered invalid.
     */
    function borrow(
        BorrowParams calldata params,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) {
        // Precalculating borrowing details and storing them in cache
        BorrowCache memory cache = _precalculateBorrowing(params);
        // Initializing borrowing variables and obtaining borrowing key
        (
            uint256 feesDebt,
            bytes32 borrowingKey,
            BorrowingInfo storage borrowing
        ) = _initOrUpdateBorrowing(params.saleToken, params.holdToken, cache.accLoanRatePerSeconds);
        // Adding borrowing key and loans information to storage
        _addKeysAndLoansInfo(borrowing.borrowedAmount > 0, borrowingKey, params.loans);
        // Calculating liquidation bonus based on hold token, borrowed amount, and number of used loans
        uint256 liquidationBonus = getLiquidationBonus(
            params.holdToken,
            cache.borrowedAmount,
            params.loans.length
        );
        // Updating borrowing details
        borrowing.borrowedAmount += cache.borrowedAmount;
        borrowing.liquidationBonus += liquidationBonus;
        borrowing.dailyRateCollateralBalance +=
            cache.dailyRateCollateral *
            Constants.COLLATERAL_BALANCE_PRECISION;
        // Checking if borrowing collateral exceeds the maximum allowed collateral
        uint256 borrowingCollateral = cache.borrowedAmount - cache.holdTokenBalance;
        (borrowingCollateral > params.maxCollateral).revertError(
            ErrLib.ErrorCode.TOO_BIG_COLLATERAL
        );

        // Transfer the required tokens to the VAULT_ADDRESS for collateral and holdTokenBalance
        _pay(
            params.holdToken,
            msg.sender,
            VAULT_ADDRESS,
            borrowingCollateral + liquidationBonus + cache.dailyRateCollateral + feesDebt
        );
        // Transferring holdTokenBalance to VAULT_ADDRESS
        _pay(params.holdToken, address(this), VAULT_ADDRESS, cache.holdTokenBalance);
        // Emit the Borrow event with the borrower, borrowing key, and borrowed amount
        emit Borrow(
            msg.sender,
            borrowingKey,
            cache.borrowedAmount,
            borrowingCollateral,
            liquidationBonus,
            cache.dailyRateCollateral
        );
    }

    /**
     * @notice This function is used to repay a loan.
     * The position is closed either by the trader or by the liquidator if the trader has not paid for holding the position
     * and the moment of liquidation has arrived.The positions borrowed from liquidation providers are restored from the held
     * token and the remainder is sent to the caller.In the event of liquidation, the liquidity provider
     * whose liquidity is present in the trader’s position can use the emergency mode and withdraw their liquidity.In this case,
     * he will receive hold tokens and liquidity will not be restored in the uniswap pool.
     * @param params The repayment parameters including
     *  activation of the emergency liquidity restoration mode (available only to the lender)
     *  internal swap pool fee,
     *  external swap parameters,
     *  borrowing key,
     *  swap slippage allowance.
     * @param deadline The deadline by which the repayment must be made.
     */
    function repay(
        RepayParams calldata params,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) {
        BorrowingInfo memory borrowing = borrowingsInfo[params.borrowingKey];
        // Check if the borrowing key is valid
        (borrowing.borrowedAmount == 0).revertError(ErrLib.ErrorCode.INVALID_BORROWING_KEY);

        bool zeroForSaleToken = borrowing.saleToken < borrowing.holdToken;
        uint256 liquidationBonus = borrowing.liquidationBonus;
        int256 collateralBalance;
        // Update token rate information and get holdTokenRateInfo storage reference
        (, TokenInfo storage holdTokenRateInfo) = _updateTokenRateInfo(
            borrowing.saleToken,
            borrowing.holdToken
        );
        {
            // Calculate collateral balance and validate caller
            uint256 accLoanRatePerSeconds = holdTokenRateInfo.accLoanRatePerSeconds;
            uint256 currentFees;
            (collateralBalance, currentFees) = _calculateCollateralBalance(
                borrowing.borrowedAmount,
                borrowing.accLoanRatePerSeconds,
                borrowing.dailyRateCollateralBalance,
                accLoanRatePerSeconds
            );

            (msg.sender != borrowing.borrower && collateralBalance >= 0).revertError(
                ErrLib.ErrorCode.INVALID_CALLER
            );

            // Calculate liquidation bonus and adjust fees owed

            if (
                collateralBalance > 0 &&
                (currentFees + borrowing.feesOwed) / Constants.COLLATERAL_BALANCE_PRECISION >
                Constants.MINIMUM_AMOUNT
            ) {
                liquidationBonus +=
                    uint256(collateralBalance) /
                    Constants.COLLATERAL_BALANCE_PRECISION;
            } else {
                currentFees = borrowing.dailyRateCollateralBalance;
            }

            // Calculate platform fees and adjust fees owed
            borrowing.feesOwed += _pickUpPlatformFees(borrowing.holdToken, currentFees);
        }
        // Check if it's an emergency repayment
        if (params.isEmergency) {
            (collateralBalance >= 0).revertError(ErrLib.ErrorCode.FORBIDDEN);
            (
                uint256 removedAmt,
                uint256 feesAmt,
                bool completeRepayment
            ) = _calculateEmergencyLoanClosure(
                    zeroForSaleToken,
                    params.borrowingKey,
                    borrowing.feesOwed,
                    borrowing.borrowedAmount
                );
            (removedAmt == 0).revertError(ErrLib.ErrorCode.LIQUIDITY_IS_ZERO);
            // prevent overspent
            // Subtract the removed amount and fees from borrowedAmount and feesOwed
            borrowing.borrowedAmount -= removedAmt;
            borrowing.feesOwed -= feesAmt;
            feesAmt /= Constants.COLLATERAL_BALANCE_PRECISION;
            // Deduct the removed amount from totalBorrowed
            holdTokenRateInfo.totalBorrowed -= removedAmt;
            // If loansInfoLength is 0, remove the borrowing key from storage and get the liquidation bonus
            if (completeRepayment) {
                LoanInfo[] memory empty;
                _removeKeysAndClearStorage(borrowing.borrower, params.borrowingKey, empty);
                feesAmt += liquidationBonus;
            } else {
                BorrowingInfo storage borrowingStorage = borrowingsInfo[params.borrowingKey];
                borrowingStorage.dailyRateCollateralBalance = 0;
                borrowingStorage.feesOwed = borrowing.feesOwed;
                borrowingStorage.borrowedAmount = borrowing.borrowedAmount;
                // Calculate the updated accLoanRatePerSeconds
                borrowingStorage.accLoanRatePerSeconds =
                    holdTokenRateInfo.accLoanRatePerSeconds -
                    FullMath.mulDiv(
                        uint256(-collateralBalance),
                        Constants.BP,
                        borrowing.borrowedAmount // new amount
                    );
            }
            // Transfer removedAmt + feesAmt to msg.sender and emit EmergencyLoanClosure event
            Vault(VAULT_ADDRESS).transferToken(
                borrowing.holdToken,
                msg.sender,
                removedAmt + feesAmt
            );
            emit EmergencyLoanClosure(borrowing.borrower, msg.sender, params.borrowingKey);
        } else {
            // Deduct borrowedAmount from totalBorrowed
            holdTokenRateInfo.totalBorrowed -= borrowing.borrowedAmount;

            // Transfer the borrowed amount and liquidation bonus from the VAULT to this contract
            Vault(VAULT_ADDRESS).transferToken(
                borrowing.holdToken,
                address(this),
                borrowing.borrowedAmount + liquidationBonus
            );
            // Restore liquidity using the borrowed amount and pay a daily rate fee
            LoanInfo[] memory loans = loansInfo[params.borrowingKey];
            _maxApproveIfNecessary(
                borrowing.holdToken,
                address(underlyingPositionManager),
                type(uint128).max
            );
            _maxApproveIfNecessary(
                borrowing.saleToken,
                address(underlyingPositionManager),
                type(uint128).max
            );

            _restoreLiquidity(
                RestoreLiquidityParams({
                    zeroForSaleToken: zeroForSaleToken,
                    fee: params.internalSwapPoolfee,
                    slippageBP1000: params.swapSlippageBP1000,
                    totalfeesOwed: borrowing.feesOwed,
                    totalBorrowedAmount: borrowing.borrowedAmount
                }),
                params.externalSwap,
                loans
            );
            // Get the remaining balance of saleToken and holdToken
            (uint256 saleTokenBalance, uint256 holdTokenBalance) = _getPairBalance(
                borrowing.saleToken,
                borrowing.holdToken
            );
            // Remove borrowing key from related data structures
            _removeKeysAndClearStorage(borrowing.borrower, params.borrowingKey, loans);
            // Pay a profit to a msg.sender
            _pay(borrowing.holdToken, address(this), msg.sender, holdTokenBalance);
            _pay(borrowing.saleToken, address(this), msg.sender, saleTokenBalance);

            emit Repay(borrowing.borrower, msg.sender, params.borrowingKey);
        }
    }

    /**
     * @dev Calculates the liquidation bonus for a given token, borrowed amount, and times factor.
     * @param token The address of the token.
     * @param borrowedAmount The amount of tokens borrowed.
     * @param times The times factor to apply to the liquidation bonus calculation.
     * @return liquidationBonus The calculated liquidation bonus.
     */
    function getLiquidationBonus(
        address token,
        uint256 borrowedAmount,
        uint256 times
    ) public view returns (uint256 liquidationBonus) {
        // Retrieve liquidation bonus for the given token
        Liquidation memory liq = liquidationBonusForToken[token];

        if (liq.bonusBP == 0) {
            // If there is no specific bonus for the token
            // Use default bonus
            liq.minBonusAmount = Constants.MINIMUM_AMOUNT;
            liq.bonusBP = dafaultLiquidationBonusBP;
        }
        liquidationBonus = (borrowedAmount * liq.bonusBP) / Constants.BP;

        if (liquidationBonus < liq.minBonusAmount) {
            liquidationBonus = liq.minBonusAmount;
        }
        liquidationBonus *= times;
    }

    /**
     * @notice Calculates the amount to be repaid in an emergency situation.
     * @dev This function removes loans associated with a borrowing key owned by the `msg.sender`.
     * @param zeroForSaleToken A boolean value indicating whether the token for sale is the 0th token or not.
     * @param borrowingKey The identifier for the borrowing key.
     * @param totalfeesOwed The total fees owed without pending fees.
     * @param totalBorrowedAmount The total borrowed amount.
     * @return removedAmt The amount of debt removed from the loan.
     * @return feesAmt The calculated fees amount.
     * @return completeRepayment indicates the complete closure of the debtor's position
     */
    function _calculateEmergencyLoanClosure(
        bool zeroForSaleToken,
        bytes32 borrowingKey,
        uint256 totalfeesOwed,
        uint256 totalBorrowedAmount
    ) private returns (uint256 removedAmt, uint256 feesAmt, bool completeRepayment) {
        // Create a memory struct to store liquidity cache information.
        RestoreLiquidityCache memory cache;
        // Get the array of LoanInfo structs associated with the given borrowing key.
        LoanInfo[] storage loans = loansInfo[borrowingKey];
        // Iterate through each loan in the loans array.
        for (uint256 i; i < loans.length; ) {
            LoanInfo memory loan = loans[i];
            // Get the owner address of the loan's token ID using the underlyingPositionManager contract.
            address creditor = underlyingPositionManager.ownerOf(loan.tokenId);
            // Check if the owner of the loan's token ID is equal to the `msg.sender`.
            if (creditor == msg.sender) {
                // If the owner matches the `msg.sender`, replace the current loan with the last loan in the loans array
                // and remove the last element.
                loans[i] = loans[loans.length - 1];
                loans.pop();
                // Remove the borrowing key from the tokenIdToBorrowingKeys mapping.
                tokenIdToBorrowingKeys[loan.tokenId].removeKey(borrowingKey);
                // Update the liquidity cache based on the loan information.
                _upRestoreLiquidityCache(zeroForSaleToken, loan, cache);
                // Add the holdTokenDebt value to the removedAmt.
                removedAmt += cache.holdTokenDebt;
                // Calculate the fees amount based on the total fees owed and holdTokenDebt.
                feesAmt += FullMath.mulDiv(totalfeesOwed, cache.holdTokenDebt, totalBorrowedAmount);
            } else {
                // If the owner of the loan's token ID is not equal to the `msg.sender`,
                // the function increments the loop counter and moves on to the next loan.
                unchecked {
                    ++i;
                }
            }
        }
        // Check if all loans have been removed, indicating complete repayment.
        completeRepayment = loans.length == 0;
    }

    /**
     * @dev This internal function is used to remove borrowing keys and clear related storage for a specific
     * borrower and borrowing key.
     * @param borrower The address of the borrower.
     * @param borrowingKey The borrowing key to be removed.
     * @param loans An array of LoanInfo structs representing the loans associated with the borrowing key.
     */
    function _removeKeysAndClearStorage(
        address borrower,
        bytes32 borrowingKey,
        LoanInfo[] memory loans
    ) private {
        // Remove the borrowing key from the tokenIdToBorrowingKeys mapping for each loan in the loans array.
        for (uint256 i; i < loans.length; ) {
            tokenIdToBorrowingKeys[loans[i].tokenId].removeKey(borrowingKey);
            unchecked {
                ++i;
            }
        }
        // Remove the borrowing key from the userBorrowingKeys mapping for the borrower.
        userBorrowingKeys[borrower].removeKey(borrowingKey);
        // Delete the borrowing information and loans associated with the borrowing key from the borrowingsInfo
        // and loansInfo mappings.
        delete borrowingsInfo[borrowingKey];
        delete loansInfo[borrowingKey];
    }

    /**
     * @dev This internal function is used to add borrowing keys and loan information for a specific borrowing key.
     * @param update A boolean indicating whether the borrowing key is being updated or added as a new position.
     * @param borrowingKey The borrowing key to be added or updated.
     * @param sourceLoans An array of LoanInfo structs representing the loans to be associated with the borrowing key.
     */
    function _addKeysAndLoansInfo(
        bool update,
        bytes32 borrowingKey,
        LoanInfo[] memory sourceLoans
    ) private {
        // Get the storage reference to the loans array for the borrowing key
        LoanInfo[] storage loans = loansInfo[borrowingKey];
        // Iterate through the sourceLoans array
        for (uint256 i; i < sourceLoans.length; ) {
            // Get the current loan from the sourceLoans array
            LoanInfo memory loan = sourceLoans[i];
            // Get the storage reference to the tokenIdLoansKeys array for the loan's token ID
            bytes32[] storage tokenIdLoansKeys = tokenIdToBorrowingKeys[loan.tokenId];
            // Conditionally add or push the borrowing key to the tokenIdLoansKeys array based on the 'update' flag
            update
                ? tokenIdLoansKeys.addKeyIfNotExists(borrowingKey)
                : tokenIdLoansKeys.push(borrowingKey);
            // Push the current loan to the loans array
            loans.push(loan);
            unchecked {
                ++i;
            }
        }
        // Ensure that the number of loans does not exceed the maximum limit
        (loans.length > Constants.MAX_NUM_LOANS_PER_POSITION).revertError(
            ErrLib.ErrorCode.TOO_MANY_LOANS_PER_POSITION
        );
        if (!update) {
            // If it's a new position, ensure that the user does not have too many positions
            bytes32[] storage allUserBorrowingKeys = userBorrowingKeys[msg.sender];
            (allUserBorrowingKeys.length > Constants.MAX_NUM_USER_POSOTION).revertError(
                ErrLib.ErrorCode.TOO_MANY_USER_POSITIONS
            );
            // Add the borrowingKey to the user's borrowing keys
            allUserBorrowingKeys.push(borrowingKey);
        }
    }

    /**
     * @dev This internal function is used to precalculate borrowing parameters and update the cache.
     * @param params The BorrowParams struct containing the borrowing parameters.
     * @return cache A BorrowCache struct containing the calculated values.
     */
    function _precalculateBorrowing(
        BorrowParams calldata params
    ) private returns (BorrowCache memory cache) {
        {
            bool zeroForSaleToken = params.saleToken < params.holdToken;
            // Create a storage reference for the hold token rate information
            TokenInfo storage holdTokenRateInfo;
            // Update the token rate information and retrieve the dailyRate and TokenInfo for the holdTokenRateInfo
            (cache.dailyRateCollateral, holdTokenRateInfo) = _updateTokenRateInfo(
                params.saleToken,
                params.holdToken
            );
            // Set the accumulated loan rate per second from the updated holdTokenRateInfo
            cache.accLoanRatePerSeconds = holdTokenRateInfo.accLoanRatePerSeconds;
            // Extract liquidity and store the borrowed amount in the cache
            cache.borrowedAmount = _extractLiquidity(
                zeroForSaleToken,
                params.saleToken,
                params.holdToken,
                params.loans
            );
            // Increment the total borrowed amount for the hold token information
            holdTokenRateInfo.totalBorrowed += cache.borrowedAmount;
        }
        // Calculate the prepayment per day fees based on the borrowed amount and daily rate collateral
        cache.dailyRateCollateral = FullMath.mulDivRoundingUp(
            cache.borrowedAmount,
            cache.dailyRateCollateral,
            Constants.BP
        );
        // Check if the dailyRateCollateral is less than the minimum amount defined in the Constants contract
        if (cache.dailyRateCollateral < Constants.MINIMUM_AMOUNT) {
            cache.dailyRateCollateral = Constants.MINIMUM_AMOUNT;
        }
        uint256 saleTokenBalance;
        // Get the balance of the sale token and hold token in the pair
        (saleTokenBalance, cache.holdTokenBalance) = _getPairBalance(
            params.saleToken,
            params.holdToken
        );
        // Check if the sale token balance is greater than 0
        if (saleTokenBalance > 0) {
            if (params.externalSwap.swapTarget != address(0)) {
                // Call the external swap function and update the hold token balance in the cache
                cache.holdTokenBalance += _patchAmountsAndCallSwap(
                    params.saleToken,
                    params.holdToken,
                    params.externalSwap,
                    saleTokenBalance,
                    0
                );
            } else {
                // Call the internal v3SwapExactInput function and update the hold token balance in the cache
                cache.holdTokenBalance += _v3SwapExactInput(
                    v3SwapExactInputParams({
                        fee: params.internalSwapPoolfee,
                        tokenIn: params.saleToken,
                        tokenOut: params.holdToken,
                        amountIn: saleTokenBalance,
                        amountOutMinimum: 0
                    })
                );
            }
        }

        // Ensure that the received holdToken balance meets the minimum required
        if (cache.holdTokenBalance < params.minHoldTokenOut) {
            revert TooLittleReceivedError(params.minHoldTokenOut, cache.holdTokenBalance);
        }
    }

    /**
     * @dev This internal function is used to initialize or update the borrowing process for a given saleToken and holdToken combination.
     * It computes the borrowingKey, retrieves the BorrowingInfo from borrowingsInfo mapping,
     * and updates the BorrowingInfo based on the current state of the borrowing.
     * @param saleToken The address of the sale token.
     * @param holdToken The address of the hold token.
     * @param accLoanRatePerSeconds The accumulated loan rate per second for the borrower.
     * @return feesDebt The calculated fees debt.
     * @return borrowingKey The borrowing key for the borrowing position.
     * @return borrowing The storage reference to the BorrowingInfo struct.
     */
    function _initOrUpdateBorrowing(
        address saleToken,
        address holdToken,
        uint256 accLoanRatePerSeconds
    ) private returns (uint256 feesDebt, bytes32 borrowingKey, BorrowingInfo storage borrowing) {
        // Compute the borrowingKey using the msg.sender, saleToken, and holdToken
        borrowingKey = Keys.computeBorrowingKey(msg.sender, saleToken, holdToken);
        // Retrieve the BorrowingInfo from borrowingsInfo mapping using the borrowingKey
        borrowing = borrowingsInfo[borrowingKey];
        // update
        if (borrowing.borrowedAmount > 0) {
            // Ensure that the borrower of the existing borrowing position matches the msg.sender
            (borrowing.borrower != address(msg.sender)).revertError(
                ErrLib.ErrorCode.INVALID_BORROWING_KEY
            );
            // Calculate the collateral balance and current fees based on the existing borrowing information
            (int256 collateralBalance, uint256 currentFees) = _calculateCollateralBalance(
                borrowing.borrowedAmount,
                borrowing.accLoanRatePerSeconds,
                borrowing.dailyRateCollateralBalance,
                accLoanRatePerSeconds
            );
            // Calculate the fees debt
            if (collateralBalance < 0) {
                feesDebt = uint256(-collateralBalance) / Constants.COLLATERAL_BALANCE_PRECISION + 1;
                borrowing.dailyRateCollateralBalance = 0;
            } else {
                borrowing.dailyRateCollateralBalance -= currentFees;
            }
            // Pick up platform fees from the hold token's current fees
            currentFees = _pickUpPlatformFees(holdToken, currentFees);
            // Increment the fees owed in the borrowing position
            borrowing.feesOwed += currentFees;
        } else {
            // Initialize the BorrowingInfo for the new position
            borrowing.borrower = msg.sender;
            borrowing.saleToken = saleToken;
            borrowing.holdToken = holdToken;
        }
        // Set the accumulated loan rate per second for the borrowing position
        borrowing.accLoanRatePerSeconds = accLoanRatePerSeconds;
    }

    /**
     * @dev This internal function is used to pick up platform fees from the given fees amount.
     * It calculates the platform fees based on the fees and platformFeesBP (basis points) variables,
     * updates the platformsFeesInfo mapping with the platform fees for the holdToken,
     * and returns the remaining fees after deducting the platform fees.
     * @param holdToken The address of the hold token.
     * @param fees The total fees amount.
     * @return currentFees The remaining fees after deducting the platform fees.
     */
    function _pickUpPlatformFees(
        address holdToken,
        uint256 fees
    ) private returns (uint256 currentFees) {
        uint256 platformFees = (fees * platformFeesBP) / Constants.BP;
        platformsFeesInfo[holdToken] += platformFees;
        currentFees = fees - platformFees;
    }

    /**
     * @dev This internal function is used to get information about a specific debt.
     * It retrieves the borrowing information from the borrowingsInfo mapping based on the borrowingKey,
     * calculates the current daily rate and hold token rate info using the _getHoldTokenRateInfo function,
     * calculates the collateral balance using the _calculateCollateralBalance function,
     * and calculates the estimated lifetime of the debt if the collateral balance is greater than zero.
     * @param borrowingKey The unique key associated with the debt.
     * @return borrowing The struct containing information about the debt.
     * @return collateralBalance The calculated collateral balance for the debt.
     * @return estimatedLifeTime The estimated number of seconds the debt will last based on the collateral balance.
     */
    function _getDebtInfo(
        bytes32 borrowingKey
    )
        private
        view
        returns (
            BorrowingInfo memory borrowing,
            int256 collateralBalance,
            uint256 estimatedLifeTime
        )
    {
        // Retrieve the borrowing information from the borrowingsInfo mapping based on the borrowingKey
        borrowing = borrowingsInfo[borrowingKey];
        // Calculate the current daily rate and hold token rate info using the _getHoldTokenRateInfo function
        (uint256 currentDailyRate, TokenInfo memory holdTokenRateInfo) = _getHoldTokenRateInfo(
            borrowing.saleToken,
            borrowing.holdToken
        );

        (collateralBalance, ) = _calculateCollateralBalance(
            borrowing.borrowedAmount,
            borrowing.accLoanRatePerSeconds,
            borrowing.dailyRateCollateralBalance,
            holdTokenRateInfo.accLoanRatePerSeconds
        );
        // Calculate the estimated lifetime of the debt if the collateral balance is greater than zero
        if (collateralBalance > 0) {
            uint256 everySecond = (
                FullMath.mulDivRoundingUp(
                    borrowing.borrowedAmount,
                    currentDailyRate * Constants.COLLATERAL_BALANCE_PRECISION,
                    1 days * Constants.BP
                )
            );

            estimatedLifeTime = uint256(collateralBalance) / everySecond;
            if (estimatedLifeTime == 0) estimatedLifeTime = 1;
        }
    }

    /// @notice Retrieves the debt information for the specified borrowing keys.
    /// @param borrowingKeys The array of borrowing keys to retrieve the debt information for.
    /// @return extinfo An array of BorrowingInfoExt structs representing the borrowing information.
    function _getDebtsInfo(
        bytes32[] memory borrowingKeys
    ) private view returns (BorrowingInfoExt[] memory extinfo) {
        extinfo = new BorrowingInfoExt[](borrowingKeys.length);
        for (uint256 i; i < borrowingKeys.length; ) {
            bytes32 key = borrowingKeys[i];
            extinfo[i].key = key;
            extinfo[i].loans = loansInfo[key];
            (
                extinfo[i].info,
                extinfo[i].collateralBalance,
                extinfo[i].estimatedLifeTime
            ) = _getDebtInfo(key);
            unchecked {
                ++i;
            }
        }
    }
}