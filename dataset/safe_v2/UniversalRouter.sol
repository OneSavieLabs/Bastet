// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

// Command implementations
import {Dispatcher} from ""./base/Dispatcher.sol"";
import {RouterParameters, RouterImmutables} from ""./base/RouterImmutables.sol"";
import {InfinitySwapRouter} from ""./modules/pancakeswap/infinity/InfinitySwapRouter.sol"";
import {Commands} from ""./libraries/Commands.sol"";
import {Constants} from ""./libraries/Constants.sol"";
import {IUniversalRouter} from ""./interfaces/IUniversalRouter.sol"";
import {StableSwapRouter} from ""./modules/pancakeswap/StableSwapRouter.sol"";
import {Pausable} from ""@openzeppelin/contracts/utils/Pausable.sol"";

contract UniversalRouter is RouterImmutables, IUniversalRouter, Dispatcher, Pausable {
    constructor(RouterParameters memory params)
        RouterImmutables(params)
        StableSwapRouter(params.stableFactory, params.stableInfo)
        InfinitySwapRouter(params.infiVault, params.infiClPoolManager, params.infiBinPoolManager)
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @notice To receive ETH from WETH
    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(vault)) revert InvalidEthSender();
    }

    /// @inheritdoc IUniversalRouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        execute(commands, inputs);
    }

    /// @inheritdoc Dispatcher
    function execute(bytes calldata commands, bytes[] calldata inputs)
        public
        payable
        override
        isNotLocked
        whenNotPaused
    {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & Commands.FLAG_ALLOW_REVERT == 0;
    }

    /**
     * @dev called by the owner to pause, triggers stopped state
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @dev called by the owner to unpause, returns to normal state
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }
}