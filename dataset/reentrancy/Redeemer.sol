// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.19;

import { IERC20 } from "oz/token/ERC20/IERC20.sol";
import { SafeCast } from "oz/utils/math/SafeCast.sol";
import { SafeERC20 } from "oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "oz/utils/math/Math.sol";

import { IAgToken } from "interfaces/IAgToken.sol";
import { IRedeemer } from "interfaces/IRedeemer.sol";

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibHelpers } from "../libraries/LibHelpers.sol";
import { LibGetters } from "../libraries/LibGetters.sol";
import { LibManager } from "../libraries/LibManager.sol";
import { LibStorage as s } from "../libraries/LibStorage.sol";
import { LibWhitelist } from "../libraries/LibWhitelist.sol";

import "../../utils/Constants.sol";
import "../../utils/Errors.sol";
import "../Storage.sol";

/// @title Redeemer
/// @author Angle Labs, Inc.
contract Redeemer is IRedeemer {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    event Redeemed(
        uint256 amount,
        address[] tokens,
        uint256[] amounts,
        address[] forfeitTokens,
        address indexed from,
        address indexed to
    );
    event NormalizerUpdated(uint256 newNormalizerValue);

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                   EXTERNAL ACTIONS                                                 
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRedeemer
    /// @dev The `minAmountOuts` list must reflect or be longer than the amount of `tokens` returned
    /// @dev In normal conditions, the amount of tokens outputted by this function should be the amount
    /// of collateral assets supported by the system, following their order in the `collateralList`.
    /// @dev If one collateral has its liquidity managed through strategies, then it's possible that this asset
    /// has sub-collaterals with it. In this situation, these sub-collaterals may be sent during the redemption
    /// process and the `minAmountOuts` will be bigger than the `collateralList` length. If there are 3 collateral
    /// assets and the 2nd collateral asset in the list (at index 1) consists of 3 sub-collaterals, then the ordering
    /// of the token list will be as follows:
    /// `[collat 1, sub-collat 1 of collat 2, sub-collat 2 of collat 2, sub-collat 3 of collat 2, collat 3]`
    /// @dev The list of tokens outputted (and hence the minimum length of the `minAmountOuts` list) can be obtained
    /// by calling the `quoteRedemptionCurve` function
    /// @dev Tokens requiring a whitelist must be forfeited if the redemption is to an address that is not in the
    /// whitelist, otherwise this function reverts
    /// @dev No approval is needed before calling this function
    function redeem(
        uint256 amount,
        address receiver,
        uint256 deadline,
        uint256[] memory minAmountOuts
    ) external returns (address[] memory tokens, uint256[] memory amounts) {
        return _redeem(amount, receiver, deadline, minAmountOuts, new address[](0));
    }

    /// @inheritdoc IRedeemer
    /// @dev Beware that if a token is given in the `forfeitTokens` list, the redemption will not try to send token
    /// even if it has enough immediately available to send the amount
    function redeemWithForfeit(
        uint256 amount,
        address receiver,
        uint256 deadline,
        uint256[] memory minAmountOuts,
        address[] memory forfeitTokens
    ) external returns (address[] memory tokens, uint256[] memory amounts) {
        return _redeem(amount, receiver, deadline, minAmountOuts, forfeitTokens);
    }

    /// @inheritdoc IRedeemer
    /// @dev This function may be called by trusted addresses: these could be for instance savings contract
    /// minting stablecoins when they notice a profit
    function updateNormalizer(uint256 amount, bool increase) external returns (uint256) {
        if (!LibDiamond.isGovernor(msg.sender) && s.transmuterStorage().isTrusted[msg.sender] == 0) revert NotTrusted();
        return _updateNormalizer(amount, increase);
    }

    /// @inheritdoc IRedeemer
    function quoteRedemptionCurve(
        uint256 amount
    ) external view returns (address[] memory tokens, uint256[] memory amounts) {
        (tokens, amounts, ) = _quoteRedemptionCurve(amount);
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                   INTERNAL HELPERS                                                 
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Internal function of the `redeem` function in the `Redeemer` contract
    function _redeem(
        uint256 amount,
        address to,
        uint256 deadline,
        uint256[] memory minAmountOuts,
        address[] memory forfeitTokens
    ) internal returns (address[] memory tokens, uint256[] memory amounts) {
        TransmuterStorage storage ts = s.transmuterStorage();
        if (ts.isRedemptionLive == 0) revert Paused();
        if (block.timestamp > deadline) revert TooLate();
        uint256[] memory subCollateralsTracker;
        (tokens, amounts, subCollateralsTracker) = _quoteRedemptionCurve(amount);
        // Updating the normalizer enables to simultaneously and proportionally reduce the amount
        // of stablecoins issued from each collateral without having to loop through each of them
        _updateNormalizer(amount, false);

        IAgToken(ts.agToken).burnSelf(amount, msg.sender);

        address[] memory collateralListMem = ts.collateralList;
        uint256 indexCollateral;
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] < minAmountOuts[i]) revert TooSmallAmountOut();
            // If a token is in the `forfeitTokens` list, then it is not sent as part of the redemption process
            if (amounts[i] > 0 && LibHelpers.checkList(tokens[i], forfeitTokens) < 0) {
                Collateral storage collatInfo = ts.collaterals[collateralListMem[indexCollateral]];
                if (collatInfo.onlyWhitelisted > 0 && !LibWhitelist.checkWhitelist(collatInfo.whitelistData, to))
                    revert NotWhitelisted();
                if (collatInfo.isManaged > 0)
                    LibManager.release(tokens[i], to, amounts[i], collatInfo.managerData.config);
                else IERC20(tokens[i]).safeTransfer(to, amounts[i]);
            }
            if (subCollateralsTracker[indexCollateral] - 1 <= i) ++indexCollateral;
        }
        emit Redeemed(amount, tokens, amounts, forfeitTokens, msg.sender, to);
    }

    /// @dev This function reverts if `stablecoinsIssued==0`, which is expected behavior as there is nothing to redeem
    /// anyway in this case, or if the `amountBurnt` is greater than `stablecoinsIssued`
    function _quoteRedemptionCurve(
        uint256 amountBurnt
    )
        internal
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256[] memory subCollateralsTracker)
    {
        TransmuterStorage storage ts = s.transmuterStorage();
        uint64 collatRatio;
        uint256 stablecoinsIssued;
        (collatRatio, stablecoinsIssued, tokens, balances, subCollateralsTracker) = LibGetters.getCollateralRatio();
        if (amountBurnt > stablecoinsIssued) revert TooBigAmountIn();
        int64[] memory yRedemptionCurveMem = ts.yRedemptionCurve;
        uint64 penaltyFactor;
        // If the protocol is under-collateralized, a penalty factor is applied to the returned amount of each asset
        if (collatRatio < BASE_9) {
            uint64[] memory xRedemptionCurveMem = ts.xRedemptionCurve;
            penaltyFactor = uint64(LibHelpers.piecewiseLinear(collatRatio, xRedemptionCurveMem, yRedemptionCurveMem));
        }

        uint256 balancesLength = balances.length;
        for (uint256 i; i < balancesLength; ++i) {
            // The amount given for each token in reserves does not depend on the price of the tokens in reserve:
            // it is a proportion of the balance for each token computed as the ratio between the stablecoins
            // burnt relative to the amount of stablecoins issued.
            // If the protocol is over-collateralized, the amount of each token given is inversely proportional
            // to the collateral ratio.
            balances[i] = collatRatio >= BASE_9
                ? (amountBurnt * balances[i] * (uint64(yRedemptionCurveMem[yRedemptionCurveMem.length - 1]))) /
                    (stablecoinsIssued * collatRatio)
                : (amountBurnt * balances[i] * penaltyFactor) / (stablecoinsIssued * BASE_9);
        }
    }

    /// @notice Updates the `normalizer` variable used to track stablecoins issued from each asset and globally
    function _updateNormalizer(uint256 amount, bool increase) internal returns (uint256 newNormalizerValue) {
        TransmuterStorage storage ts = s.transmuterStorage();
        uint256 _normalizer = ts.normalizer;
        uint256 _normalizedStables = ts.normalizedStables;
        // In case of an increase, the update formula used is the simplified version of the formula below:
        /*
            _normalizer * (BASE_27 + BASE_27 * amount / stablecoinsIssued) / BASE_27
             = _normalizer + (_normalizer * BASE_27 * amount * (BASE_27 / (_normalizedStables * normalizer))) / BASE_27
             = _normalizer + BASE_27 * amount / _normalizedStables
        */
        if (increase) {
            newNormalizerValue = _normalizer + (amount * BASE_27) / _normalizedStables;
        } else {
            newNormalizerValue = _normalizer - (amount * BASE_27) / _normalizedStables;
        }
        // If the `normalizer` gets too small or too big, it must be renormalized to later avoid the propagation of
        // rounding errors, as well as overflows. In this case, the function has to iterate through all the
        // supported collateral assets
        if (newNormalizerValue <= BASE_18 || newNormalizerValue >= BASE_36) {
            address[] memory collateralListMem = ts.collateralList;
            uint256 collateralListLength = collateralListMem.length;
            // For each asset, we store the actual amount of stablecoins issued based on the `newNormalizerValue`
            // (and not a normalized value)
            // We ensure to preserve the invariant `sum(collateralNewNormalizedStables) = normalizedStables`
            uint128 newNormalizedStables = 0;
            for (uint256 i; i < collateralListLength; ++i) {
                uint128 newCollateralNormalizedStable = ((uint256(
                    ts.collaterals[collateralListMem[i]].normalizedStables
                ) * newNormalizerValue) / BASE_27).toUint128();
                newNormalizedStables += newCollateralNormalizedStable;
                ts.collaterals[collateralListMem[i]].normalizedStables = uint216(newCollateralNormalizedStable);
            }
            ts.normalizedStables = newNormalizedStables;
            newNormalizerValue = BASE_27;
        }
        ts.normalizer = newNormalizerValue.toUint128();
        emit NormalizerUpdated(newNormalizerValue);
    }
}
