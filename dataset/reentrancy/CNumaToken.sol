// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import "./CErc20Immutable.sol";

import "@openzeppelin/contracts_5.0.2/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts_5.0.2/utils/structs/EnumerableSet.sol";
import "../interfaces/INumaVault.sol";
import "./INumaLeverageStrategy.sol";

/**
 * @title CNumaToken
 * @notice CTokens used with numa vault
 * @author
 */
contract CNumaToken is CErc20Immutable {
    INumaVault public vault;

    uint constant max_strategy = 10;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet leverageStrategies;

    /// @notice set vault event
    event SetVault(address vaultAddress);
    /// @notice open leverage event
    event LeverageOpen(
        CNumaToken indexed _collateral,
        uint _suppliedAmount,
        uint _borrowAmountVault,
        uint _borrowAmount
    );
    /// @notice close leverage event
    event LeverageClose(CNumaToken indexed _collateral, uint _borrowtorepay);
    event RemovedStrategy(address);
    event AddedStrategy(address);

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin");
        _;
    }
    constructor(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint fullUtilizationRate_,
        address payable admin_,
        address _vault
    )
        CErc20Immutable(
            underlying_,
            comptroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_,
            fullUtilizationRate_,
            admin_
        )
    {
        vault = INumaVault(_vault);
    }

    function setVault(address _vault) external onlyAdmin {
        vault = INumaVault(_vault);
        emit SetVault(_vault);
    }

    /**
     * @dev returns vaults list
     */
    function getLeverageStrategies() external view returns (address[] memory) {
        return leverageStrategies.values();
    }

    /**
     * @dev adds a leverage strategy
     */
    function addStrategy(address _strategy) external onlyAdmin {
        require(
            leverageStrategies.length() < max_strategy,
            "too many strategies"
        );
        require(leverageStrategies.add(_strategy), "already in list");
        emit AddedStrategy(_strategy);
    }

    /**
     * @dev removes a leverage strategy
     */
    function removeStrategy(address _strategy) external onlyAdmin {
        require(leverageStrategies.contains(_strategy), "not in list");
        leverageStrategies.remove(_strategy);
        emit RemovedStrategy(_strategy);
    }
    function isStrategy(address _addy) public view returns (bool) {
        return (leverageStrategies.contains(_addy));
    }

    // function borrowOnBehalf(uint borrowAmount,address payable borrower,address payable receiver) internal nonReentrant {
    //     accrueInterest();
    //     // borrowFresh emits borrow-specific logs on errors, so we don't need to
    //     borrowFreshOnBehalf(borrower,receiver, borrowAmount);
    // }

    function borrowInternalNoTransfer(
        uint borrowAmount,
        address borrower
    ) internal nonReentrant {
        accrueInterest();
        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        borrowFreshNoTransfer(payable(borrower), borrowAmount);
    }

    function getAmountIn(
        uint256 _amount,
        bool _closePosition,
        uint _strategyIndex
    ) external view returns (uint256) {
        INumaLeverageStrategy strat = INumaLeverageStrategy(
            leverageStrategies.at(_strategyIndex)
        );
        return strat.getAmountIn(_amount, _closePosition);
    }

    /**
     * @notice leverage by depositing and borrowing
     * LTV will be _borrowAmount/(_borrowAmount+_suppliedAmount)
     * 1) flash borrow _collateral.underlying from vault (will be repaid at the end of the function)
     * 2) deposit as collateral (mint input CNumaToken), send minted Ctoken to sender
     * 3) borrow other token using collateral
     * 4) convert to other token using vault
     * 5) flash repay vault
     *
     */
    function leverageStrategy(
        uint _suppliedAmount,
        uint _borrowAmount,
        CNumaToken _collateral,
        uint _strategyIndex
    ) external {
        // AUDITV2FIX if we don't do that, borrow balance might change when calling borrowinternal
        accrueInterest();
        _collateral.accrueInterest();

        INumaLeverageStrategy strat = INumaLeverageStrategy(
            leverageStrategies.at(_strategyIndex)
        );
        address underlyingCollateral = _collateral.underlying();

        // borrow from vault
        vault.borrowLeverage(_borrowAmount, false);

        // get user tokens
        SafeERC20.safeTransferFrom(
            IERC20(underlyingCollateral),
            msg.sender,
            address(this),
            _suppliedAmount
        );
        uint totalAmount = _suppliedAmount + _borrowAmount;

        // supply (mint collateral)
        uint balCtokenBefore = EIP20Interface(address(_collateral)).balanceOf(
            address(this)
        );
        EIP20Interface(underlyingCollateral).approve(
            address(_collateral),
            totalAmount
        );
        _collateral.mint(totalAmount);
        uint balCtokenAfter = EIP20Interface(address(_collateral)).balanceOf(
            address(this)
        );

        // send collateral to sender
        uint receivedtokens = balCtokenAfter - balCtokenBefore;
        require(receivedtokens > 0, "no collateral");

        // transfer collateral to sender
        SafeERC20.safeTransfer(
            IERC20(address(_collateral)),
            msg.sender,
            receivedtokens
        );

        // how much to we need to borrow to repay vault
        uint borrowAmount = strat.getAmountIn(_borrowAmount, false);
        //

        uint accountBorrowBefore = accountBorrows[msg.sender].principal;
        // borrow but do not transfer borrowed tokens
        borrowInternalNoTransfer(borrowAmount, msg.sender);
        //uint accountBorrowAfter = accountBorrows[msg.sender].principal;
        require(
            (accountBorrows[msg.sender].principal - accountBorrowBefore) ==
                borrowAmount,
            "borrow ko"
        );

        // swap
        EIP20Interface(underlying).approve(address(strat), borrowAmount);
        (uint collateralReceived, uint unUsedInput) = strat.swap(
            borrowAmount,
            _borrowAmount,
            false
        );

        // repay flashloan
        EIP20Interface(underlyingCollateral).approve(
            address(vault),
            _borrowAmount
        );
        vault.repayLeverage(false);

        //refund if more collateral is received than needed
        if (collateralReceived > _borrowAmount) {
            // send back the surplus
            SafeERC20.safeTransfer(
                IERC20(underlyingCollateral),
                msg.sender,
                collateralReceived - _borrowAmount
            );
        }
        if (unUsedInput > 0) {
            // we did not use all that was borrowed
            // so we can repay that borrow
            repayBorrowFresh(address(this), msg.sender, unUsedInput);
        }
        emit LeverageOpen(
            _collateral,
            _suppliedAmount,
            _borrowAmount,
            borrowAmount
        );
    }

    function closeLeverageAmount(
        CNumaToken _collateral,
        uint _borrowtorepay,
        uint _strategyIndex
    ) public view returns (uint, uint) {
        INumaLeverageStrategy strat = INumaLeverageStrategy(
            leverageStrategies.at(_strategyIndex)
        );
        // amount of underlying needed
        uint swapAmountIn = strat.getAmountIn(_borrowtorepay, true);

        // amount of ctokens to redeem this amount
        Exp memory exchangeRate = Exp({
            mantissa: _collateral.exchangeRateStored()
        });

        uint cTokenAmount = div_(swapAmountIn, exchangeRate);
        return (cTokenAmount, swapAmountIn);
    }

    function closeLeverageStrategy(
        CNumaToken _collateral,
        uint _borrowtorepay,
        uint _strategyIndex
    ) external {
        // AUDITV2FIX
        accrueInterest();
        _collateral.accrueInterest();

        INumaLeverageStrategy strat = INumaLeverageStrategy(
            leverageStrategies.at(_strategyIndex)
        );
        address underlyingCollateral = _collateral.underlying();
        // get borrowed amount
        uint borrowAmountFull = borrowBalanceStored(msg.sender);
        require(borrowAmountFull >= _borrowtorepay, "no borrow");

        // clip to borrowed amount
        if (_borrowtorepay > borrowAmountFull)
            _borrowtorepay = borrowAmountFull;

        // flashloan
        vault.borrowLeverage(_borrowtorepay, true);

        // repay borrow
        repayBorrowFresh(address(this), msg.sender, _borrowtorepay);

        // amount of underlying needed
        (uint cTokenAmount, uint swapAmountIn) = closeLeverageAmount(
            _collateral,
            _borrowtorepay,
            _strategyIndex
        );

        SafeERC20.safeTransferFrom(
            IERC20(address(_collateral)),
            msg.sender,
            address(this),
            cTokenAmount
        );
        // redeem to underlying
        uint balBefore = IERC20(underlyingCollateral).balanceOf(address(this));
        _collateral.redeemUnderlying(swapAmountIn);
        uint balAfter = IERC20(underlyingCollateral).balanceOf(address(this));
        uint received = balAfter - balBefore;
        require(received >= swapAmountIn, "not enough redeem");
        // swap to get enough token to repay flashlon
        EIP20Interface(underlyingCollateral).approve(
            address(strat),
            swapAmountIn
        );
        (uint bought, uint unusedAmount) = strat.swap(
            swapAmountIn,
            _borrowtorepay,
            true
        );

        // repay FLASHLOAN
        EIP20Interface(underlying).approve(address(vault), _borrowtorepay);
        vault.repayLeverage(true);

        // send what has not been swapped to msg.sender (surplus)
        if (bought > _borrowtorepay) {
            // send back the surplus
            SafeERC20.safeTransfer(
                IERC20(underlying),
                msg.sender,
                bought - _borrowtorepay
            );
        }
        // send also collateral that was not needed
        if (unusedAmount > 0) {
            SafeERC20.safeTransfer(
                IERC20(underlyingCollateral),
                msg.sender,
                unusedAmount
            );
        }
        emit LeverageClose(_collateral, _borrowtorepay);
    }
    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        CTokenInterface cTokenCollateral
    ) external override returns (uint) {
        // only vault can liquidate
        require(msg.sender == address(vault), "vault only");
        liquidateBorrowInternal(borrower, repayAmount, cTokenCollateral);
        return NO_ERROR;
    }

    function liquidateBadDebt(
        address borrower,
        uint repayAmount,
        uint percentageToTake,
        CTokenInterface cTokenCollateral
    ) external override returns (uint) {
        // only vault can liquidate
        require(msg.sender == address(vault), "vault only");
        liquidateBadDebtInternal(
            borrower,
            repayAmount,
            percentageToTake,
            cTokenCollateral
        );
        return NO_ERROR;
    }
}
