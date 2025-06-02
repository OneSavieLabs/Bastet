// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {IBinFungibleToken} from ""./interfaces/IBinFungibleToken.sol"";

/**
 * @notice Similar to ERC-1155, though without uri() and no onErc1155 callback when transfer is made
 */
abstract contract BinFungibleToken is IBinFungibleToken {
    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice [user] -> [keccak256(abi.encode(poolId, binId)] -> [number of shares]
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @notice [keccak256(abi.encode(poolId, binId)] -> [number of share]
    mapping(uint256 => uint256) public totalSupply;

    /// @notice [user] -> [operator] -> [is approved?]
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice Revert if ""spender"" is not approved to spend ""from"" token
    modifier checkApproval(address from, address spender) {
        if (!(spender == from || isApprovedForAll[from][spender])) {
            revert BinFungibleToken_SpenderNotApproved(from, spender);
        }
        _;
    }

    /// @notice Enforces that the Vault is unlocked.
    modifier onlyIfVaultUnlocked() virtual;

    /*//////////////////////////////////////////////////////////////
                             LOGIC
    //////////////////////////////////////////////////////////////*/

    function name() public view virtual override returns (string memory) {
        return ""Bin Fungible Token"";
    }

    function symbol() public view virtual override returns (string memory) {
        return ""BFT"";
    }

    function balanceOfBatch(address[] calldata owners, uint256[] calldata ids)
        public
        view
        virtual
        override
        returns (uint256[] memory balances)
    {
        if (owners.length != ids.length) revert BinFungibleToken_InvalidLength();

        balances = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i; i < owners.length; ++i) {
                balances[i] = balanceOf[owners[i]][ids[i]];
            }
        }
    }

    function approveForAll(address operator, bool approved) public virtual override {
        if (msg.sender == operator) revert BinFungibleToken_SelfApproval(msg.sender);

        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function batchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts)
        public
        virtual
        override
        onlyIfVaultUnlocked
    {
        if (ids.length != amounts.length) revert BinFungibleToken_InvalidLength();
        if (to == address(0) || to == address(this)) revert BinFungibleToken_AddressThisOrZero();
        if (!(msg.sender == from || isApprovedForAll[from][msg.sender])) {
            revert BinFungibleToken_SpenderNotApproved(from, msg.sender);
        }

        // Storing these outside the loop saves ~15 gas per iteration.
        uint256 id;
        uint256 amount;
        for (uint256 i; i < ids.length;) {
            id = ids[i];
            amount = amounts[i];

            if (balanceOf[from][id] < amount) revert BinFungibleToken_TransferExceedsBalance(from, id, amount);

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                balanceOf[from][id] -= amount;
                balanceOf[to][id] += amount;

                ++i;
            }
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 id, uint256 amount) internal {
        totalSupply[id] += amount;

        unchecked {
            balanceOf[to][id] += amount;
        }
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        if (balanceOf[from][id] < amount) revert BinFungibleToken_BurnExceedsBalance(from, id, amount);

        unchecked {
            totalSupply[id] -= amount;
            balanceOf[from][id] -= amount;
        }
    }
}