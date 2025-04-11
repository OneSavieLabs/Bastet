// SPDX-License-Identifier: CC0
pragma solidity >=0.8.13;

import { Test, console2 } from "forge-std/Test.sol"; // remove after testing
import "./HSGLib.sol";
import { HatsOwnedInitializable } from "hats-auth/HatsOwnedInitializable.sol";
import { BaseGuard } from "zodiac/guard/BaseGuard.sol";
import { IAvatar } from "zodiac/interfaces/IAvatar.sol";
import { StorageAccessible } from "@gnosis.pm/safe-contracts/contracts/common/StorageAccessible.sol";
import { IGnosisSafe, Enum } from "./Interfaces/IGnosisSafe.sol";
import { SignatureDecoder } from "@gnosis.pm/safe-contracts/contracts/common/SignatureDecoder.sol";

abstract contract HatsSignerGateBase is BaseGuard, SignatureDecoder, HatsOwnedInitializable {
    /// @notice The multisig to which this contract is attached
    IGnosisSafe public safe;

    /// @notice The minimum signature threshold for the `safe`
    uint256 public minThreshold;

    /// @notice The highest level signature threshold for the `safe`
    uint256 public targetThreshold;

    /// @notice The maximum number of signers allowed for the `safe`
    uint256 public maxSigners;

    /// @notice The current number of signers on the `safe`
    uint256 public signerCount;

    /// @notice The version of HatsSignerGate used in this contract
    string public version;

    /// @notice The number of modules enabled on the `safe`, as enabled via this contract
    uint256 public enabledModuleCount;

    /// @dev Temporary record of the existing modules on the `safe` when a transaction is submitted
    bytes32 internal _existingModulesHash;
    
    /// @dev A simple re-entrency guard
    uint256 internal _guardEntries;

    /// @dev The head pointer used in the GnosisSafe owners linked list, as well as the module linked list
    address internal constant SENTINEL_OWNERS = address(0x1);

    /// @dev The storage slot used by GnosisSafe to store the guard address
    ///      keccak256("guard_manager.guard.address")
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    /// @dev Makes the singleton unusable by setting its owner to the 1-address
    constructor() payable initializer {
        _HatsOwned_init(1, address(0x1));
    }

    /// @notice Initializes a new instance
    /// @dev Can only be called once
    /// @param initializeParams ABI-encoded bytes with initialization parameters
    function setUp(bytes calldata initializeParams) public payable virtual initializer { }

    /// @notice Internal function to initialize a new instance
    /// @param _ownerHatId The hat id of the hat that owns this instance of HatsSignerGate
    /// @param _safe The multisig to which this instance of HatsSignerGate is attached
    /// @param _hats The Hats Protocol address
    /// @param _minThreshold The minimum threshold for the `_safe`
    /// @param _targetThreshold The maxium threshold for the `_safe`
    /// @param _maxSigners The maximum number of signers allowed on the `_safe`
    /// @param _version The current version of HatsSignerGate
    function _setUp(
        uint256 _ownerHatId,
        address _safe,
        address _hats,
        uint256 _minThreshold,
        uint256 _targetThreshold,
        uint256 _maxSigners,
        string memory _version,
        uint256 _existingModuleCount
    ) internal {
        _HatsOwned_init(_ownerHatId, _hats);
        maxSigners = _maxSigners;
        safe = IGnosisSafe(_safe);

        _setTargetThreshold(_targetThreshold);
        _setMinThreshold(_minThreshold);
        version = _version;
        enabledModuleCount = _existingModuleCount + 1; // this contract is enabled as well
    }

    /// @notice Checks if `_account` is a valid signer
    /// @dev Must be implemented by all flavors of HatsSignerGate
    /// @param _account The address to check
    /// @return valid Whether `_account` is a valid signer
    function isValidSigner(address _account) public view virtual returns (bool valid) { }

    /// @notice Sets a new target threshold, and changes `safe`'s threshold if appropriate
    /// @dev Only callable by a wearer of the owner hat. Reverts if `_targetThreshold` is greater than `maxSigners`.
    /// @param _targetThreshold The new target threshold to set
    function setTargetThreshold(uint256 _targetThreshold) public onlyOwner {
        if (_targetThreshold != targetThreshold) {
            _setTargetThreshold(_targetThreshold);

            if (signerCount > 1) _setSafeThreshold(_targetThreshold);

            emit HSGLib.TargetThresholdSet(_targetThreshold);
        }
    }

    /// @notice Internal function to set the target threshold
    /// @dev Reverts if `_targetThreshold` is greater than `maxSigners`
    /// @param _targetThreshold The new target threshold to set
    function _setTargetThreshold(uint256 _targetThreshold) internal {
        if (_targetThreshold > maxSigners) {
            revert InvalidTargetThreshold();
        }

        targetThreshold = _targetThreshold;
    }

    /// @notice Internal function to set the threshold for the `safe`
    /// @dev Forwards the threshold-setting call to `safe.ExecTransactionFromModule`
    /// @param _threshold The threshold to set on the `safe`
    function _setSafeThreshold(uint256 _threshold) internal {
        uint256 newThreshold = _threshold;
        uint256 signerCount_ = signerCount; // save an SLOAD

        // ensure that txs can't execute if fewer signers than target threshold
        if (signerCount_ <= _threshold) {
            newThreshold = signerCount_;
        }
        if (newThreshold != safe.getThreshold()) {
            bytes memory data = abi.encodeWithSignature("changeThreshold(uint256)", newThreshold);

            bool success = safe.execTransactionFromModule(
                address(safe), // to
                0, // value
                data, // data
                Enum.Operation.Call // operation
            );

            if (!success) {
                revert FailedExecChangeThreshold();
            }
        }
    }

    /// @notice Sets a new minimum threshold
    /// @dev Only callable by a wearer of the owner hat. Reverts if `_minThreshold` is greater than `maxSigners` or `targetThreshold`
    /// @param _minThreshold The new minimum threshold
    function setMinThreshold(uint256 _minThreshold) public onlyOwner {
        _setMinThreshold(_minThreshold);
        emit HSGLib.MinThresholdSet(_minThreshold);
    }

    /// @notice Internal function to set a new minimum threshold
    /// @dev Only callable by a wearer of the owner hat. Reverts if `_minThreshold` is greater than `maxSigners` or `targetThreshold`
    /// @param _minThreshold The new minimum threshold
    function _setMinThreshold(uint256 _minThreshold) internal {
        if (_minThreshold > maxSigners || _minThreshold > targetThreshold) {
            revert InvalidMinThreshold();
        }

        minThreshold = _minThreshold;
    }

    /// @notice Allows the owner to enable a new module on the `safe`
    /// @dev Increments the `enabledModuleCount` to include the new module in the allowed list (see `checkTransaction` and `checkAfterExecution`)
    /// @param _module The address of the module to enable
    function enableNewModule(address _module) external onlyOwner {
        ++enabledModuleCount;

        bytes memory data = abi.encodeWithSignature("enableModule(address)", _module);
        bool success = safe.execTransactionFromModule(
            address(safe), // to
            0, // value
            data, // data
            Enum.Operation.Call // operation
        );

        if (!success) {
            revert FailedExecEnableModule();
        }
    }

    /// @notice Tallies the number of existing `safe` owners that wear a signer hat, sets `signerCount` to that value, and updates the `safe` threshold if necessary
    /// @dev Does NOT remove invalid `safe` owners
    function reconcileSignerCount() public {
        address[] memory owners = safe.getOwners();
        uint256 validSignerCount = _countValidSigners(owners);

        if (validSignerCount > maxSigners) {
            revert MaxSignersReached();
        }

        // update the signer count accordingly
        signerCount = validSignerCount;

        uint256 currentThreshold = safe.getThreshold();
        uint256 newThreshold;
        uint256 target = targetThreshold; // save SLOADs

        if (validSignerCount <= target && validSignerCount != currentThreshold) {
            newThreshold = validSignerCount;
        } else if (validSignerCount > target && currentThreshold < target) {
            newThreshold = target;
        }
        if (newThreshold > 0) {
            bytes memory data = abi.encodeWithSignature("changeThreshold(uint256)", validSignerCount);

            bool success = safe.execTransactionFromModule(
                address(safe), // to
                0, // value
                data, // data
                Enum.Operation.Call // operation
            );

            if (!success) {
                revert FailedExecChangeThreshold();
            }
        }
    }

    /// @notice Internal function to count the number of valid signers in an array of addresses
    /// @param owners The addresses to check for validity
    /// @return validSignerCount The number of valid signers in `owners`
    function _countValidSigners(address[] memory owners) internal view returns (uint256 validSignerCount) {
        uint256 length = owners.length;
        // count the existing safe owners that wear the signer hat
        for (uint256 i; i < length;) {
            if (isValidSigner(owners[i])) {
                // shouldn't overflow given reasonable owners array length
                unchecked {
                    ++validSignerCount;
                }
            }
            // shouldn't overflow given reasonable owners array length
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal function that adds `_signer` as an owner on `safe`, updating the threshold if appropriate
    /// @dev Unsafe. Does not check if `_signer` is a valid signer
    /// @param _owners Array of owners on the `safe`
    /// @param _currentSignerCount The current number of signers
    /// @param _signer The address to add as a new `safe` owner
    function _grantSigner(address[] memory _owners, uint256 _currentSignerCount, address _signer) internal {
        uint256 newSignerCount = _currentSignerCount;

        uint256 currentThreshold = safe.getThreshold(); // view function
        uint256 newThreshold = currentThreshold;

        bytes memory addOwnerData;

        // if the only owner is a non-signer (ie this module set as an owner on initialization), replace it with _signer
        if (_owners.length == 1 && _owners[0] == address(this)) {
            // prevOwner will always be the sentinel when owners.length == 1

            // set up the swapOwner call
            addOwnerData = abi.encodeWithSignature(
                "swapOwner(address,address,address)",
                SENTINEL_OWNERS, // prevOwner
                address(this), // oldOwner
                _signer // newOwner
            );
            unchecked {
                // shouldn't overflow given MaxSignersReached check higher in call stack
                ++newSignerCount;
            }
        } else {
            // otherwise, add the claimer as a new owner

            unchecked {
                // shouldn't overflow given MaxSignersReached check higher in call stack
                ++newSignerCount;
            }

            // ensure that txs can't execute if fewer signers than target threshold
            if (newSignerCount <= targetThreshold) {
                newThreshold = newSignerCount;
            }

            // set up the addOwner call
            addOwnerData = abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", _signer, newThreshold);
        }

        // increment signer count
        signerCount = newSignerCount;

        // execute the call
        bool success = safe.execTransactionFromModule(
            address(safe), // to
            0, // value
            addOwnerData, // data
            Enum.Operation.Call // operation
        );

        if (!success) {
            revert FailedExecAddSigner();
        }
    }

    /// @notice Internal function that adds `_signer` as an owner on `safe` by swapping with an existing (invalid) owner
    /// @dev Unsafe. Does not check if `_signer` is a valid signer.
    /// @param _owners Array of owners on the `safe`
    /// @param _ownerCount The number of owners on the `safe` (length of `_owners` array)
    /// @param _maxSigners The maximum number of signers allowed
    /// @param _currentSignerCount The current number of signers
    /// @param _signer The address to add as a new `safe` owner
    /// @return success Whether an invalid signer was found and successfully replaced with `_signer`
    function _swapSigner(
        address[] memory _owners,
        uint256 _ownerCount,
        uint256 _maxSigners,
        uint256 _currentSignerCount,
        address _signer
    ) internal returns (bool success) {
        address ownerToCheck;
        bytes memory data;

        for (uint256 i; i < _ownerCount - 1;) {
            ownerToCheck = _owners[i];

            if (!isValidSigner(ownerToCheck)) {
                // prep the swap
                data = abi.encodeWithSignature(
                    "swapOwner(address,address,address)",
                    _findPrevOwner(_owners, ownerToCheck), // prevOwner
                    ownerToCheck, // oldOwner
                    _signer // newOwner
                );

                // execute the swap, reverting if it fails for some reason
                success = safe.execTransactionFromModule(
                    address(safe), // to
                    0, // value
                    data, // data
                    Enum.Operation.Call // operation
                );

                if (!success) {
                    revert FailedExecRemoveSigner();
                }

                // increment the signer count if signerCount was correct, ie `reconcileSignerCount` was called prior
                if (_currentSignerCount < _maxSigners) ++signerCount;
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Removes an invalid signer from the `safe`, updating the threshold if appropriate
    /// @param _signer The address to remove if not a valid signer
    function removeSigner(address _signer) public virtual {
        if (isValidSigner(_signer)) {
            revert StillWearsSignerHat(_signer);
        }

        _removeSigner(_signer);
    }

    /// @notice Internal function to remove a signer from the `safe`, updating the threshold if appropriate
    /// @dev Unsafe. Does not check for signer validity before removal
    /// @param _signer The address to remove
    function _removeSigner(address _signer) internal {
        bytes memory removeOwnerData;
        address[] memory owners = safe.getOwners();
        uint256 currentSignerCount = signerCount; // save an SLOAD
        uint256 newSignerCount;

        if (currentSignerCount < 2 && owners.length == 1) {
            // signerCount could be 0 after reconcileSignerCount
            // make address(this) the only owner
            removeOwnerData = abi.encodeWithSignature(
                "swapOwner(address,address,address)",
                SENTINEL_OWNERS, // prevOwner
                _signer, // oldOwner
                address(this) // newOwner
            );

            // newSignerCount is already 0
        } else {
            uint256 currentThreshold = safe.getThreshold();
            uint256 newThreshold = currentThreshold;
            uint256 validSignerCount = _countValidSigners(owners);

            if (validSignerCount == currentSignerCount) {
                newSignerCount = currentSignerCount;
            } else {
                newSignerCount = currentSignerCount - 1;
            }

            // ensure that txs can't execute if fewer signers than target threshold
            if (newSignerCount <= targetThreshold) {
                newThreshold = newSignerCount;
            }

            removeOwnerData = abi.encodeWithSignature(
                "removeOwner(address,address,uint256)", _findPrevOwner(owners, _signer), _signer, newThreshold
            );
        }

        // update signerCount
        signerCount = newSignerCount;

        bool success = safe.execTransactionFromModule(
            address(safe), // to
            0, // value
            removeOwnerData, // data
            Enum.Operation.Call // operation
        );

        if (!success) {
            revert FailedExecRemoveSigner();
        }
    }

    /// @notice Internal function to find the previous owner of an `_owner` in an array of `_owners`, ie the pointer to the owner to remove from the `safe` owners linked list
    /// @param _owners An array of addresses
    /// @param _owner The address after the one to find
    /// @return prevOwner The owner previous to `_owner` in the `safe` linked list
    function _findPrevOwner(address[] memory _owners, address _owner) internal pure returns (address prevOwner) {
        prevOwner = SENTINEL_OWNERS;

        for (uint256 i; i < _owners.length;) {
            if (_owners[i] == _owner) {
                if (i == 0) break;
                prevOwner = _owners[i - 1];
            }
            // shouldn't overflow given reasonable _owners array length
            unchecked {
                ++i;
            }
        }
    }

    // solhint-disallow-next-line payable-fallback
    fallback() external {
        // We don't revert on fallback to avoid issues in case of a Safe upgrade
        // E.g. The expected check method might change and then the Safe would be locked.
    }

    /// @notice Pre-flight check on a `safe` transaction to ensure that it s signers are valid, called from within `safe.execTransactionFromModule()`
    /// @dev Overrides All params mirror params for `safe.execTransactionFromModule()`
    function checkTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures,
        address // msgSender
    ) external override {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();

        uint256 safeOwnerCount = safe.getOwners().length;
        // uint256 validSignerCount = _countValidSigners(safe.getOwners());

        // ensure that safe threshold is correct
        reconcileSignerCount();

        if (safeOwnerCount < minThreshold) {
            revert BelowMinThreshold(minThreshold, safeOwnerCount);
        }

        // get the tx hash; view function
        bytes32 txHash = safe.getTransactionHash(
            // Transaction info
            to,
            value,
            data,
            operation,
            safeTxGas,
            // Payment info
            baseGas,
            gasPrice,
            gasToken,
            refundReceiver,
            // Signature info
            // We subtract 1 since nonce was just incremented in the parent function call
            safe.nonce() - 1 // view function
        );

        uint256 validSigCount = countValidSignatures(txHash, signatures, signatures.length / 65);

        // revert if there aren't enough valid signatures
        if (validSigCount < safe.getThreshold() || validSigCount < minThreshold) {
            revert InvalidSigners();
        }

        // record existing modules for post-flight check
        // SENTINEL_OWNERS and SENTINEL_MODULES are both address(0x1)
        (address[] memory modules,) = safe.getModulesPaginated(SENTINEL_OWNERS, enabledModuleCount);
        _existingModulesHash = keccak256(abi.encode(modules));

        unchecked {
            ++_guardEntries;
        }
    }

    /// @notice Post-flight check to prevent `safe` signers from removing this contract guard, changing any modules, or changing the threshold
    /// @dev Modified from https://github.com/gnosis/zodiac-guard-mod/blob/988ebc7b71e352f121a0be5f6ae37e79e47a4541/contracts/ModGuard.sol#L86
    function checkAfterExecution(bytes32, bool) external override {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();

        if (
            abi.decode(StorageAccessible(address(safe)).getStorageAt(uint256(GUARD_STORAGE_SLOT), 1), (address))
                != address(this)
        ) {
            revert CannotDisableThisGuard(address(this));
        }

        if (safe.getThreshold() != _getCorrectThreshold()) {
            revert SignersCannotChangeThreshold();
        }

        // SENTINEL_OWNERS and SENTINEL_MODULES are both address(0x1)
        (address[] memory modules,) = safe.getModulesPaginated(SENTINEL_OWNERS, enabledModuleCount + 1);
        if (keccak256(abi.encode(modules)) != _existingModulesHash) {
            revert SignersCannotChangeModules();
        }

        // leave checked to catch underflows triggered by re-erntry attempts
        --_guardEntries;
    }

    /// @notice Internal function to calculate the threshold that `safe` should have, given the correct `signerCount`, `minThreshold`, and `targetThreshold`
    /// @return _threshold The correct threshold
    function _getCorrectThreshold() internal view returns (uint256 _threshold) {
        uint256 count = _countValidSigners(safe.getOwners());
        uint256 min = minThreshold;
        uint256 max = targetThreshold;
        if (count < min) _threshold = min;
        else if (count > max) _threshold = max;
        else _threshold = count;
    }

    /// @notice Counts the number of hats-valid signatures within a set of `signatures`
    /// @dev modified from https://github.com/safe-global/safe-contracts/blob/c36bcab46578a442862d043e12a83fec41143dec/contracts/GnosisSafe.sol#L240
    /// @param dataHash The signed data
    /// @param signatures The set of signatures to check
    /// @return validSigCount The number of hats-valid signatures
    function countValidSignatures(bytes32 dataHash, bytes memory signatures, uint256 sigCount)
        public
        view
        returns (uint256 validSigCount)
    {
        // There cannot be an owner with address 0.
        address currentOwner;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 i;

        for (i; i < sigCount;) {
            (v, r, s) = signatureSplit(signatures, i);
            if (v == 0) {
                // If v is 0 then it is a contract signature
                // When handling contract signatures the address of the contract is encoded into r
                currentOwner = address(uint160(uint256(r)));
            } else if (v == 1) {
                // If v is 1 then it is an approved hash
                // When handling approved hashes the address of the approver is encoded into r
                currentOwner = address(uint160(uint256(r)));
            } else if (v > 30) {
                // If v > 30 then default va (27,28) has been adjusted for eth_sign flow
                // To support eth_sign and similar we adjust v and hash the messageHash with the Ethereum message prefix before applying ecrecover
                currentOwner =
                    ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)), v - 4, r, s);
            } else {
                // Default is the ecrecover flow with the provided data hash
                // Use ecrecover with the messageHash for EOA signatures
                currentOwner = ecrecover(dataHash, v, r, s);
            }

            if (isValidSigner(currentOwner)) {
                // shouldn't overflow given reasonable sigCount
                unchecked {
                    ++validSigCount;
                }
            }
            // shouldn't overflow given reasonable sigCount
            unchecked {
                ++i;
            }
        }
    }
}
