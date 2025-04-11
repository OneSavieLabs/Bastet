pragma solidity ^0.8.13;

// SPDX-License-Identifier: MIT

import { GiantLP } from "./GiantLP.sol";
import { StakingFundsVault } from "./StakingFundsVault.sol";
import { LPToken } from "./LPToken.sol";
import { GiantPoolBase } from "./GiantPoolBase.sol";
import { SyndicateRewardsProcessor } from "./SyndicateRewardsProcessor.sol";
import { LSDNFactory } from "./LSDNFactory.sol";
import { LPToken } from "./LPToken.sol";
import { ITransferHookProcessor } from "../interfaces/ITransferHookProcessor.sol";

/// @notice A giant pool that can provide liquidity to any liquid staking network's staking funds vault
contract GiantMevAndFeesPool is ITransferHookProcessor, GiantPoolBase, SyndicateRewardsProcessor {

    constructor(LSDNFactory _factory) {
        lpTokenETH = new GiantLP(address(this), address(this), "GiantETHLP", "gMevETH");
        liquidStakingDerivativeFactory = _factory;
    }

    /// @notice Stake ETH against multiple BLS keys within multiple LSDNs and specify the amount of ETH being supplied for each key
    /// @dev Uses contract balance for funding and get Staking Funds Vault LP in exchange for ETH
    /// @param _stakingFundsVault List of mev and fees vaults being interacted with
    /// @param _ETHTransactionAmounts ETH being attached to each savETH vault in the list
    /// @param _blsPublicKeyOfKnots For every staking funds vault, the list of BLS keys of LSDN validators receiving funding
    /// @param _amounts List of amounts of ETH being staked per BLS public key
    function batchDepositETHForStaking(
        address[] calldata _stakingFundsVault,
        uint256[] calldata _ETHTransactionAmounts,
        bytes[][] calldata _blsPublicKeyOfKnots,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfVaults = _stakingFundsVault.length;
        require(numOfVaults > 0, "Zero vaults");
        require(numOfVaults == _blsPublicKeyOfKnots.length, "Inconsistent lengths");
        require(numOfVaults == _amounts.length, "Inconsistent lengths");
        for (uint256 i; i < numOfVaults; ++i) {
            // As ETH is being deployed to a staking funds vault, it is no longer idle
            idleETH -= _ETHTransactionAmounts[i];

            StakingFundsVault sfv = StakingFundsVault(payable(_stakingFundsVault[i]));
            require(
                liquidStakingDerivativeFactory.isLiquidStakingManager(address(sfv.liquidStakingNetworkManager())),
                "Invalid liquid staking manager"
            );

            sfv.batchDepositETHForStaking{ value: _ETHTransactionAmounts[i] }(
                _blsPublicKeyOfKnots[i],
                _amounts[i]
            );
        }
    }

    /// @notice Allow a giant LP to claim a % of the revenue received by the MEV and Fees Pool
    function claimRewards(
        address _recipient,
        address[] calldata _stakingFundsVaults,
        bytes[][] calldata _blsPublicKeysForKnots
    ) external {
        uint256 numOfVaults = _stakingFundsVaults.length;
        require(numOfVaults > 0, "Empty array");
        require(numOfVaults == _blsPublicKeysForKnots.length, "Inconsistent array lengths");
        for (uint256 i; i < numOfVaults; ++i) {
            StakingFundsVault(payable(_stakingFundsVaults[i])).claimRewards(
                address(this),
                _blsPublicKeysForKnots[i]
            );
        }

        updateAccumulatedETHPerLP();

        _distributeETHRewardsToUserForToken(
            msg.sender,
            address(lpTokenETH),
            lpTokenETH.balanceOf(msg.sender),
            _recipient
        );
    }

    /// @notice Preview total ETH accumulated by an address
    function previewAccumulatedETH(
        address _user,
        address[] calldata _stakingFundsVaults,
        LPToken[][] calldata _lpTokens
    ) external view returns (uint256) {
        require(_stakingFundsVaults.length == _lpTokens.length, "Inconsistent array lengths");

        uint256 accumulated;
        for (uint256 i; i < _stakingFundsVaults.length; ++i) {
            accumulated = StakingFundsVault(payable(_stakingFundsVaults[i])).batchPreviewAccumulatedETH(
                address(this),
                _lpTokens[i]
            );
        }

        return _previewAccumulatedETH(_user, address(lpTokenETH), lpTokenETH.balanceOf(_user), lpTokenETH.totalSupply(), accumulated);
    }

    /// @notice Any ETH supplied to a BLS key registered with a liquid staking network can be rotated to another key if it never gets staked
    /// @param _stakingFundsVaults List of staking funds vaults this contract will contact
    /// @param _oldLPTokens List of savETH vault LP tokens that the vault has
    /// @param _oldLPTokens List of new savETH vault LP tokens that the vault wants to receive in exchange for moving ETH to a new KNOT
    /// @param _amounts Amount of old being swapped for new per LP token
    function batchRotateLPTokens(
        address[] calldata _stakingFundsVaults,
        LPToken[][] calldata _oldLPTokens,
        LPToken[][] calldata _newLPTokens,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfRotations = _stakingFundsVaults.length;
        require(numOfRotations > 0, "Empty arrays");
        require(numOfRotations == _oldLPTokens.length, "Inconsistent arrays");
        require(numOfRotations == _newLPTokens.length, "Inconsistent arrays");
        require(numOfRotations == _amounts.length, "Inconsistent arrays");
        require(lpTokenETH.balanceOf(msg.sender) >= 0.5 ether, "No common interest");
        for (uint256 i; i < numOfRotations; ++i) {
            StakingFundsVault(payable(_stakingFundsVaults[i])).batchRotateLPTokens(_oldLPTokens[i], _newLPTokens[i], _amounts[i]);
        }
    }

    /// @notice Any ETH that has not been utilized by a Staking Funds vault can be brought back into the giant pool
    /// @param _stakingFundsVaults List of staking funds vaults this contract will contact
    /// @param _lpTokens List of LP tokens that the giant pool holds which represents ETH in a staking funds vault
    /// @param _amounts Amounts of LP within the giant pool being burnt
    function bringUnusedETHBackIntoGiantPool(
        address[] calldata _stakingFundsVaults,
        LPToken[][] calldata _lpTokens,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfVaults = _stakingFundsVaults.length;
        require(numOfVaults > 0, "Empty arrays");
        require(numOfVaults == _lpTokens.length, "Inconsistent arrays");
        require(numOfVaults == _amounts.length, "Inconsistent arrays");
        for (uint256 i; i < numOfVaults; ++i) {
            StakingFundsVault(payable(_stakingFundsVaults[i])).burnLPTokensForETH(_lpTokens[i], _amounts[i]);
        }
    }

    /// @notice Distribute any new ETH received to LP holders
    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTokenETH.totalSupply());
    }

    /// @notice Allow giant LP token to notify pool about transfers so the claimed amounts can be processed
    function beforeTokenTransfer(address _from, address _to, uint256) external {
        require(msg.sender == address(lpTokenETH), "Caller is not giant LP");
        updateAccumulatedETHPerLP();

        // Make sure that `_from` gets total accrued before transfer as post transferred anything owed will be wiped
        if (_from != address(0)) {
            _distributeETHRewardsToUserForToken(
                _from,
                address(lpTokenETH),
                lpTokenETH.balanceOf(_from),
                _from
            );
        }

        // Make sure that `_to` gets total accrued before transfer as post transferred anything owed will be wiped
        _distributeETHRewardsToUserForToken(
            _to,
            address(lpTokenETH),
            lpTokenETH.balanceOf(_to),
            _to
        );
    }

    /// @notice Allow giant LP token to notify pool about transfers so the claimed amounts can be processed
    function afterTokenTransfer(address, address _to, uint256) external {
        require(msg.sender == address(lpTokenETH), "Caller is not giant LP");
        _setClaimedToMax(_to);
    }

    /// @notice Total rewards received by this contract from the syndicate excluding idle ETH from LP depositors
    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    /// @dev On withdrawing LP in exchange for burning giant LP, claim rewards
    function _onWithdraw(LPToken[] calldata _lpTokens) internal override {
        // Use the transfer hook of LPToken to trigger the claiming accrued ETH
        for (uint256 i; i < _lpTokens.length; ++i) {
            _lpTokens[i].transfer(address(this), _lpTokens[i].balanceOf(address(this)));
        }

        _distributeETHRewardsToUserForToken(
            msg.sender,
            address(lpTokenETH),
            lpTokenETH.balanceOf(msg.sender),
            msg.sender
        );
    }

    /// @dev On depositing on ETH set claimed to max claim so the new depositor cannot claim ETH that they have not accrued
    function _onDepositETH() internal override {
        _setClaimedToMax(msg.sender);
    }

    /// @dev Internal re-usable method for setting claimed to max for msg.sender
    function _setClaimedToMax(address _user) internal {
        // New ETH stakers are not entitled to ETH earned by
        claimed[_user][address(lpTokenETH)] = (accumulatedETHPerLPShare * lpTokenETH.balanceOf(_user)) / PRECISION;
    }
}