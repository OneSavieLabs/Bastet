// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {ICLPositionDescriptor} from ""./interfaces/ICLPositionDescriptor.sol"";
import {ICLPositionManager} from ""./interfaces/ICLPositionManager.sol"";
import {Strings} from ""@openzeppelin/contracts/utils/Strings.sol"";
import {Ownable} from ""@openzeppelin/contracts/access/Ownable.sol"";

/// @title Describes NFT token positions
contract CLPositionDescriptorOffChain is ICLPositionDescriptor, Ownable {
    using Strings for uint256;

    string private _baseTokenURI;

    /// @notice Just in case we want to upgrade the tokenURI generation logic
    /// This defaults to address(0) but will be used if set
    ICLPositionDescriptor public tokenURIContract;

    constructor(string memory baseTokenURI) Ownable(msg.sender) {
        _baseTokenURI = baseTokenURI;
    }

    function setBaseTokenURI(string memory baseTokenURI) external onlyOwner {
        _baseTokenURI = baseTokenURI;
    }

    function setTokenURIContract(ICLPositionDescriptor newTokenURIContract) external onlyOwner {
        tokenURIContract = newTokenURIContract;
    }

    /// @inheritdoc ICLPositionDescriptor
    function tokenURI(ICLPositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        // if set, this will be used instead of _baseTokenURI
        if (address(tokenURIContract) != address(0)) {
            return tokenURIContract.tokenURI(positionManager, tokenId);
        }

        return bytes(_baseTokenURI).length > 0 ? string(abi.encodePacked(_baseTokenURI, tokenId.toString())) : """";
    }
}