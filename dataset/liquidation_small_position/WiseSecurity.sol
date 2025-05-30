// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.24;

/**
 * @author Christoph Krpoun
 * @author René Hochmuth
 * @author Vitally Marinchenko
 */

import "./WiseSecurityHelper.sol";
import "../TransferHub/ApprovalHelper.sol";

/**
 * @dev WiseSecurity is a core contract for wiseLending including most of
 * the performed security checks for withdraws, borrows, paybacks and liquidations.
 * It also has several read only functions providing UI data for a better user
 * experiencne.
 *
 */

error NotWiseLendingSecurity();

contract WiseSecurity is WiseSecurityHelper, ApprovalHelper {

    modifier onlyWiseLending() {
        _onlyWiseLending();
        _;
    }

    function _onlyWiseLending()
        private
        view
    {
        if (msg.sender == address(WISE_LENDING)) {
            return;
        }

        revert NotWiseLendingSecurity();
    }

    constructor(
        address _master,
        address _wiseLendingAddress,
        address _aaveHubAddress
    )
        WiseSecurityDeclarations(
            _master,
            _wiseLendingAddress,
            _aaveHubAddress
        )
    {}

    /**
     * @dev View functions returning current
     * debt ratio of a postion in normal mode.
     * 1% <=> 1E16
     */
    function getLiveDebtRatio(
        uint256 _nftId
    )
        external
        view
        returns (uint256)
    {
        uint256 overallCollateral = overallETHCollateralsWeighted(
            _nftId
        );

        if (overallCollateral == 0) {
            return 0;
        }

        return overallETHBorrow(_nftId)
            * PRECISION_FACTOR_E18
            / overallCollateral;
    }

    /**
     * @dev Set Liquidation incentives and boundaries
     * for liquidation. Only callable by the master.
     * Assures liquidation cascade cannot be self imposed
     * by limiting incentives.
     */
    function setLiquidationSettings(
        uint256 _baseReward,
        uint256 _baseRewardFarm,
        uint256 _newMaxFeeETH,
        uint256 _newMaxFeeFarmETH
    )
        external
        onlyMaster
    {
        _setLiquidationSettings(
            _baseReward,
            _baseRewardFarm,
            _newMaxFeeETH,
            _newMaxFeeFarmETH
        );
    }

    /**
     * @dev Checks for liquidation logic.
     */
    function checksLiquidation(
        uint256 _nftIdLiquidate,
        address _tokenToPayback,
        uint256 _shareAmountToPay
    )
        external
        view
    {
        (
            uint256 weightedCollateralETH,
            uint256 unweightedCollateralETH

        ) = overallETHCollateralsBoth(
            _nftIdLiquidate
        );

        uint256 borrowETHTotal = overallETHBorrowHeartbeat(
            _nftIdLiquidate
        );

        canLiquidate(
            borrowETHTotal,
            weightedCollateralETH
        );

        checkMaxShares(
            _nftIdLiquidate,
            _tokenToPayback,
            borrowETHTotal,
            unweightedCollateralETH,
            _shareAmountToPay
        );
    }

    /**
     * @dev Set function for preparing curve pools.
     */
    function prepareCurvePools(
        address _poolToken,
        CurveSwapStructData calldata _curveSwapStructData,
        CurveSwapStructToken calldata _curveSwapStructToken
    )
        external
        onlyWiseLending
    {
        curveSwapInfoData[_poolToken] = _curveSwapStructData;
        curveSwapInfoToken[_poolToken] = _curveSwapStructToken;

        address curvePool = curveSwapInfoData[_poolToken].curvePool;
        uint256 tokenIndexForApprove = _curveSwapStructToken.curvePoolTokenIndexFrom;

        _safeApprove(
            ICurve(curvePool).coins(tokenIndexForApprove),
            curvePool,
            0
        );

        _safeApprove(
            ICurve(curvePool).coins(tokenIndexForApprove),
            curvePool,
            UINT256_MAX
        );

        address curveMetaPool = curveSwapInfoData[_poolToken].curveMetaPool;

        if (curveMetaPool == ZERO_ADDRESS) {
            return;
        }

        tokenIndexForApprove = _curveSwapStructToken.curveMetaPoolTokenIndexFrom;

        _safeApprove(
            ICurve(curveMetaPool).coins(tokenIndexForApprove),
            curveMetaPool,
            0
        );

        _safeApprove(
            ICurve(curveMetaPool).coins(tokenIndexForApprove),
            curveMetaPool,
            UINT256_MAX
        );
    }

    /**
     * @dev Reentrency guard for curve pools. Forces
     * a swap to update internal curve values.
     */
    function curveSecurityCheck(
        address _poolToken
    )
        external
        onlyWiseLending
    {
        address curvePool = curveSwapInfoData[_poolToken].curvePool;

        if (curvePool == ZERO_ADDRESS) {
            return;
        }

        (
            bool success
            ,
        ) = curvePool.call{value: 0} (
            curveSwapInfoData[_poolToken].swapBytesPool
        );

        _checkSuccess(
            success
        );

        address curveMeta = curveSwapInfoData[_poolToken].curveMetaPool;

        if (curveMeta == ZERO_ADDRESS) {
            return;
        }

        (
            success
            ,
        ) = curveMeta.call{value: 0} (
            curveSwapInfoData[_poolToken].swapBytesMeta
        );

        _checkSuccess(
            success
        );
    }

    /**
     * @dev Checks for withdraw logic.
     */
    function checksWithdraw(
        uint256 _nftId,
        address _caller,
        address _poolToken
    )
        external
        view
        returns (bool specialCase)
    {
        if (_checkBlacklisted(_poolToken) == true) {

            if (overallETHBorrowBare(_nftId) > 0) {
                revert OpenBorrowPosition();
            }

            return true;
        }

        if (WISE_LENDING.verifiedIsolationPool(_caller) == true) {
            return true;
        }

        if (WISE_LENDING.positionLocked(_nftId) == true) {
            return true;
        }

        if (_isUncollateralized(_nftId, _poolToken) == true) {
            return true;
        }

        if (WISE_LENDING.getPositionBorrowTokenLength(_nftId) == 0) {
            return true;
        }
    }

    /**
     * @dev Checks for solely withdraw logic.
     */
    function checksSolelyWithdraw(
        uint256 _nftId,
        address _caller,
        address _poolToken
    )
        external
        view
        returns (bool specialCase)
    {
        if (_checkBlacklisted(_poolToken) == true) {

            if (overallETHBorrowBare(_nftId) > 0) {
                revert OpenBorrowPosition();
            }

            return true;
        }

        if (WISE_LENDING.verifiedIsolationPool(_caller) == true) {
            return true;
        }

        if (WISE_LENDING.positionLocked(_nftId) == true) {
            return true;
        }

    }

    /**
     * @dev Checks for borrow logic.
     */
    function checksBorrow(
        uint256 _nftId,
        address _caller,
        address _poolToken
    )
        external
        view
        returns (bool specialCase)
    {
        _checkPoolCondition(
            _poolToken
        );

        checkTokenAllowed(
            _poolToken
        );

        if (WISE_LENDING.verifiedIsolationPool(_caller) == true) {
            return true;
        }

        if (WISE_LENDING.positionLocked(_nftId) == true) {
            return true;
        }
    }

    /**
     * @dev Checks for collateralize deposit logic.
     */
    function checksCollateralizeDeposit(
        uint256 _nftId,
        address _caller,
        address _poolAddress
    )
        external
        view
    {
        if (checkHeartbeat(_poolAddress) == false) {
            revert ChainlinkDead();
        }

        _checkPoolCondition(
            _poolAddress
        );

        checkOwnerPosition(
            _nftId,
            _caller
        );
    }

    /**
     * @dev Checks for uncollateralized deposit logic.
     */
    function checkUncollateralizedDeposit(
        uint256 _nftId,
        address _poolToken
    )
        external
        view
    {
        if (_checkBlacklisted(_poolToken) == true) {

            if (overallETHBorrowBare(_nftId) > 0) {
                revert OpenBorrowPosition();
            }

            return;
        }

        _checkHealthState(
            {
                _nftId: _nftId,
                _powerFarm: false
            }
        );
    }

    /**
     * @dev Checks if user has healthy position.
     */

    function checkHealthState(
        uint256 _nftId,
        bool _isPowerFarm
    )
        external
        view
    {
        _checkHealthState(
            _nftId,
            _isPowerFarm
        );
    }

    /**
     * @dev Checks for bad debt logic. Compares
     * total ETH of borrow and collateral.
     */
    function checkBadDebtLiquidation(
        uint256 _nftId
    )
        external
        onlyWiseLending
    {
        uint256 bareCollateral = overallETHCollateralsBare(
            _nftId
        );

        uint256 totalBorrow = overallETHBorrowBare(
            _nftId
        );

        if (totalBorrow < bareCollateral) {
            return;
        }

        unchecked {
            uint256 diff = totalBorrow
                - bareCollateral;

            FEE_MANAGER.increaseTotalBadDebtLiquidation(
                diff
            );

            FEE_MANAGER.setBadDebtUserLiquidation(
                _nftId,
                diff
            );
        }
    }

    /**
     * @dev View function returning weighted
     * supply APY of a postion. 1% <=> 1E16
     */
    function overallLendingAPY(
        uint256 _nftId
    )
        external
        view
        returns (uint256)
    {
        uint256 len = WISE_LENDING.getPositionLendingTokenLength(
            _nftId
        );

        if (len == 0) {
            return 0;
        }

        uint256 i;
        address token;
        uint256 amount;
        uint256 ethValue;
        uint256 overallETH;
        uint256 weightedRate;

        while (i < len) {

            token = WISE_LENDING.getPositionLendingTokenByIndex(
                _nftId,
                i
            );

            amount = getPositionLendingAmount(
                _nftId,
                token
            );

            ethValue = WISE_ORACLE.getTokensInETH(
                token,
                amount
            );

            weightedRate += ethValue
                * getLendingRate(token);

            overallETH += ethValue;

            unchecked {
                ++i;
            }
        }

        return weightedRate
            / overallETH;
    }

    /**
     * @dev View function returning weighted
     * borrow APY of a postion. 1% <=> 1E16
     */
    function overallBorrowAPY(
        uint256 _nftId
    )
        external
        view
        returns (uint256)
    {
        uint256 len = WISE_LENDING.getPositionBorrowTokenLength(
            _nftId
        );

        if (len == 0) {
            return 0;
        }

        uint256 i;
        address token;
        uint256 amount;
        uint256 ethValue;
        uint256 overallETH;
        uint256 weightedRate;

        while (i < len) {

            token = WISE_LENDING.getPositionBorrowTokenByIndex(
                _nftId,
                i
            );

            amount = getPositionBorrowAmount(
                _nftId,
                token
            );

            ethValue = WISE_ORACLE.getTokensInETH(
                token,
                amount
            );

            weightedRate += ethValue
                * getBorrowRate(token);

            overallETH += ethValue;

            unchecked {
                ++i;
            }
        }

        return weightedRate
            / overallETH;
    }

    /**
     * @dev View function returning the total
     * net APY of a postion. 1% <=> 1E16
     */
    function overallNetAPY(
        uint256 _nftId
    )
        external
        view
        returns (uint256, bool)
    {
        uint256 i;
        address token;
        uint256 ethValue;
        uint256 ethValueDebt;
        uint256 ethValueGain;
        uint256 totalETHSupply;

        uint256 netAPY;

        uint256 lenBorrow = WISE_LENDING.getPositionBorrowTokenLength(
            _nftId
        );

        uint256 lenDeposit = WISE_LENDING.getPositionLendingTokenLength(
            _nftId
        );

        while (i < lenBorrow) {

            token = WISE_LENDING.getPositionBorrowTokenByIndex(
                _nftId,
                i
            );

            ethValue = getETHBorrow(
                _nftId,
                token
            );

            ethValueDebt += ethValue
                * getBorrowRate(token);

            unchecked {
                ++i;
            }
        }

        i = 0;

        while (i < lenDeposit) {

            token = WISE_LENDING.getPositionLendingTokenByIndex(
                _nftId,
                i
            );

            ethValue = getETHCollateral(
                _nftId,
                token
            );

            totalETHSupply += ethValue;
            ethValueGain += ethValue
                * getLendingRate(token);

            unchecked {
                ++i;
            }
        }

        if (ethValueGain >= ethValueDebt) {

            netAPY = (ethValueGain - ethValueDebt)
                / totalETHSupply;

            return (netAPY, false);
        }

        netAPY = (ethValueDebt - ethValueGain)
                / totalETHSupply;

        return (netAPY, true);
    }

    /**
     * @dev View function claculating the open
     * amount a postion is allowed to borrow.
     */
    function safeLimitPosition(
        uint256 _nftId
    )
        external
        view
        returns (uint256)
    {
        uint256 len = WISE_LENDING.getPositionLendingTokenLength(
            _nftId
        );

        if (len == 0) {
            return 0;
        }

        uint256 i;
        address token;
        uint256 buffer;

        while (i < len) {

            token = WISE_LENDING.getPositionLendingTokenByIndex(
                _nftId,
                i
            );

            unchecked {
                ++i;
            }

            if (checkHeartbeat(token) == false) {
                continue;
            }

            if (wasBlacklisted[token] == true) {
                continue;
            }

            buffer += WISE_LENDING.lendingPoolData(token).collateralFactor
                * getFullCollateralETH(
                    _nftId,
                    token
                ) / PRECISION_FACTOR_E18;
        }

        return buffer
            * BORROW_PERCENTAGE_CAP
            / PRECISION_FACTOR_E18;
    }

    /**
     * @dev View function checking if the postion is
     * locked due to blacklisted token.
     */
    function positionBlackListToken(
        uint256 _nftId
    )
        external
        view
        returns (bool, address)
    {
        uint256 lenDeposit = WISE_LENDING.getPositionLendingTokenLength(
            _nftId
        );

        uint256 i;
        address token;

        while (i < lenDeposit) {

            token = WISE_LENDING.getPositionLendingTokenByIndex(
                _nftId,
                i
            );

            if (_checkBlacklisted(token) == true) {
                return (
                    true,
                    token
                );
            }

            unchecked {
                ++i;
            }
        }

        uint256 lenBorrow = WISE_LENDING.getPositionBorrowTokenLength(
            _nftId
        );

        i = 0;

        while (i < lenBorrow) {

            token = WISE_LENDING.getPositionBorrowTokenByIndex(
                _nftId,
                i
            );

            if (_checkBlacklisted(token) == true) {
                return (
                    true,
                    token
                );
            }

            unchecked {
                ++i;
            }
        }

        return (
            false,
            ZERO_ADDRESS
        );
    }

    /**
     * @dev View function extrapolating the
     * possible withdraw amount of a postion
     * for a specific _poolToken.
     */
    function maximumWithdrawToken(
        uint256 _nftId,
        address _poolToken,
        uint256 _interval,
        uint256 _solelyWithdrawAmount
    )
        external
        view
        returns (uint256)
    {
        uint256 withdrawAmount;

        uint256 expectedMaxAmount = getExpectedLendingAmount(
            _nftId,
            _poolToken,
            _interval
        );

        uint256 maxAmountPool = WISE_LENDING.getTotalPool(
            _poolToken
        );

        withdrawAmount = expectedMaxAmount;

        if (expectedMaxAmount > maxAmountPool) {
            withdrawAmount = maxAmountPool;
        }

        if (_isUncollateralized(_nftId, _poolToken) == true) {
            return withdrawAmount;
        }

        uint256 possibelWithdraw = _getPossibleWithdrawAmount(
            _nftId,
            _poolToken,
            _interval
        );

        withdrawAmount = possibelWithdraw;

        if (possibelWithdraw > expectedMaxAmount) {
            withdrawAmount = expectedMaxAmount;
        }

        if (_solelyWithdrawAmount >= withdrawAmount) {
            return 0;
        }

        withdrawAmount = withdrawAmount - _solelyWithdrawAmount;

        if (withdrawAmount > maxAmountPool) {
            return maxAmountPool;
        }

        return withdrawAmount;
    }

    /**
     * @dev View function extrapolating the
     * possible withdraw amount of a private
     * postion for a specific _poolToken.
     */
    function maximumWithdrawTokenSolely(
        uint256 _nftId,
        address _poolToken,
        uint256 _interval,
        uint256 _poolWithdrawAmount
    )
        external
        view
        returns (uint256)
    {
        uint256 tokenAmount = _getPossibleWithdrawAmount(
            _nftId,
            _poolToken,
            _interval
        );

        if (_isUncollateralized(_nftId, _poolToken) == false) {

            if (_poolWithdrawAmount >= tokenAmount) {
                return 0;
            }

            tokenAmount = tokenAmount - _poolWithdrawAmount;
        }

        uint256 maxSolelyAmount = WISE_LENDING.getPureCollateralAmount(
            _nftId,
            _poolToken
        );

        if (tokenAmount > maxSolelyAmount) {
            return maxSolelyAmount;
        }

        return tokenAmount;
    }

    /**
     * @dev View function extrapolating the
     * possible borrow amount of postion for
     * a specific _poolToken.
     */
    function maximumBorrowToken(
        uint256 _nftId,
        address _poolToken,
        uint256 _interval
    )
        external
        view
        returns (uint256 tokenAmount)
    {
        uint256 term = _overallETHCollateralsWeighted(_nftId, _interval)
            * BORROW_PERCENTAGE_CAP
            / PRECISION_FACTOR_E18;

        uint256 borrowETH = term
            - _overallETHBorrow(
                _nftId,
                _interval
            );

        tokenAmount = WISE_ORACLE.getTokensFromETH(
            _poolToken,
            borrowETH
        );

        uint256 maxPoolAmount = WISE_LENDING.getTotalPool(
            _poolToken
        );

        if (tokenAmount > maxPoolAmount) {
            tokenAmount = maxPoolAmount;
        }
    }

    /**
     * @dev View function extrapolating the
     * possible payback amount of a position
     * for a specific _poolToken.
     */
    function getExpectedPaybackAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _interval
    )
        external
        view
        returns (uint256)
    {
        uint256 borrowShares = WISE_LENDING.getPositionBorrowShares(
            _nftId,
            _poolToken
        );

        uint256 currentTotalBorrowShares = WISE_LENDING.getTotalBorrowShares(
            _poolToken
        );

        if (currentTotalBorrowShares == 0) {
            return 0;
        }

        uint256 updatedPseudo = _getUpdatedPseudoBorrow(
            _poolToken,
            _interval
        );

        return borrowShares
            * updatedPseudo
            / currentTotalBorrowShares;
    }

    /**
     * @dev View function extrapolating the
     * possible lending amount of a position
     * for a specific _poolToken.
     */
    function getExpectedLendingAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _interval
    )
        public
        view
        returns (uint256)
    {
        uint256 lendingShares = WISE_LENDING.getPositionLendingShares(
            _nftId,
            _poolToken
        );

        uint256 currentTotalLendingShares = WISE_LENDING.getTotalDepositShares(
            _poolToken
        );

        if (currentTotalLendingShares == 0) {
            return 0;
        }

        uint256 updatedPseudo = _getUpdatedPseudoPool(
            _poolToken,
            _interval
        );

        return lendingShares
            * updatedPseudo
            / currentTotalLendingShares;
    }

    /**
     * @dev Set function for blacklisting token.
     * Those token can not be borrowed or used as
     * collateral anymore. Only callable by master.
     */
    function setBlacklistToken(
        address _tokenAddress,
        bool _state
    )
        external
        onlyMaster()
    {
        wasBlacklisted[_tokenAddress] = _state;
    }

    /**
     * @dev Set function for adding or removing
     * workers to perform a security shutdown.
     * Only callable by the master.
     */
    function setSecurityWorker(
        address _entitiy,
        bool _state
    )
        external
        onlyMaster
    {
        securityWorker[_entitiy] = _state;
    }

    /**
     * Safety function to perform a security
     * shutdown of all active pools. Can be
     * called by the security worker, a
     * special role set by the master.
     */
    function securityShutdown()
        external
    {
        if (securityWorker[msg.sender] == false) {
            revert NotAllowedEntity();
        }

        _setPoolState(
            true
        );

        emit SecurityShutdown(
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @dev Master function to revoke all locks,
     * only callable by the master.
     */
    function revokeShutdown()
        external
        onlyMaster
    {
        _setPoolState(
            false
        );
    }

    /**
     * @dev External wrapper for pool condition
     * check.
     */
    function checkPoolCondition(
        address _token
    )
        external
        view
    {
        _checkPoolCondition(
            _token
        );
    }

    /**
     * @dev External wrapper for pool condition
     * check.
     */
    function checkPoolWithMinDeposit(
        address _token,
        uint256 _amount
    )
        external
        view
        returns (bool)
    {
        _checkPoolCondition(
            _token
        );

        return _checkMinDepositValue(
            _token,
            _amount
        );
    }

    function checkMinDepositValue(
        address _token,
        uint256 _amount
    )
        external
        view
        returns (bool)
    {
        return _checkMinDepositValue(
            _token,
            _amount
        );
    }

    function _checkMinDepositValue(
        address _token,
        uint256 _amount
    )
        private
        view
        returns (bool)
    {
        if (minDepositEthValue == ONE_WEI) {
            return true;
        }

        if (_getTokensInEth(_token, _amount) < minDepositEthValue) {
            revert DepositAmountTooSmall();
        }

        return true;
    }

    function changeMinDepositValue(
        uint256 _newMinDepositValue
    )
        external
        onlyMaster
    {
        if (_newMinDepositValue == 0) {
            revert NoValue();
        }

        minDepositEthValue = _newMinDepositValue;
    }
}
