// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.24;

import {Constants} from "@contracts/global/Constants.sol";
import {TypeConvert} from "@contracts/global/TypeConvert.sol";
import {Deployments} from "@deployments/Deployments.sol";
import {VaultStorage, WithdrawRequest, SplitWithdrawRequest} from "./VaultStorage.sol";

/**
 * Library to handle potentially illiquid withdraw requests of staking tokens where there
 * is some indeterminate lock up time before tokens can be redeemed. Examples would be withdraws
 * of staked or restaked ETH, tokens like sUSDe or stkAave which have cooldown periods before they
 * can be withdrawn.
 *
 * Primarily, this library tracks the withdraw request and an associated identifier for the withdraw
 * request. It also allows for the withdraw request to be "tokenized" so that shares of the withdraw
 * request can be liquidated.
 */
abstract contract WithdrawRequestBase {
    using TypeConvert for int256;

    event InitiateWithdrawRequest(
        address indexed account,
        bool indexed isForced,
        uint256 vaultShares,
        uint256 requestId
    );

    /// @notice Required implementation to begin the withdraw request
    /// @return requestId some identifier of the withdraw request
    function _initiateWithdrawImpl(
        address account,
        uint256 vaultShares,
        bool isForced
    ) internal virtual returns (uint256 requestId);

    /// @notice Required implementation to finalize the withdraw
    /// @return tokensClaimed total tokens claimed as a result of the withdraw, does not
    /// necessarily represent the tokens that go to the account if the request has been
    /// split due to liquidation
    /// @return finalized returns true if the withdraw has been finalized
    function _finalizeWithdrawImpl(
        address account,
        uint256 requestId
    ) internal virtual returns (uint256 tokensClaimed, bool finalized);

    /// @notice Used to determine if a withdraw request can be finalized off chain
    function canFinalizeWithdrawRequest(uint256 requestId) public virtual view returns (bool);

    /// @notice Returns the split status of a withdraw request
    function getSplitWithdrawRequest(uint256 requestId) public view returns (SplitWithdrawRequest memory s) {
        s = VaultStorage.getSplitWithdrawRequest()[requestId];
    }

    /// @notice Returns the open withdraw request for a given account
    /// @return accountWithdraw an account's self initiated withdraw
    function getWithdrawRequest(address account) public view returns (WithdrawRequest memory) {
        return VaultStorage.getAccountWithdrawRequest()[account];
    }

    function _getValueOfWithdrawRequest(
        WithdrawRequest memory w, uint256 stakeAssetPrice
    ) internal virtual view returns (uint256);

    function _getValueOfSplitFinalizedWithdrawRequest(
        WithdrawRequest memory w,
        SplitWithdrawRequest memory s,
        address borrowToken,
        address redeemToken
    ) internal virtual view returns (uint256) {
        // If the borrow token and the withdraw token match, then there is no need to apply
        // an exchange rate at this point.
        if (borrowToken == redeemToken) {
            return (s.totalWithdraw * w.vaultShares) / s.totalVaultShares;
        } else {
            // Otherwise, apply the proper exchange rate
            (int256 rate, /* */) = Deployments.TRADING_MODULE.getOraclePrice(redeemToken, borrowToken);

            return (s.totalWithdraw * rate.toUint() * w.vaultShares) / 
                (s.totalVaultShares * Constants.EXCHANGE_RATE_PRECISION);
        }
    }

    /// @notice Returns the value of a withdraw request in terms of the borrowed token. Used
    /// to determine the collateral position of the vault.
    function _calculateValueOfWithdrawRequest(
        WithdrawRequest memory w,
        uint256 stakeAssetPrice,
        address borrowToken,
        address redeemToken
    ) internal view returns (uint256 borrowTokenValue) {
        if (w.requestId == 0) return 0;

        // If a withdraw request has split and is finalized, we know the fully realized value of
        // the withdraw request as a share of the total realized value.
        if (w.hasSplit) {
            SplitWithdrawRequest memory s = VaultStorage.getSplitWithdrawRequest()[w.requestId];
            if (s.finalized) {
                return _getValueOfSplitFinalizedWithdrawRequest(w, s, borrowToken, redeemToken);
            }
        }

        // In every other case, including the case when the withdraw request has split, the vault shares
        // in the withdraw request (`w`) are marked at the amount of vault shares the account holds.
        return _getValueOfWithdrawRequest(w, stakeAssetPrice);
    }

    /// @notice Initiates a withdraw request of all vault shares
    function _initiateWithdraw(address account, bool isForced) internal {
        uint256 vaultShares = Deployments.NOTIONAL.getVaultAccount(account, address(this)).vaultShares;
        require(0 < vaultShares);

        WithdrawRequest storage accountWithdraw = VaultStorage.getAccountWithdrawRequest()[account];
        require(accountWithdraw.requestId == 0, "Existing Request");

        uint256 requestId = _initiateWithdrawImpl(account, vaultShares, isForced);
        accountWithdraw.requestId = requestId;
        accountWithdraw.hasSplit = false;
        accountWithdraw.vaultShares = vaultShares;

        emit InitiateWithdrawRequest(account, isForced, vaultShares, requestId);
    }

    /// @notice Attempts to redeem active withdraw requests during vault exit
    /// @return vaultSharesRedeemed amount of vault shares to burn as a result of finalizing withdraw
    /// requests
    /// @return tokensClaimed amount of tokens redeemed from the withdraw requests
    function _redeemActiveWithdrawRequest(
        address account,
        WithdrawRequest memory accountWithdraw
    ) internal returns (uint256 vaultSharesRedeemed, uint256 tokensClaimed) {
        if (accountWithdraw.requestId == 0) return (0, 0);

        (uint256 tokens, bool finalized) = _finalizeWithdraw(account, accountWithdraw);
        if (finalized) {
            vaultSharesRedeemed = accountWithdraw.vaultShares;
            tokensClaimed = tokens;
            delete VaultStorage.getAccountWithdrawRequest()[account];
        }
    }

    /// @notice Finalizes a withdraw request and updates the account required to determine how many
    /// tokens the account has a claim over.
    function _finalizeWithdraw(
        address account,
        WithdrawRequest memory w
    ) internal returns (uint256 tokensClaimed, bool finalized) {
        SplitWithdrawRequest memory s;
        if (w.hasSplit) {
            s = VaultStorage.getSplitWithdrawRequest()[w.requestId];

            // If the split request was already finalized in a different transaction
            // then return the values here and we can short circuit the withdraw impl
            if (s.finalized) {
                return (s.totalWithdraw * w.vaultShares / s.totalVaultShares, true);
            }
        }

        // These values are the total tokens claimed from the withdraw request, does not
        // account for potential splitting.
        (tokensClaimed, finalized) = _finalizeWithdrawImpl(account, w.requestId);

        if (w.hasSplit && finalized) {
            s.totalWithdraw = tokensClaimed;
            s.finalized = true;
            VaultStorage.getSplitWithdrawRequest()[w.requestId] = s;

            tokensClaimed = s.totalWithdraw * w.vaultShares / s.totalVaultShares;
        } else if (!finalized) {
            // No tokens claimed if not finalized
            require(tokensClaimed == 0);
        }
    }


    /// @notice Finalizes withdraw requests outside of a vault exit. This may be required in cases if an
    /// account is negligent in exiting their vault position and letting the withdraw request sit idle
    /// could result in losses. The withdraw request is finalized and stored in a "split" withdraw request
    /// where the account has the full claim on the withdraw.
    function _finalizeWithdrawsManual(address account) internal {
        WithdrawRequest storage accountWithdraw = VaultStorage.getAccountWithdrawRequest()[account];
        if (accountWithdraw.requestId == 0) return;

        (uint256 tokens, bool finalized) = _finalizeWithdraw(account, accountWithdraw);

        // If the account has not split, we store the total tokens withdrawn in the split withdraw
        // request. When the account does exit, they will skip `_finalizeWithdrawImpl` and get the
        // full share of totalWithdraw (unless they are liquidated after this withdraw has been finalized).
        if (!accountWithdraw.hasSplit && finalized) {
            VaultStorage.getSplitWithdrawRequest()[accountWithdraw.requestId] = SplitWithdrawRequest({
                totalVaultShares: accountWithdraw.vaultShares,
                totalWithdraw: tokens,
                finalized: true
            });

            accountWithdraw.hasSplit = true;
        }
    }

    /// @notice If an account has an illiquid withdraw request, this method will split their
    /// claim on it during liquidation.
    /// @param _from the account that is being liquidated
    /// @param _to the liquidator
    /// @param vaultShares the vault shares that have been transferred to the liquidator
    function _splitWithdrawRequest(address _from, address _to, uint256 vaultShares) internal {
        WithdrawRequest storage w = VaultStorage.getAccountWithdrawRequest()[_from];
        if (w.requestId == 0) return;

        // Create a new split withdraw request
        if (!w.hasSplit) {
            SplitWithdrawRequest memory s = VaultStorage.getSplitWithdrawRequest()[w.requestId];
            // Safety check to ensure that the split withdraw request is not active, split withdraw
            // requests are never deleted. This presumes that all withdraw request ids are unique.
            require(s.finalized == false && s.totalVaultShares == 0);
            VaultStorage.getSplitWithdrawRequest()[w.requestId].totalVaultShares = w.vaultShares;
        }

        if (w.vaultShares == vaultShares) {
            // If the resulting vault shares is zero, then delete the request. The _from account's
            // withdraw request is fully transferred to _to
            delete VaultStorage.getAccountWithdrawRequest()[_from];
        } else {
            // Otherwise deduct the vault shares
            w.vaultShares = w.vaultShares - vaultShares;
            w.hasSplit = true;
        }

        // Ensure that no withdraw request gets overridden, the _to account always receives their withdraw
        // request in the account withdraw slot.
        WithdrawRequest storage toWithdraw = VaultStorage.getAccountWithdrawRequest()[_to];
        require(toWithdraw.requestId == 0 || toWithdraw.requestId == w.requestId , "Existing Request");

        // Either the request gets set or it gets incremented here.
        toWithdraw.requestId = w.requestId;
        toWithdraw.vaultShares = toWithdraw.vaultShares + vaultShares;
        toWithdraw.hasSplit = true;
    }
}
