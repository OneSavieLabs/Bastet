// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../interfaces/IVault.sol";
import "../interfaces/IPosition.sol";
import "../storage/Position.sol";
import "../storage/UpdatePositionMargin.sol";
import "../storage/UpdateLeverage.sol";
import "../storage/UuidCreator.sol";
import "../storage/Order.sol";
import "./OracleProcess.sol";
import "./LpPoolProcess.sol";
import "./FeeProcess.sol";
import "./VaultProcess.sol";
import "./AccountProcess.sol";

library PositionMarginProcess {
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedSafeMath for int256;
    using Math for uint256;
    using Position for Position.Props;
    using Account for Account.Props;
    using AccountProcess for Account.Props;

    bytes32 constant UPDATE_MARGIN_ID_KEY = keccak256("UPDATE_MARGIN_ID_KEY");
    bytes32 constant UPDATE_LEVERAGE_ID_KEY = keccak256("UPDATE_LEVERAGE_ID_KEY");

    event CreateUpdateLeverageEvent(uint256 indexed requestId, UpdateLeverage.Request data);
    event CreateUpdatePositionMarginEvent(uint256 indexed requestId, UpdatePositionMargin.Request data);
    event UpdatePositionMarginSuccessEvent(uint256 indexed requestId, UpdatePositionMargin.Request data);
    event UpdateLeverageSuccessEvent(uint256 indexed requestId, UpdateLeverage.Request data);
    event CancelUpdateLeverageEvent(uint256 indexed requestId, UpdateLeverage.Request data, bytes32 reasonCode);
    event CancelUpdatePositionMarginEvent(
        uint256 indexed requestId,
        UpdatePositionMargin.Request data,
        bytes32 reasonCode
    );

    struct AddPositionMarginCache {
        address stakeToken;
        uint256 addMarginAmount;
        uint256 marginTokenPrice;
        uint8 marginTokenDecimals;
        bool isCrossMargin;
        uint256 addInitialMarginFromBalance;
    }

    function createUpdatePositionMarginRequest(
        address account,
        IPosition.UpdatePositionMarginParams memory params,
        uint256 updateMarginAmount,
        bool isExecutionFeeFromTradeVault
    ) external {
        uint256 requestId = UuidCreator.nextId(UPDATE_MARGIN_ID_KEY);
        UpdatePositionMargin.Request storage request = UpdatePositionMargin.create(requestId);
        request.account = account;
        request.positionKey = params.positionKey;
        request.marginToken = params.marginToken;
        request.updateMarginAmount = updateMarginAmount;
        request.isAdd = params.isAdd;
        request.isExecutionFeeFromTradeVault = isExecutionFeeFromTradeVault;
        request.executionFee = params.executionFee;
        request.lastBlock = ChainUtils.currentBlock();
        emit CreateUpdatePositionMarginEvent(requestId, request);
    }

    function createUpdateLeverageRequest(
        address account,
        IPosition.UpdateLeverageParams memory params,
        uint256 addMarginAmount,
        bool isExecutionFeeFromTradeVault
    ) external {
        uint256 requestId = UuidCreator.nextId(UPDATE_LEVERAGE_ID_KEY);
        UpdateLeverage.Request storage request = UpdateLeverage.create(requestId);
        request.account = account;
        request.symbol = params.symbol;
        request.marginToken = params.marginToken;
        request.addMarginAmount = addMarginAmount;
        request.leverage = params.leverage;
        request.isLong = params.isLong;
        request.isExecutionFeeFromTradeVault = isExecutionFeeFromTradeVault;
        request.executionFee = params.executionFee;
        request.lastBlock = ChainUtils.currentBlock();
        request.isCrossMargin = params.isCrossMargin;

        emit CreateUpdateLeverageEvent(requestId, request);
    }

    function updatePositionMargin(uint256 requestId, UpdatePositionMargin.Request memory request) external {
        Position.Props storage position = Position.load(request.positionKey);
        position.checkExists();
        if (position.isCrossMargin) {
            revert Errors.OnlyIsolateSupported();
        }
        if (request.marginToken != position.marginToken) {
            revert Errors.TokenIsNotSupport();
        }
        Symbol.Props memory symbolProps = Symbol.load(position.symbol);
        Account.Props storage accountProps = Account.load(request.account);
        if (request.isAdd) {
            AddPositionMarginCache memory cache;
            cache.stakeToken = symbolProps.stakeToken;
            cache.addMarginAmount = request.updateMarginAmount;
            cache.marginTokenDecimals = TokenUtils.decimals(position.marginToken);
            cache.marginTokenPrice = OracleProcess.getLatestUsdUintPrice(position.marginToken, !position.isLong);
            cache.isCrossMargin = false;
            _executeAddMargin(position, cache);
            VaultProcess.transferOut(
                IVault(address(this)).getTradeVaultAddress(),
                request.marginToken,
                symbolProps.stakeToken,
                cache.addMarginAmount
            );
            position.emitPositionUpdateEvent(requestId, Position.PositionUpdateFrom.ADD_MARGIN, 0);
        } else {
            uint256 reduceMarginAmount = _executeReduceMargin(position, symbolProps, request.updateMarginAmount, true);
            VaultProcess.transferOut(symbolProps.stakeToken, request.marginToken, request.account, reduceMarginAmount);
            position.emitPositionUpdateEvent(requestId, Position.PositionUpdateFrom.DECREASE_MARGIN, 0);
        }
        Order.updateAllOrderLeverage(
            accountProps.getAllOrders(),
            position.symbol,
            position.marginToken,
            position.leverage,
            position.isLong,
            position.isCrossMargin
        );
        UpdatePositionMargin.remove(requestId);
        emit UpdatePositionMarginSuccessEvent(requestId, request);
    }

    function updatePositionLeverage(uint256 requestId, UpdateLeverage.Request memory request) external {
        bytes32 positionKey = Position.getPositionKey(
            request.account,
            request.symbol,
            request.marginToken,
            request.isCrossMargin
        );

        Position.Props storage position = Position.load(positionKey);
        if (position.leverage == request.leverage) {
            revert Errors.UpdateLeverageWithNoChange();
        }

        Symbol.Props memory symbolProps = Symbol.load(request.symbol);
        Account.Props storage accountProps = Account.load(request.account);

        if (position.qty != 0) {
            if (position.leverage > request.leverage) {
                AddPositionMarginCache memory cache;
                cache.stakeToken = symbolProps.stakeToken;
                cache.marginTokenDecimals = TokenUtils.decimals(request.marginToken);
                cache.marginTokenPrice = OracleProcess.getLatestUsdUintPrice(position.marginToken, !position.isLong);
                cache.isCrossMargin = position.isCrossMargin;
                if (cache.isCrossMargin) {
                    position.leverage = request.leverage;
                    uint256 newInitialMarginInUsd = CalUtils.divRate(position.qty, position.leverage);
                    uint256 addMarginInUsd = newInitialMarginInUsd > position.initialMarginInUsd
                        ? newInitialMarginInUsd - position.initialMarginInUsd
                        : 0;
                    if (addMarginInUsd.toInt256() > accountProps.getCrossAvailableValue()) {
                        revert Errors.BalanceNotEnough(request.account, position.marginToken);
                    }
                    cache.addMarginAmount = CalUtils.usdToToken(
                        addMarginInUsd,
                        cache.marginTokenDecimals,
                        cache.marginTokenPrice
                    );
                    cache.addInitialMarginFromBalance = CalUtils.tokenToUsd(
                        cache.addMarginAmount.min(accountProps.getAvailableTokenAmount(position.marginToken)),
                        cache.marginTokenDecimals,
                        cache.marginTokenPrice
                    );
                    accountProps.useToken(
                        position.marginToken,
                        cache.addMarginAmount,
                        false,
                        Account.UpdateSource.UPDATE_POSITION_MARGIN
                    );
                } else {
                    cache.addMarginAmount = request.addMarginAmount;
                }
                _executeAddMargin(position, cache);
                if (!cache.isCrossMargin) {
                    VaultProcess.transferOut(
                        IVault(address(this)).getTradeVaultAddress(),
                        position.marginToken,
                        symbolProps.stakeToken,
                        cache.addMarginAmount
                    );
                }
                position.emitPositionUpdateEvent(requestId, Position.PositionUpdateFrom.DECREASE_LEVERAGE, 0);
            } else {
                position.leverage = request.leverage;
                uint256 reduceMargin = position.initialMarginInUsd - CalUtils.divRate(position.qty, position.leverage);
                uint256 reduceMarginAmount = _executeReduceMargin(position, symbolProps, reduceMargin, false);
                if (position.isCrossMargin) {
                    accountProps.unUseToken(
                        position.marginToken,
                        reduceMarginAmount,
                        Account.UpdateSource.UPDATE_LEVERAGE
                    );
                } else {
                    VaultProcess.transferOut(
                        symbolProps.stakeToken,
                        request.marginToken,
                        request.account,
                        reduceMarginAmount
                    );
                }
                position.emitPositionUpdateEvent(requestId, Position.PositionUpdateFrom.INCREASE_LEVERAGE, 0);
            }
        }

        Order.updateAllOrderLeverage(
            accountProps.getAllOrders(),
            request.symbol,
            request.marginToken,
            request.leverage,
            request.isLong,
            request.isCrossMargin
        );

        UpdateLeverage.remove(requestId);

        emit UpdateLeverageSuccessEvent(requestId, request);
    }

    function cancelUpdatePositionMarginRequest(
        uint256 requestId,
        UpdatePositionMargin.Request memory request,
        bytes32 reasonCode
    ) external {
        if (request.isAdd) {
            VaultProcess.transferOut(
                IVault(address(this)).getTradeVaultAddress(),
                request.marginToken,
                request.account,
                request.updateMarginAmount
            );
        }
        UpdatePositionMargin.remove(requestId);

        emit CancelUpdatePositionMarginEvent(requestId, request, reasonCode);
    }

    function cancelUpdateLeverageRequest(
        uint256 requestId,
        UpdateLeverage.Request memory request,
        bytes32 reasonCode
    ) external {
        bytes32 positionKey = Position.getPositionKey(
            request.account,
            request.symbol,
            request.marginToken,
            request.isCrossMargin
        );
        Position.Props storage position = Position.load(positionKey);
        if (request.addMarginAmount > 0 && !position.isCrossMargin) {
            VaultProcess.transferOut(
                IVault(address(this)).getTradeVaultAddress(),
                request.marginToken,
                request.account,
                request.addMarginAmount
            );
        }
        UpdateLeverage.remove(requestId);

        emit CancelUpdateLeverageEvent(requestId, request, reasonCode);
    }

    function updateAllPositionFromBalanceMargin(
        uint256 requestId,
        address account,
        address token,
        int256 amount,
        bytes32 originPositionKey
    ) external {
        if (amount == 0) {
            return;
        }
        bytes32[] memory positionKeys = Account.load(account).getAllPosition();
        int256 reduceAmount = amount;
        for (uint256 i; i < positionKeys.length; i++) {
            Position.Props storage position = Position.load(positionKeys[i]);
            if (token == position.marginToken && position.isCrossMargin) {
                int256 changeAmount = updatePositionFromBalanceMargin(
                    position,
                    originPositionKey.length > 0 && originPositionKey == position.key,
                    requestId,
                    amount
                ).toInt256();
                reduceAmount = amount > 0 ? reduceAmount - changeAmount : reduceAmount + changeAmount;
                if (reduceAmount == 0) {
                    break;
                }
            }
        }
    }

    function updatePositionFromBalanceMargin(
        Position.Props storage position,
        bool needSendEvent,
        uint256 requestId,
        int256 amount
    ) public returns (uint256 changeAmount) {
        if (position.initialMarginInUsd == position.initialMarginInUsdFromBalance || amount == 0) {
            changeAmount = 0;
            return 0;
        }
        if (amount > 0) {
            uint256 borrowMargin = (position.initialMarginInUsd - position.initialMarginInUsdFromBalance)
                .mul(position.initialMargin)
                .div(position.initialMarginInUsd);
            changeAmount = amount.toUint256().min(borrowMargin);
            position.initialMarginInUsdFromBalance += changeAmount.mul(position.initialMarginInUsd).div(
                position.initialMargin
            );
        } else {
            uint256 addBorrowMarginInUsd = (-amount).toUint256().mul(position.initialMarginInUsd).div(
                position.initialMargin
            );
            if (position.initialMarginInUsdFromBalance <= addBorrowMarginInUsd) {
                position.initialMarginInUsdFromBalance = 0;
                changeAmount = position.initialMarginInUsdFromBalance.mul(position.initialMargin).div(
                    position.initialMarginInUsd
                );
            } else {
                position.initialMarginInUsdFromBalance -= addBorrowMarginInUsd;
                changeAmount = (-amount).toUint256();
            }
        }
        if (needSendEvent && changeAmount > 0) {
            position.emitPositionUpdateEvent(requestId, Position.PositionUpdateFrom.DEPOSIT, 0);
        }
    }

    function _executeAddMargin(Position.Props storage position, AddPositionMarginCache memory cache) internal {
        if (
            cache.addMarginAmount >
            CalUtils.usdToToken(
                position.qty - position.initialMarginInUsd,
                cache.marginTokenDecimals,
                cache.marginTokenPrice
            )
        ) {
            revert Errors.AddMarginTooBig();
        }
        position.initialMargin += cache.addMarginAmount;
        if (cache.isCrossMargin) {
            position.initialMarginInUsd = CalUtils.divRate(position.qty, position.leverage);
            position.initialMarginInUsdFromBalance += cache.addInitialMarginFromBalance;
        } else {
            position.initialMarginInUsd += CalUtils.tokenToUsd(
                cache.addMarginAmount,
                cache.marginTokenDecimals,
                cache.marginTokenPrice
            );
            position.leverage = CalUtils.divRate(position.qty, position.initialMarginInUsd);
            position.initialMarginInUsdFromBalance = position.initialMarginInUsd;
        }

        uint256 subHoldAmount = cache.addMarginAmount.min(position.holdPoolAmount);
        position.holdPoolAmount -= subHoldAmount;
        LpPoolProcess.updatePnlAndUnHoldPoolAmount(cache.stakeToken, position.marginToken, subHoldAmount, 0, 0);
    }

    function _executeReduceMargin(
        Position.Props storage position,
        Symbol.Props memory symbolProps,
        uint256 reduceMargin,
        bool needUpdateLeverage
    ) internal returns (uint256) {
        AppConfig.SymbolConfig memory symbolConfig = AppConfig.getSymbolConfig(symbolProps.code);
        uint256 maxReduceMarginInUsd = position.initialMarginInUsd -
            CalUtils.divRate(position.qty, symbolConfig.maxLeverage).max(
                AppTradeConfig.getTradeConfig().minOrderMarginUSD
            );
        if (reduceMargin > maxReduceMarginInUsd) {
            revert Errors.ReduceMarginTooBig();
        }
        uint8 decimals = TokenUtils.decimals(position.marginToken);
        uint256 marginTokenPrice = OracleProcess.getLatestUsdUintPrice(position.marginToken, !position.isLong);
        uint256 reduceMarginAmount = CalUtils.usdToToken(reduceMargin, decimals, marginTokenPrice);
        if (
            position.isCrossMargin &&
            position.initialMarginInUsd - position.initialMarginInUsdFromBalance < reduceMargin
        ) {
            position.initialMarginInUsdFromBalance -= (reduceMargin -
                (position.initialMarginInUsd - position.initialMarginInUsdFromBalance)).max(0);
        }
        position.initialMargin -= reduceMarginAmount;
        position.initialMarginInUsd -= reduceMargin;
        if (needUpdateLeverage) {
            position.leverage = CalUtils.divRate(position.qty, position.initialMarginInUsd);
        }
        if (!position.isCrossMargin) {
            position.initialMarginInUsdFromBalance = position.initialMarginInUsd;
        }

        position.holdPoolAmount += reduceMarginAmount;
        LpPoolProcess.holdPoolAmount(symbolProps.stakeToken, position.marginToken, reduceMarginAmount, position.isLong);
        return reduceMarginAmount;
    }
}
