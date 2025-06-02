// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IPermit2} from ""permit2/src/interfaces/IPermit2.sol"";
import {IV3NonfungiblePositionManager} from
    ""infinity-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol"";
import {IPositionManager} from ""infinity-periphery/src/interfaces/IPositionManager.sol"";
import {ERC20} from ""solmate/src/tokens/ERC20.sol"";
import {IWETH9} from ""infinity-periphery/src/interfaces/external/IWETH9.sol"";

struct RouterParameters {
    // Payment parameters
    address permit2;
    address weth9;
    // PCS swapping parameters
    address v2Factory;
    address v3Factory;
    address v3Deployer;
    bytes32 v2InitCodeHash;
    bytes32 v3InitCodeHash;
    address stableFactory;
    address stableInfo;
    // PCS infinity swapping parameters, param not in this contract as stored in infiSwapRouter
    address infiVault;
    address infiClPoolManager;
    address infiBinPoolManager;
    // PCS v3->infinity migration parameters
    address v3NFTPositionManager;
    address infiClPositionManager;
    address infiBinPositionManager;
}

/// @title Router Immutable Storage contract
/// @notice Used along with the `RouterParameters` struct for ease of cross-chain deployment
contract RouterImmutables {
    /// @dev WETH9 address
    IWETH9 internal immutable WETH9;

    /// @dev Permit2 address
    IPermit2 internal immutable PERMIT2;

    /// @dev The address of PancakeSwapV2Factory
    address internal immutable PANCAKESWAP_V2_FACTORY;

    /// @dev The PancakeSwapV2Pair initcodehash
    bytes32 internal immutable PANCAKESWAP_V2_PAIR_INIT_CODE_HASH;

    /// @dev The address of PancakeSwapV3Factory
    address internal immutable PANCAKESWAP_V3_FACTORY;

    /// @dev The PancakeSwapV3Pool initcodehash
    bytes32 internal immutable PANCAKESWAP_V3_POOL_INIT_CODE_HASH;

    /// @dev The address of PancakeSwap V3 Deployer
    address internal immutable PANCAKESWAP_V3_DEPLOYER;

    /// @dev v3PositionManager address
    IV3NonfungiblePositionManager public immutable V3_POSITION_MANAGER;

    /// @dev infinity CLPositionManager address
    IPositionManager public immutable INFI_CL_POSITION_MANAGER;

    /// @dev infinity BinPositionManager address
    IPositionManager public immutable INFI_BIN_POSITION_MANAGER;

    constructor(RouterParameters memory params) {
        PERMIT2 = IPermit2(params.permit2);
        WETH9 = IWETH9(params.weth9);
        PANCAKESWAP_V2_FACTORY = params.v2Factory;
        PANCAKESWAP_V2_PAIR_INIT_CODE_HASH = params.v2InitCodeHash;
        PANCAKESWAP_V3_FACTORY = params.v3Factory;
        PANCAKESWAP_V3_POOL_INIT_CODE_HASH = params.v3InitCodeHash;
        PANCAKESWAP_V3_DEPLOYER = params.v3Deployer;
        V3_POSITION_MANAGER = IV3NonfungiblePositionManager(params.v3NFTPositionManager);
        INFI_CL_POSITION_MANAGER = IPositionManager(params.infiClPositionManager);
        INFI_BIN_POSITION_MANAGER = IPositionManager(params.infiBinPositionManager);
    }
}