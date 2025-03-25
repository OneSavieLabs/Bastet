// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {TransferHelper} from "../../lib/v3-periphery/contracts/libraries/TransferHelper.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {DataStruct} from "./Structs.sol";
import {Errors} from "./Errors.sol";
import {Base} from "./Base.sol";

/// @title Liquidity Position
/// @notice Represents a liquidity position's underlying owner and fee tokens accrued from lending
library LiquidityPosition {
    struct Info {
        address owner;
        uint32 renewalCutoffTime; ///@dev loans before this time can't be renewed
        uint128 token0Owed;
        uint128 token1Owed;
    }

    event SupplyLiquidity(uint256 tokenId, address lp, uint128 liquidity);
    event IncreaseLiquidity(uint256 tokenId, uint128 liquidity);
    event DecreaseLiquidity(uint256 tokenId, uint128 liquidity);
    event CollectLiquidity(address lp, address token0, address token1, uint256 amount0, uint256 amount1);

    /*=============================================================
                               Info Logic
    ==============================================================*/

    /**
     * @notice Getter for a liquidity position's renewal cutoff time
     * @param self The mapping containing all liquidity positions
     * @param tokenId The token id of the liquidity position NFT
     * @return renewalCutoffTime renewal cutoff time for all previous loans
     */
    function getRenewalCutoffTime(
        mapping(uint256 => Info) storage self,
        uint256 tokenId
    ) internal view returns (uint32 renewalCutoffTime) {
        renewalCutoffTime = self[tokenId].renewalCutoffTime;
    }

    /**
     * @notice Getter for a liquidity position's tokens currently owed to owner
     * @param self The mapping containing all liquidity positions
     * @param tokenId The token id of the liquidity position NFT
     * @return token0Owed The amount of token0 owed to the owner
     * @return token1Owed The amount of token1 owed to the owner
     */
    function getTokensOwed(
        mapping(uint256 => Info) storage self,
        uint256 tokenId
    ) internal view returns (uint128 token0Owed, uint128 token1Owed) {
        Info memory info = self[tokenId];
        token0Owed = info.token0Owed;
        token1Owed = info.token1Owed;
    }

    /*=============================================================
                            Tokens Owed Logic
    ==============================================================*/

    /**
     * @notice Update a liquidity positon's owed tokens
     * @param self The mapping containing all liquidity positions
     * @param tokenId The token id of the liquidity position NFT
     * @param token0Owed The amount of token0 owed to the owner to be added
     * @param token1Owed The amount of token1 owed to the owner to be added
     */
    function addTokensOwed(
        mapping(uint256 => Info) storage self,
        uint256 tokenId,
        uint128 token0Owed,
        uint128 token1Owed
    ) internal {
        Info storage info = self[tokenId];
        info.token0Owed += token0Owed;
        info.token1Owed += token1Owed;
    }

    /**
     * @notice Reset a liquidity positon's owed tokens to 0
     * @param self The mapping containing all liquidity positions
     * @param tokenId The token id of the liquidity position NFT
     */
    function resetTokensOwed(mapping(uint256 => Info) storage self, uint256 tokenId) internal {
        Info storage info = self[tokenId];
        info.token0Owed = 0;
        info.token1Owed = 0;
    }

    /*=============================================================
                           Renewal Time Logic
    ==============================================================*/

    /**
     * @notice Update a liquidity positon's renewal cutoff time
     * @param self The mapping containing all liquidity positions
     * @param tokenId The token id of the liquidity position NFT
     */
    function updateRenewalCutoffTime(mapping(uint256 => Info) storage self, uint256 tokenId) internal {
        Info storage info = self[tokenId];
        info.renewalCutoffTime = uint32(block.timestamp);
    }

    /*=============================================================
                               Mint Logic
    ==============================================================*/

    /**
     * @notice Supply liquidity to mint position NFT to the contract
     * @param self The mapping containing all liquidity positions
     * @param params mint parameters containing token pairs, fee, tick info and amount to mint
     * @return tokenId newly minted tokenId
     * @return liquidity amount of liquidity minted
     * @return amount0Minted amount of token 0 minted
     * @return amount1Minted amount of token 1 minted
     */

    function mint(
        mapping(uint256 => Info) storage self,
        DataStruct.MintParams calldata params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Minted, uint256 amount1Minted) {
        // transfer in the tokens
        TransferHelper.safeTransferFrom(params.token0, msg.sender, address(this), params.amount0ToMint);
        TransferHelper.safeTransferFrom(params.token1, msg.sender, address(this), params.amount1ToMint);

        // approve position manager to spend the tokens
        TransferHelper.safeApprove(params.token0, Base.UNI_POSITION_MANAGER_ADDR, params.amount0ToMint);
        TransferHelper.safeApprove(params.token1, Base.UNI_POSITION_MANAGER_ADDR, params.amount1ToMint);

        // mint the position
        (tokenId, liquidity, amount0Minted, amount1Minted) = Base.UNI_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0ToMint,
                amount1Desired: params.amount1ToMint,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        // create the LP position
        self[tokenId] = LiquidityPosition.Info({owner: msg.sender, renewalCutoffTime: 0, token0Owed: 0, token1Owed: 0});

        // reset the approval
        TransferHelper.safeApprove(params.token0, Base.UNI_POSITION_MANAGER_ADDR, 0);
        TransferHelper.safeApprove(params.token1, Base.UNI_POSITION_MANAGER_ADDR, 0);

        // refund if necessary
        Base.refund(msg.sender, params.token0, params.amount0ToMint, amount0Minted);
        Base.refund(msg.sender, params.token1, params.amount1ToMint, amount1Minted);

        emit SupplyLiquidity(tokenId, msg.sender, liquidity);
    }

    /*=============================================================
                        Increase Liquidity Logic
    ==============================================================*/

    /**
     * @notice Increase liquidity to a liquidity position
     * @dev Caller must check for authorization and non-reentrancy
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param tokenId The token id of the liquidity position NFT
     * @param amount0 The amount of token0 to add to the liquidity position
     * @param amount1 The amount of token1 to add to the liquidity position
     * @return liquidity The amount of liquidity added
     * @return amount0Added The amount of token0 added
     * @return amount1Added The amount of token1 added
     */
    function increaseLiquidity(
        address token0,
        address token1,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
        // approve spending for uniswap's position manager
        TransferHelper.safeApprove(token0, Base.UNI_POSITION_MANAGER_ADDR, amount0);
        TransferHelper.safeApprove(token1, Base.UNI_POSITION_MANAGER_ADDR, amount1);

        // increase liquidity via position manager
        (liquidity, amount0Added, amount1Added) = Base.UNI_POSITION_MANAGER.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // reset approval
        TransferHelper.safeApprove(token0, Base.UNI_POSITION_MANAGER_ADDR, 0);
        TransferHelper.safeApprove(token1, Base.UNI_POSITION_MANAGER_ADDR, 0);
    }

    /**
     * @notice Increase liquidity of a position
     * @param self The mapping containing all liquidity positions
     * @param tokenId tokenId of the liquidity position NFT
     * @param amount0 amount to add for token 0
     * @param amount1 amount to add for token 1
     * @return liquidity amount of liquidity added
     * @return amount0Added amount of token 0 added
     * @return amount1Added amount of token 1 added
     */
    function increaseLiquidity(
        mapping(uint256 => Info) storage self,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
        if (self[tokenId].owner != msg.sender) revert Errors.Unauthorized();

        // get token0 and token1 from the position NFT
        (, , address token0, address token1, , , , , , , , ) = Base.UNI_POSITION_MANAGER.positions(tokenId);

        // transfer in liquidity to add
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amount0);
        TransferHelper.safeTransferFrom(token1, msg.sender, address(this), amount1);

        // add liquidity
        (liquidity, amount0Added, amount1Added) = increaseLiquidity(token0, token1, tokenId, amount0, amount1);

        // refund if necessary
        Base.refund(msg.sender, token0, amount0, amount0Added);
        Base.refund(msg.sender, token1, amount1, amount1Added);

        emit IncreaseLiquidity(tokenId, liquidity);
    }

    /*=============================================================
                        Decrease Liquidity Logic
    ==============================================================*/

    /**
     * @notice Decrease liquidity from an existing position
     * @dev Caller must check for authorization and non-reentrancy
     * @param tokenId tokenId of the liquidity position NFT
     * @param liquidity amount to decrease
     * @return amount0 amount decreased for token0
     * @return amount1 amount decreased for token1
     */
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = Base.UNI_POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    /**
     * @notice Decrease liquidity from a position
     * @param self The mapping containing all liquidity positions
     * @param tokenId tokenId of the liquidity position NFT
     * @param liquidity amount of liquidity to add
     * @return amount0Decreased amount of token 0 decreased
     * @return amount1Decreased amount of token 1 decreased
     */
    function decreaseLiquidity(
        mapping(uint256 => Info) storage self,
        uint256 tokenId,
        uint128 liquidity
    ) internal returns (uint256 amount0Decreased, uint256 amount1Decreased) {
        if (self[tokenId].owner != msg.sender) revert Errors.Unauthorized();
        (amount0Decreased, amount1Decreased) = decreaseLiquidity(tokenId, liquidity);
        emit DecreaseLiquidity(tokenId, liquidity);
    }

    /*=============================================================
                        Collect Liquidity Logic
    ==============================================================*/

    /**
     * @notice Collect fees from a position
     * @dev Caller must check for authorization and non-reentrancy
     * @param tokenId tokenId of the liquidity position NFT
     * @param amount0Max maximum amount of token0 to collect
     * @param amount1Max maximum amount of token1 to collect
     * @param recipient the address to collect the liquidity
     * @return amount0 amount collected for token0
     * @return amount1 amount collected for token1
     */
    function collectLiquidity(
        uint256 tokenId,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = Base.UNI_POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    /**
     * @notice Collect fees from a position
     * @param self The mapping containing all liquidity positions
     * @param tokenId tokenId of the liquidity position NFT
     * @return amount0Collected amount of fees collected in token 0
     * @return amount1Collected amount of fees collected in token 1
     */
    function collectLiquidity(
        mapping(uint256 => Info) storage self,
        uint256 tokenId
    ) internal returns (uint256 amount0Collected, uint256 amount1Collected) {
        if (self[tokenId].owner != msg.sender) revert Errors.Unauthorized();
        (amount0Collected, amount1Collected) = LiquidityPosition.collectLiquidity(
            tokenId,
            type(uint128).max,
            type(uint128).max,
            msg.sender
        );
        (uint128 token0Owed, uint128 token1Owed) = getTokensOwed(self, tokenId);
        resetTokensOwed(self, tokenId);
        (, , address token0, address token1, , , , , , , , ) = Base.UNI_POSITION_MANAGER.positions(tokenId);
        if (token0Owed > 0) {
            amount0Collected += token0Owed;
            TransferHelper.safeTransfer(token0, msg.sender, token0Owed);
        }
        if (token1Owed > 0) {
            amount1Collected += token1Owed;
            TransferHelper.safeTransfer(token1, msg.sender, token1Owed);
        }

        emit CollectLiquidity(msg.sender, token0, token1, amount0Collected, amount1Collected);
    }

    /*=============================================================
                         Reclaim Liquidity Logic
    ==============================================================*/

    /**
     * @notice LP reclaims borrowed liquidity from being renewed
     * @param self The mapping containing all liquidity positions
     * @param tokenId tokenId of the liquidity position NFT
     */
    function reclaimLiquidity(mapping(uint256 => Info) storage self, uint256 tokenId) internal {
        if (self[tokenId].owner != msg.sender) revert Errors.Unauthorized();
        updateRenewalCutoffTime(self, tokenId);
    }
}