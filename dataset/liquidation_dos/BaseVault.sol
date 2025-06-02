// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Contracts
import { Controllable } from "../Controller/Controllable.sol";
import { Controller } from "../Controller/Controller.sol";
import { PriceOracleManager } from "../Oracle/PriceOracleManager.sol";
import { TauDripFeed } from "./TauDripFeed.sol";
import { SwapHandler } from "./SwapHandler.sol";
import { TAU } from "../TAU.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// Libraries
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Constants } from "../Libs/Constants.sol";
import { TauMath } from "../Libs/TauMath.sol";

// Note that this contract is not compatible with ERC777 tokens due to potential reentrancy concerns.
abstract contract BaseVault is SwapHandler, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    /// Define the errors
    error insufficientCollateral();
    error userNotFound();
    error wrongLiquidationAmount();
    error incorrectDebtRepayAmount();
    error insufficientCollateralLiquidated(uint256 debtRepaid, uint256 collateralReceived);
    error cannotLiquidateHealthyAccount();

    // Events
    event Repay(address indexed _repayer, uint256 _amountTau);
    event Borrow(address indexed _borrower, uint256 _amountTau);
    event Deposit(address indexed _depositer, uint256 _amountAsset);
    event Withdraw(address indexed _withdrawer, uint256 _amountAsset);
    event AccountLiquidated(address _liquidator, address _account, uint256 _amount, uint256 _liqFees);
    event TauEarned(address indexed _account, uint256 _amount); // Emitted when a user's debt is cancelled

    struct UserDetails {
        uint256 collateral; // Collateral amount deposited by user
        uint256 debt; // Debt amount borrowed by user
        uint256 lastUpdatedRewardPerCollateral; // Last updated reward per collateral for the user
        uint256 startTimestamp; // Time when the first deposit was made by the user
    }

    /// @dev mapping of user and UserDetails
    mapping(address => UserDetails) public userDetails;

    /// @dev keep track of user addresses to index the userDetails for liquidation
    address[] public userAddresses;

    // Liquidation constants

    // Minimum collateral ratio
    uint256 public constant MIN_COL_RATIO = 1.2e18; // 120 %

    // Maximum collateral ratio an account can have after being liquidated (limits liquidation size to only what is necessary)
    uint256 public constant MAX_LIQ_COLL_RATIO = 1.3e18; // 130 %

    uint256 public constant MAX_LIQ_DISCOUNT = 0.2e18; // 20 %

    // 2% of the liquidated amount is sent to the FeeSplitter to fund protocol stability
    // and disincentivize self-liquidation
    uint256 public constant LIQUIDATION_SURCHARGE = 0.02e18;

    function __BaseVault_init(address _controller, address _tau, address _collateralToken) internal initializer {
        __Controllable_init(_controller);
        __TauDripFeed_init(_tau, _collateralToken);
    }

    /**
     * @dev modifier to update user's reward per collateral and pay off some of their debt. This is
        executed before any function that modifies a user's collateral or debt.
     * note if there is surplus TAU after the debt is paid off, it is added back to the drip feed.
     */
    modifier updateReward(address _account) {
        // Disburse available yield from the drip feed
        _disburseTau();

        // If user has collateral, pay down their debt and recycle surplus rewards back into the tauDripFeed.
        uint256 _userCollateral = userDetails[_account].collateral;
        if (_userCollateral > 0) {
            // Get diff between global rewardPerCollateral and user lastUpdatedRewardPerCollateral
            uint256 _rewardDiff = cumulativeTauRewardPerCollateral -
                userDetails[_account].lastUpdatedRewardPerCollateral;

            // Calculate user's TAU earned since the last update, use it to pay off debt
            uint256 _tauEarned = (_rewardDiff * _userCollateral) / Constants.PRECISION;

            if (_tauEarned > 0) {
                uint256 _userDebt = userDetails[_account].debt;
                if (_tauEarned > _userDebt) {
                    // If user has earned more than enough TAU to pay off their debt, pay off debt and add surplus to drip feed
                    userDetails[_account].debt = 0;

                    _withholdTau(_tauEarned - _userDebt);
                    _tauEarned = _userDebt;
                } else {
                    // Pay off as much debt as possible
                    userDetails[_account].debt = _userDebt - _tauEarned;
                }

                emit TauEarned(_account, _tauEarned);
            }
        } else {
            // If this is a new user, add them to the userAddresses array to keep track of them.
            if (userDetails[_account].startTimestamp == 0) {
                userAddresses.push(_account);
                userDetails[_account].startTimestamp = block.timestamp;
            }
        }

        // Update user lastUpdatedRewardPerCollateral
        userDetails[_account].lastUpdatedRewardPerCollateral = cumulativeTauRewardPerCollateral;
        _;
    }

    //------------------------------------------------------------View functions------------------------------------------------------------

    /// @dev In this function, we assume that TAU is worth $1 exactly. This allows users to arbitrage the difference, if any.
    function getAccountHealth(address _account) public view returns (bool) {
        uint256 ratio = _getCollRatio(_account);

        return (ratio > MIN_COL_RATIO);
    }

    /**
     * @dev calculate the max amount of debt that can be liquidated from an account
     * @param _account is the address of the account to be liquidated
     * @return maxRepay is the maximum amount of debt that can be liquidated from the account
     */
    function getMaxLiquidation(address _account) external view returns (uint256 maxRepay) {
        (uint256 price, uint8 decimals) = _getCollPrice();
        UserDetails memory accDetails = userDetails[_account];
        uint256 _collRatio = TauMath._computeCR(accDetails.collateral, accDetails.debt, price, decimals);

        // This call will revert if the account is healthy
        uint256 totalLiquidationDiscount = _calcLiquidationDiscount(_collRatio);

        maxRepay = _getMaxLiquidation(
            accDetails.collateral,
            accDetails.debt,
            price,
            decimals,
            totalLiquidationDiscount
        );
        return maxRepay;
    }

    /// @dev Get the number of users
    function getUsersCount() public view returns (uint256) {
        return userAddresses.length;
    }

    /** @dev Get the user details in the range given start and end index.
     * note the start and end index are inclusive
     */
    function getUsersDetailsInRange(uint256 _start, uint256 _end) public view returns (UserDetails[] memory users) {
        if (_end > getUsersCount() || _start > _end) revert indexOutOfBound();

        users = new UserDetails[](_end - _start + 1);

        for (uint i = _start; i < _end; ++i) {
            users[i - _start] = userDetails[userAddresses[i]];
        }
    }

    /** @dev Get the user addresses in the range given start and end index
     * note the start and end index are inclusive
     */
    function getUsers(uint256 _start, uint256 _end) public view returns (address[] memory users) {
        if (_end > getUsersCount() || _start > _end) revert indexOutOfBound();

        users = new address[](_end - _start + 1);

        for (uint256 i = _start; i < _end; ++i) {
            users[i - _start] = userAddresses[i];
        }
    }

    function _checkAccountHealth(address _account) internal view {
        if (!getAccountHealth(_account)) {
            revert insufficientCollateral();
        }
    }

    /// @dev In this function, we calculate the collateral ratio
    function _getCollRatio(address _account) internal view returns (uint256 ratio) {
        // Fetch the price from oracle manager
        (uint256 price, uint8 decimals) = _getCollPrice();

        // Check that user's collateral ratio is above minimum healthy ratio
        ratio = TauMath._computeCR(userDetails[_account].collateral, userDetails[_account].debt, price, decimals);
    }

    function _getCollPrice() internal view virtual returns (uint256 price, uint8 decimals) {
        bool success;

        // Fetch the price from oracle manager
        (price, decimals, success) = PriceOracleManager(
            Controller(controller).addressMapper(Constants.PRICE_ORACLE_MANAGER)
        ).getExternalPrice(collateralToken, abi.encodePacked(false));
        if (!success) {
            revert oracleCorrupt();
        }
    }

    //------------------------------------------------------------User functions------------------------------------------------------------

    function modifyPosition(
        uint256 _collateralDelta,
        uint256 _debtDelta,
        bool _increaseCollateral,
        bool _increaseDebt
    ) external whenNotPaused updateReward(msg.sender) {
        _modifyPosition(msg.sender, _collateralDelta, _debtDelta, _increaseCollateral, _increaseDebt);
    }

    /**
     * @dev Function allowing a user to automatically close their position.
     * Note that this function is available even when the contract is paused.
     * Note that since this function does not call updateReward, it should only be used when the contract is paused.
     *
     */
    function emergencyClosePosition() external {
        _modifyPosition(msg.sender, userDetails[msg.sender].collateral, userDetails[msg.sender].debt, false, false);
    }

    /**
     * @dev Find the max amount of debt that can be liquidated from an account.
     * @param _collateral is the amount of collateral the user has.
     * @param _debt is the amount of debt the user has.
     * @param _price is $ / collateral
     * @param _decimals is the number of decimals in price
     * @param _liquidationDiscount is the liquidation discount in percentage, e.g. 120% * PRECISION
     * @return maxRepay is the max amount of debt which can be repaid as part of the liquidation process, 0 if the user's account is healthy.
     */
    function _getMaxLiquidation(
        uint256 _collateral,
        uint256 _debt,
        uint256 _price,
        uint8 _decimals,
        uint256 _liquidationDiscount
    ) internal pure returns (uint256 maxRepay) {
        // Formula to find the liquidation amount is as follows
        // [(collateral * price) - (liqDiscount * liqAmount)] / (debt - liqAmount) = max liq ratio
        // Therefore
        // liqAmount = [(max liq ratio * debt) - (collateral * price)] / (max liq ratio - liqDiscount)
        maxRepay =
            ((MAX_LIQ_COLL_RATIO * _debt) - ((_collateral * _price * Constants.PRECISION) / (10 ** _decimals))) /
            (MAX_LIQ_COLL_RATIO - _liquidationDiscount);

        // Liquidators cannot repay more than the account's debt
        if (maxRepay > _debt) {
            maxRepay = _debt;
        }

        return maxRepay;
    }

    //------------------------------------------------------------BaseVault internal functions------------------------------------------------------------

    /**
     * @dev function to modify user collateral and debt in any way. If debt is increased or collateral reduced, the account must be healthy at the end of the tx.
     * note that generally this function is called after updateReward, meaning that user details are up to date.
     * @param _account is the account to be modified
     * @param _collateralDelta is the absolute value of the change in collateral.
     *  note that withdrawals cannot attempt to withdraw more than the user collateral balance, or the transaction will revert.
     * @param _debtDelta is the absolute value of the change in debt
     *  note that repayments can attempt to repay more than their debt balance. Only their debt balance will be pulled, and used to cancel out their debt.
     * @param _increaseCollateral is true if collateral is being deposited, false if collateralDelta is 0 or collateral is being withdrawn
     * @param _increaseDebt is true if debt is being borrowed, false if debtDelta is 0 or debt is being repaid
     */
    function _modifyPosition(
        address _account,
        uint256 _collateralDelta,
        uint256 _debtDelta,
        bool _increaseCollateral,
        bool _increaseDebt
    ) internal virtual {
        bool mustCheckHealth; // False until an action is taken which can reduce account health

        // Handle debt first, since TAU has no reentrancy concerns.
        if (_debtDelta != 0) {
            if (_increaseDebt) {
                // Borrow TAU from the vault
                userDetails[_account].debt += _debtDelta;
                mustCheckHealth = true;
                TAU(tau).mint(_account, _debtDelta);

                emit Borrow(_account, _debtDelta);
            } else {
                // Repay TAU debt
                uint256 currentDebt = userDetails[_account].debt;
                if (_debtDelta > currentDebt) _debtDelta = currentDebt;
                userDetails[_account].debt = currentDebt - _debtDelta;
                // Burn Tau used to repay debt
                TAU(tau).burnFrom(_account, _debtDelta);

                emit Repay(_account, _debtDelta);
            }
        }

        if (_collateralDelta != 0) {
            if (_increaseCollateral) {
                // Deposit collateral
                userDetails[_account].collateral += _collateralDelta;
                IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _collateralDelta);

                emit Deposit(_account, _collateralDelta);
            } else {
                // Withdraw collateral
                uint256 currentCollateral = userDetails[_account].collateral;
                if (_collateralDelta > currentCollateral) revert insufficientCollateral();
                userDetails[_account].collateral = currentCollateral - _collateralDelta;
                mustCheckHealth = true;
                IERC20(collateralToken).safeTransfer(msg.sender, _collateralDelta);

                emit Withdraw(_account, _collateralDelta);
            }
        }

        if (mustCheckHealth) {
            _checkAccountHealth(_account);
        }
    }

    //------------------------------------------------------------Liquidator/governance functions------------------------------------------------------------

    /**
     * @param _account is the account to be liquidated. It must be unhealthy.
     * @param _debtAmount is the amount of debt to be repaid. It must be greater than 0. If the entire account is liquidateable, an arbitrarily
     high debt amount will signal that the entire account should be liquidated. Otherwise, _debtAmount must be less than or equal to the max
     debt which can be liquidated from the acount.
     * @param _minExchangeRate represents the minimum number of collateral tokens which the liquidator is willing to receive in exchange for 
      1 debt token. A value of PRECISION will mean that the liquidation will revert unless the liquidator receives at least 1 collateral per
      debt token repaid. A value of 0 means that slippage is not checked, and the liquidator will accept whatever the exchange rate happens to be.
     * @return true if the liquidation was successful
     */
    function liquidate(
        address _account,
        uint256 _debtAmount,
        uint256 _minExchangeRate
    ) external onlyLiquidator whenNotPaused updateReward(_account) returns (bool) {
        if (_debtAmount == 0) revert wrongLiquidationAmount();

        UserDetails memory accDetails = userDetails[_account];

        // Since Taurus accounts' debt continuously decreases, liquidators may pass in an arbitrarily large number in order to
        // request to liquidate the entire account.
        if (_debtAmount > accDetails.debt) {
            _debtAmount = accDetails.debt;
        }

        // Get total fee charged to the user for this liquidation. Collateral equal to (liquidated taurus debt value * feeMultiplier) will be deducted from the user's account.
        // This call reverts if the account is healthy or if the liquidation amount is too large.
        (uint256 collateralToLiquidate, uint256 liquidationSurcharge) = _calcLiquidation(
            accDetails.collateral,
            accDetails.debt,
            _debtAmount
        );

        // Check that collateral received is sufficient for liquidator
        uint256 collateralToLiquidator = collateralToLiquidate - liquidationSurcharge;
        if (collateralToLiquidator < (_debtAmount * _minExchangeRate) / Constants.PRECISION) {
            revert insufficientCollateralLiquidated(_debtAmount, collateralToLiquidator);
        }

        // Update user info
        userDetails[_account].collateral = accDetails.collateral - collateralToLiquidate;
        userDetails[_account].debt = accDetails.debt - _debtAmount;

        // Burn liquidator's Tau
        TAU(tau).burnFrom(msg.sender, _debtAmount);

        // Transfer part of _debtAmount to liquidator and Taurus as fees for liquidation
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToLiquidator);
        IERC20(collateralToken).safeTransfer(
            Controller(controller).addressMapper(Constants.FEE_SPLITTER),
            liquidationSurcharge
        );

        emit AccountLiquidated(msg.sender, _account, collateralToLiquidate, liquidationSurcharge);

        return true;
    }

    /**
     * @dev calculate relevant liquidation parameters. If 100 TAU are liquidated, and the discount is 105%, then 100 * 1.05 = 105 TAU worth of collateral
     * will be liquidated.
     * @return collateralToLiquidate is the amount of the user's collateral which will be liquidated
     * @return liquidationSurcharge is the amount of collateral which will be sent to the Taurus treasury as a liquidation fee
     */
    function _calcLiquidation(
        uint256 _accountCollateral,
        uint256 _accountDebt,
        uint256 _debtToLiquidate
    ) internal view returns (uint256 collateralToLiquidate, uint256 liquidationSurcharge) {
        (uint256 price, uint8 decimals) = _getCollPrice();
        uint256 _collRatio = TauMath._computeCR(_accountCollateral, _accountDebt, price, decimals);

        uint256 totalLiquidationDiscount = _calcLiquidationDiscount(_collRatio);

        uint256 collateralToLiquidateWithoutDiscount = (_debtToLiquidate * (10 ** decimals)) / price;
        collateralToLiquidate = (collateralToLiquidateWithoutDiscount * totalLiquidationDiscount) / Constants.PRECISION;
        if (collateralToLiquidate > _accountCollateral) {
            collateralToLiquidate = _accountCollateral;
        }

        // Revert if requested liquidation amount is greater than allowed
        if (
            _debtToLiquidate >
            _getMaxLiquidation(_accountCollateral, _accountDebt, price, decimals, totalLiquidationDiscount)
        ) revert wrongLiquidationAmount();

        return (
            collateralToLiquidate,
            (collateralToLiquidateWithoutDiscount * LIQUIDATION_SURCHARGE) / Constants.PRECISION
        );
    }

    /**
     * @dev calculate the current liquidation discount for a given account
     * @return liquidationDiscount -- the discount applied to the price of the user's collateral. If 100 TAU of debt are liquidated, 100 * liquidationDiscount / PRECISION collateral 
     will be liquidated.
     * note that the calculated discount includes the liquidation surcharge, so not all of the discounted funds will be sent to the liquidator.
     * note that the discount cannot exceed MAX_LIQ_DISCOUNT.
     * The liquidation discount may be any value in the range of (PRECISION, MAX_LIQ_DISCOUNT]. 
     */
    function _calcLiquidationDiscount(uint256 _accountHealth) internal pure returns (uint256 liquidationDiscount) {
        if (_accountHealth >= MIN_COL_RATIO) {
            revert cannotLiquidateHealthyAccount();
        }

        // The liquidator's discount on user funds is based on how far underwater the position is, to simulate a dutch auction.
        // The discount is capped at MAX_LIQ_DISCOUNT.
        uint256 diff = (MIN_COL_RATIO + LIQUIDATION_SURCHARGE) - _accountHealth;
        if (diff > MAX_LIQ_DISCOUNT) {
            diff = MAX_LIQ_DISCOUNT;
        }

        liquidationDiscount = Constants.PRECISION + diff;
    }

    /**
     * @dev Updates a user's rewards. Callable by anyone, but really only useful for keepers
     *  to update inactive accounts (thus redistributing their excess rewards to the vault).
     * @param _account is the account whose rewards will be updated
     */
    function updateRewards(address _account) external whenNotPaused updateReward(_account) {}

    function _authorizeUpgrade(address newImplementation) internal virtual override onlyGovernor {}

    uint256[48] private __gap;
}