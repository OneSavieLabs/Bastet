// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {V2SwapRouter} from ""../modules/pancakeswap/v2/V2SwapRouter.sol"";
import {V3SwapRouter} from ""../modules/pancakeswap/v3/V3SwapRouter.sol"";
import {InfinitySwapRouter} from ""../modules/pancakeswap/infinity/InfinitySwapRouter.sol"";
import {StableSwapRouter} from ""../modules/pancakeswap/StableSwapRouter.sol"";
import {Payments} from ""../modules/Payments.sol"";
import {RouterImmutables} from ""../base/RouterImmutables.sol"";
import {V3ToInfinityMigrator} from ""../modules/V3ToInfinityMigrator.sol"";
import {BytesLib} from ""../libraries/BytesLib.sol"";
import {Commands} from ""../libraries/Commands.sol"";
import {Lock} from ""./Lock.sol"";
import {ERC20} from ""solmate/src/tokens/ERC20.sol"";
import {IAllowanceTransfer} from ""permit2/src/interfaces/IAllowanceTransfer.sol"";
import {ActionConstants} from ""infinity-periphery/src/libraries/ActionConstants.sol"";
import {BaseActionsRouter} from ""infinity-periphery/src/base/BaseActionsRouter.sol"";
import {CalldataDecoder} from ""infinity-periphery/src/libraries/CalldataDecoder.sol"";
import {PoolKey} from ""infinity-core/src/types/PoolKey.sol"";
import {ICLPoolManager} from ""infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol"";
import {IBinPoolManager} from ""infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol"";

