pragma solidity ^0.8.13;

// SPDX-License-Identifier: MIT

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { GiantLP } from "./GiantLP.sol";
import { LPToken } from "./LPToken.sol";
import { LSDNFactory } from "./LSDNFactory.sol";

contract GiantPoolBase is ReentrancyGuard {

    /// @notice Emitted when an account deposits Ether into the giant pool
    event ETHDeposited(address indexed sender, uint256 amount);

    /// @notice Emitted when giant LP is burnt to recover ETH
    event LPBurnedForETH(address indexed sender, uint256 amount);

    /// @notice Emitted when giant LP is burnt to receive LP from a specific vault
    event LPSwappedForVaultLP(address indexed vaultLPToken, address indexed sender, uint256 amount);

    /// @notice Minimum amount of Ether that can be deposited into the contract
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;

    /// @notice Total amount of ETH sat idle ready for either withdrawal or depositing into a liquid staking network
    uint256 public idleETH;

    /// @notice LP token representing all ETH deposited and any ETH converted into savETH vault LP tokens from any liquid staking network
    GiantLP public lpTokenETH;

    /// @notice Address of the liquid staking derivative factory that provides a source of truth on individual networks that can be funded
    LSDNFactory public liquidStakingDerivativeFactory;

    /// @notice Add ETH to the ETH LP pool at a rate of 1:1. LPs can always pull out at same rate.
    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        // The ETH capital has not yet been deployed to a liquid staking network
        idleETH += msg.value;

        // Mint giant LP at ratio of 1:1
        lpTokenETH.mint(msg.sender, msg.value);

        // If anything extra needs to be done
        _onDepositETH();

        emit ETHDeposited(msg.sender, msg.value);
    }

    /// @notice Allow a user to chose to burn their LP tokens for ETH only if the requested amount is idle and available from the contract
    /// @param _amount of LP tokens user is burning in exchange for same amount of ETH
    function withdrawETH(uint256 _amount) external nonReentrant {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(lpTokenETH.balanceOf(msg.sender) >= _amount, "Invalid balance");
        require(idleETH >= _amount, "Come back later or withdraw less ETH");

        idleETH -= _amount;

        lpTokenETH.burn(msg.sender, _amount);
        (bool success,) = msg.sender.call{value: _amount}("");
        require(success, "Failed to transfer ETH");

        emit LPBurnedForETH(msg.sender, _amount);
    }

    /// @notice Allow a user to chose to withdraw vault LP tokens by burning their giant LP tokens. 1 Giant LP == 1 vault LP
    /// @param _lpTokens List of LP tokens being owned and being withdrawn from the giant pool
    /// @param _amounts List of amounts of giant LP being burnt in exchange for vault LP
    function withdrawLPTokens(LPToken[] calldata _lpTokens, uint256[] calldata _amounts) external {
        uint256 amountOfTokens = _lpTokens.length;
        require(amountOfTokens > 0, "Empty arrays");
        require(amountOfTokens == _amounts.length, "Inconsistent array lengths");

        _onWithdraw(_lpTokens);

        for (uint256 i; i < amountOfTokens; ++i) {
            LPToken token = _lpTokens[i];
            uint256 amount = _amounts[i];

            _assertUserHasEnoughGiantLPToClaimVaultLP(token, amount);

            // Burn giant LP from user before sending them an LP token from this pool
            lpTokenETH.burn(msg.sender, amount);

            // Giant LP tokens in this pool are 1:1 exchangeable with external savETH vault LP
            token.transfer(msg.sender, amount);

            emit LPSwappedForVaultLP(address(token), msg.sender, amount);
        }
    }

    /// @dev Check the msg.sender has enough giant LP to burn and that the pool has enough savETH vault LP
    function _assertUserHasEnoughGiantLPToClaimVaultLP(LPToken _token, uint256 _amount) internal view {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(_token.balanceOf(address(this)) >= _amount, "Pool does not own specified LP");
        require(lpTokenETH.lastInteractedTimestamp(msg.sender) + 1 days < block.timestamp, "Too new");
    }

    /// @dev Allow an inheriting contract to have a hook for performing operations post depositing ETH
    function _onDepositETH() internal virtual {}

    /// @dev Allow an inheriting contract to have a hook for performing operations during withdrawal of LP tokens when burning giant LP
    function _onWithdraw(LPToken[] calldata _lpTokens) internal virtual {}
}