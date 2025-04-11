pragma solidity ^0.8.13;

// SPDX-License-Identifier: MIT

import { StakehouseAPI } from "@blockswaplab/stakehouse-solidity-api/contracts/StakehouseAPI.sol";
import { GiantLP } from "./GiantLP.sol";
import { SavETHVault } from "./SavETHVault.sol";
import { LPToken } from "./LPToken.sol";
import { GiantPoolBase } from "./GiantPoolBase.sol";
import { LSDNFactory } from "./LSDNFactory.sol";

/// @notice A giant pool that can provide protected deposit liquidity to any liquid staking network
contract GiantSavETHVaultPool is StakehouseAPI, GiantPoolBase {

    /// @notice Emitted when giant LP is burnt to receive dETH
    event LPBurnedForDETH(address indexed savETHVaultLPToken, address indexed sender, uint256 amount);

    constructor(LSDNFactory _factory) {
        lpTokenETH = new GiantLP(address(this), address(0), "GiantETHLP", "gETH");
        liquidStakingDerivativeFactory = _factory;
    }

    /// @notice Given the liquidity of the giant pool, stake ETH to receive protected deposits from many liquid staking networks (LSDNs)
    /// @dev Take ETH from the contract balance in order to send money to the individual vaults
    /// @param _savETHVaults List of savETH vaults that belong to individual liquid staking derivative networks
    /// @param _ETHTransactionAmounts ETH being attached to each savETH vault in the list
    /// @param _blsPublicKeys For every savETH vault, the list of BLS keys of LSDN validators receiving funding
    /// @param _stakeAmounts For every savETH vault, the amount of ETH each BLS key will receive in funding
    function batchDepositETHForStaking(
        address[] calldata _savETHVaults,
        uint256[] calldata _ETHTransactionAmounts,
        bytes[][] calldata _blsPublicKeys,
        uint256[][] calldata _stakeAmounts
    ) public {
        uint256 numOfSavETHVaults = _savETHVaults.length;
        require(numOfSavETHVaults > 0, "Empty arrays");
        require(numOfSavETHVaults == _ETHTransactionAmounts.length, "Inconsistent array lengths");
        require(numOfSavETHVaults == _blsPublicKeys.length, "Inconsistent array lengths");
        require(numOfSavETHVaults == _stakeAmounts.length, "Inconsistent array lengths");

        // For every vault specified, supply ETH for at least 1 BLS public key of a LSDN validator
        for (uint256 i; i < numOfSavETHVaults; ++i) {
            uint256 transactionAmount = _ETHTransactionAmounts[i];

            // As ETH is being deployed to a savETH pool vault, it is no longer idle
            idleETH -= transactionAmount;

            SavETHVault savETHPool = SavETHVault(_savETHVaults[i]);
            require(
                liquidStakingDerivativeFactory.isLiquidStakingManager(address(savETHPool.liquidStakingManager())),
                "Invalid liquid staking manager"
            );

            // Deposit ETH for staking of BLS key
            savETHPool.batchDepositETHForStaking{ value: transactionAmount }(
                _blsPublicKeys[i],
                _stakeAmounts[i]
            );
        }
    }

    /// @notice Allow a user to burn their giant LP in exchange for dETH that is ready to withdraw from a set of savETH vaults
    /// @param _savETHVaults List of savETH vaults being interacted with
    /// @param _lpTokens List of savETH vault LP being burnt from the giant pool in exchange for dETH
    /// @param _amounts Amounts of giant LP the user owns which is burnt 1:1 with savETH vault LP and in turn that will give a share of dETH
    function withdrawDETH(
        address[] calldata _savETHVaults,
        LPToken[][] calldata _lpTokens,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfVaults = _savETHVaults.length;
        require(numOfVaults > 0, "Empty arrays");
        require(numOfVaults == _lpTokens.length, "Inconsistent arrays");
        require(numOfVaults == _amounts.length, "Inconsistent arrays");

        // Firstly capture current dETH balance and see how much has been deposited after the loop
        uint256 dETHReceivedFromAllSavETHVaults = getDETH().balanceOf(address(this));
        for (uint256 i; i < numOfVaults; ++i) {
            SavETHVault vault = SavETHVault(_savETHVaults[i]);

            // Simultaneously check the status of LP tokens held by the vault and the giant LP balance of the user
            for (uint256 j; j < _lpTokens[i].length; ++j) {
                LPToken token = _lpTokens[i][j];
                uint256 amount = _amounts[i][j];

                // Check the user has enough giant LP to burn and that the pool has enough savETH vault LP
                _assertUserHasEnoughGiantLPToClaimVaultLP(token, amount);

                require(vault.isDETHReadyForWithdrawal(address(token)), "dETH is not ready for withdrawal");

                // Giant LP is burned 1:1 with LPs from sub-networks
                require(lpTokenETH.balanceOf(msg.sender) >= amount, "User does not own enough LP");

                // Burn giant LP from user before sending them dETH
                lpTokenETH.burn(msg.sender, amount);

                emit LPBurnedForDETH(address(token), msg.sender, amount);
            }

            // Ask
            vault.burnLPTokens(_lpTokens[i], _amounts[i]);
        }

        // Calculate how much dETH has been received from burning
        dETHReceivedFromAllSavETHVaults = getDETH().balanceOf(address(this)) - dETHReceivedFromAllSavETHVaults;

        // Send giant LP holder dETH owed
        getDETH().transfer(msg.sender, dETHReceivedFromAllSavETHVaults);
    }

    /// @notice Any ETH supplied to a BLS key registered with a liquid staking network can be rotated to another key if it never gets staked
    /// @param _savETHVaults List of savETH vaults this contract will contact
    /// @param _oldLPTokens List of savETH vault LP tokens that the vault has
    /// @param _oldLPTokens List of new savETH vault LP tokens that the vault wants to receive in exchange for moving ETH to a new KNOT
    /// @param _amounts Amount of old being swapped for new per LP token
    function batchRotateLPTokens(
        address[] calldata _savETHVaults,
        LPToken[][] calldata _oldLPTokens,
        LPToken[][] calldata _newLPTokens,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfRotations = _savETHVaults.length;
        require(numOfRotations > 0, "Empty arrays");
        require(numOfRotations == _oldLPTokens.length, "Inconsistent arrays");
        require(numOfRotations == _newLPTokens.length, "Inconsistent arrays");
        require(numOfRotations == _amounts.length, "Inconsistent arrays");
        require(lpTokenETH.balanceOf(msg.sender) >= 0.5 ether, "No common interest");
        for (uint256 i; i < numOfRotations; ++i) {
            SavETHVault(_savETHVaults[i]).batchRotateLPTokens(_oldLPTokens[i], _newLPTokens[i], _amounts[i]);
        }
    }

    /// @notice Any ETH that has not been utilized by a savETH vault can be brought back into the giant pool
    /// @param _savETHVaults List of savETH vaults where ETH is staked
    /// @param _lpTokens List of LP tokens that the giant pool holds which represents ETH in a savETH vault
    /// @param _amounts Amounts of LP within the giant pool being burnt
    function bringUnusedETHBackIntoGiantPool(
        address[] calldata _savETHVaults,
        LPToken[][] calldata _lpTokens,
        uint256[][] calldata _amounts
    ) external {
        uint256 numOfVaults = _savETHVaults.length;
        require(numOfVaults > 0, "Empty arrays");
        require(numOfVaults == _lpTokens.length, "Inconsistent arrays");
        require(numOfVaults == _amounts.length, "Inconsistent arrays");
        for (uint256 i; i < numOfVaults; ++i) {
            SavETHVault vault = SavETHVault(_savETHVaults[i]);
            for (uint256 j; j < _lpTokens[i].length; ++j) {
                require(
                    vault.isDETHReadyForWithdrawal(address(_lpTokens[i][j])) == false,
                    "ETH is either staked or derivatives minted"
                );
            }

            vault.burnLPTokens(_lpTokens[i], _amounts[i]);
        }
    }
}