/// @title Decodes and Executes Commands
/// @notice Called by the UniversalRouter contract to efficiently decode and execute a singular command
abstract contract Dispatcher is
    Payments,
    V2SwapRouter,
    V3SwapRouter,
    StableSwapRouter,
    InfinitySwapRouter,
    V3ToInfinityMigrator,
    Lock
{
    using BytesLib for bytes;
    using CalldataDecoder for bytes;

    error InvalidCommandType(uint256 commandType);
    error BalanceTooLow();

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable virtual;

    /// @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
    /// times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
    function msgSender() public view override(BaseActionsRouter) returns (address) {
        return _getLocker();
    }

    /// @notice Decodes and executes the given command with the given inputs
    /// @param commandType The command type to execute
    /// @param inputs The inputs to execute the command with
    /// @dev inputs must be ABI encoded using abi.encode() to ensure proper padding. WARNING: Direct calldata
    //       manipulation or abi.encodePacked() can result in incorrect data reads.
    /// @dev 2 masks are used to enable use of a nested-if statement in execution for efficiency reasons
    /// @return success True on success of the command, false on failure
    /// @return output The outputs or error messages, if any, from the command
    function dispatch(bytes1 commandType, bytes calldata inputs) internal returns (bool success, bytes memory output) {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        success = true;

        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.INFI_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountIn;
                        uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountIn := calldataload(add(inputs.offset, 0x20))
                            amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v3SwapExactInput(map(recipient), amountIn, amountOutMin, path, payer);
                        return (success, output);
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountOut;
                        uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountOut := calldataload(add(inputs.offset, 0x20))
                            amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v3SwapExactOutput(map(recipient), amountOut, amountInMax, path, payer);
                        return (success, output);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // equivalent: abi.decode(inputs, (address, address, uint160))
                        address token;
                        address recipient;
                        uint160 amount;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amount := calldataload(add(inputs.offset, 0x40))
                        }
                        permit2TransferFrom(token, msgSender(), map(recipient), amount);
                        return (success, output);
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        IAllowanceTransfer.PermitBatch calldata permitBatch;
                        assembly {
                            // this is a variable length struct, so calldataload(inputs.offset) contains the
                            // offset from inputs.offset at which the struct begins
                            permitBatch := add(inputs.offset, calldataload(inputs.offset))
                        }
                        bytes calldata data = inputs.toBytes(1);
                        (success, output) = address(PERMIT2).call(
                            abi.encodeWithSignature(
                                ""permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)"",
                                msgSender(),
                                permitBatch,
                                data
                            )
                        );
                        return (success, output);
                    } else if (command == Commands.SWEEP) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint160 amountMin;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amountMin := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.sweep(token, map(recipient), amountMin);
                        return (success, output);
                    } else if (command == Commands.TRANSFER) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 value;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            value := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.pay(token, map(recipient), value);
                        return (success, output);
                    } else if (command == Commands.PAY_PORTION) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 bips;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            bips := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.payPortion(token, map(recipient), bips);
                        return (success, output);
                    } else {
                        // placeholder area for command 0x07
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountIn;
                        uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountIn := calldataload(add(inputs.offset, 0x20))
                            amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        address[] calldata path = inputs.toAddressArray(3);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v2SwapExactInput(map(recipient), amountIn, amountOutMin, path, payer);
                        return (success, output);
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
                        address recipient;
                        uint256 amountOut;
                        uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountOut := calldataload(add(inputs.offset, 0x20))
                            amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 offset is the path, decoded below
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        address[] calldata path = inputs.toAddressArray(3);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v2SwapExactOutput(map(recipient), amountOut, amountInMax, path, payer);
                        return (success, output);
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        // equivalent: abi.decode(inputs, (IAllowanceTransfer.PermitSingle, bytes))
                        IAllowanceTransfer.PermitSingle calldata permitSingle;
                        assembly {
                            permitSingle := inputs.offset
                        }
                        bytes calldata data = inputs.toBytes(6); // PermitSingle takes first 6 slots (0..5)
                        (success, output) = address(PERMIT2).call(
                            abi.encodeWithSignature(
                                ""permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)"",
                                msgSender(),
                                permitSingle,
                                data
                            )
                        );
                        return (success, output);
                    } else if (command == Commands.WRAP_ETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amount;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amount := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.wrapETH(map(recipient), amount);
                        return (success, output);
                    } else if (command == Commands.UNWRAP_WETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amountMin;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountMin := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.unwrapWETH9(map(recipient), amountMin);
                        return (success, output);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        IAllowanceTransfer.AllowanceTransferDetails[] calldata batchDetails;
                        (uint256 length, uint256 offset) = inputs.toLengthOffset(0);
                        assembly {
                            batchDetails.length := length
                            batchDetails.offset := offset
                        }
                        permit2TransferFrom(batchDetails, msgSender());
                        return (success, output);
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // equivalent: abi.decode(inputs, (address, address, uint256))
                        address owner;
                        address token;
                        uint256 minBalance;
                        assembly {
                            owner := calldataload(inputs.offset)
                            token := calldataload(add(inputs.offset, 0x20))
                            minBalance := calldataload(add(inputs.offset, 0x40))
                        }
                        success = (ERC20(token).balanceOf(owner) >= minBalance);
                        if (!success) output = abi.encodePacked(BalanceTooLow.selector);
                        return (success, output);
                    } else {
                        // placeholder area for command 0x0f
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                if (command == Commands.INFI_SWAP) {
                    // pass the calldata provided to InfinitySwapRouter._executeActions (defined in BaseActionsRouter)
                    _executeActions(inputs);
                    return (success, output);
                    // This contract MUST be approved to spend the token since its going to be doing the call on the position manager
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    _checkV3PermitCall(inputs);
                    (success, output) = address(V3_POSITION_MANAGER).call(inputs);
                    return (success, output);
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    _checkV3PositionManagerCall(inputs, msgSender());
                    /// @dev ensure there's follow-up action if v3 position's removed token are sent to router contract
                    (success, output) = address(V3_POSITION_MANAGER).call(inputs);
                    return (success, output);
                } else if (command == Commands.INFI_CL_INITIALIZE_POOL) {
                    // equivalent: abi.decode(inputs, (PoolKey, uint160)) where PoolKey is
                    // (Currency currency0, Currency currency1, IHooks hooks, IPoolManager poolManager, uint24 fee, bytes32 parameters)
                    PoolKey calldata poolKey;
                    uint160 sqrtPriceX96;
                    assembly {
                        poolKey := inputs.offset
                        sqrtPriceX96 := calldataload(add(inputs.offset, 0xc0)) // poolKey has 6 variable, so it takes 192 space = 0xc0
                    }
                    (success, output) =
                        address(clPoolManager).call(abi.encodeCall(ICLPoolManager.initialize, (poolKey, sqrtPriceX96)));
                } else if (command == Commands.INFI_BIN_INITIALIZE_POOL) {
                    // equivalent: abi.decode(inputs, (PoolKey, uint24)) where PoolKey is
                    // (Currency currency0, Currency currency1, IHooks hooks, IPoolManager poolManager, uint24 fee, bytes32 parameters)
                    PoolKey calldata poolKey;
                    uint24 activeId;
                    assembly {
                        poolKey := inputs.offset
                        activeId := calldataload(add(inputs.offset, 0xc0)) // poolKey has 6 variable, so it takes 192 space = 0xc0
                    }
                    (success, output) =
                        address(binPoolManager).call(abi.encodeCall(IBinPoolManager.initialize, (poolKey, activeId)));
                } else if (command == Commands.INFI_CL_POSITION_CALL) {
                    _checkInfiClPositionManagerCall(inputs);
                    (success, output) = address(INFI_CL_POSITION_MANAGER).call{value: address(this).balance}(inputs);
                    return (success, output);
                } else if (command == Commands.INFI_BIN_POSITION_CALL) {
                    _checkInfiBinPositionManagerCall(inputs);
                    (success, output) = address(INFI_BIN_POSITION_MANAGER).call{value: address(this).balance}(inputs);
                    return (success, output);
                } else {
                    // placeholder area for commands 0x15-0x20
                    revert InvalidCommandType(command);
                }
            }
        } else {
            // 0x21 <= command
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes calldata _commands, bytes[] calldata _inputs) = inputs.decodeCommandsAndInputs();
                (success, output) = (address(this)).call(abi.encodeCall(Dispatcher.execute, (_commands, _inputs)));
                return (success, output);
            } else if (command == Commands.STABLE_SWAP_EXACT_IN) {
                // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bytes, bool))
                address recipient;
                uint256 amountIn;
                uint256 amountOutMin;
                bool payerIsUser;
                assembly {
                    recipient := calldataload(inputs.offset)
                    amountIn := calldataload(add(inputs.offset, 0x20))
                    amountOutMin := calldataload(add(inputs.offset, 0x40))
                    // 0x60 offset is the path and 0x80 is the flag, decoded below
                    payerIsUser := calldataload(add(inputs.offset, 0xa0))
                }
                address[] calldata path = inputs.toAddressArray(3);
                uint256[] calldata flag = inputs.toUintArray(4);
                address payer = payerIsUser ? msgSender() : address(this);
                stableSwapExactInput(map(recipient), amountIn, amountOutMin, path, flag, payer);
                return (success, output);
            } else if (command == Commands.STABLE_SWAP_EXACT_OUT) {
                // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bytes, bool))
                address recipient;
                uint256 amountOut;
                uint256 amountInMax;
                bool payerIsUser;
                assembly {
                    recipient := calldataload(inputs.offset)
                    amountOut := calldataload(add(inputs.offset, 0x20))
                    amountInMax := calldataload(add(inputs.offset, 0x40))
                    // 0x60 offset is the path and 0x80 is the flag, decoded below
                    payerIsUser := calldataload(add(inputs.offset, 0xa0))
                }
                address[] calldata path = inputs.toAddressArray(3);
                uint256[] calldata flag = inputs.toUintArray(4);
                address payer = payerIsUser ? msgSender() : address(this);

                /// @dev structured this way as stack too deep by Yul
                uint256 amountIn = stableSwapExactOutputAmountIn(amountOut, amountInMax, path, flag);
                stableSwapExactOutput(map(recipient), amountIn, amountOut, path, flag, payer);
                return (success, output);
            } else {
                // placeholder area for commands 0x24-0x3f
                revert InvalidCommandType(command);
            }
        }
    }

    /// @notice Calculates the recipient address for a command
    /// @param recipient The recipient or recipient-flag for the command
    /// @return output The resultant recipient for the command
    function map(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }
}