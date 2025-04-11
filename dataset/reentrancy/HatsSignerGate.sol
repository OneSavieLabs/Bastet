// SPDX-License-Identifier: LGPL-3.0
pragma solidity >=0.8.13;

// import { Test, console2 } from "../lib/forge-std/src/Test.sol"; // comment out after testing
import { IHats } from "../lib/hats-protocol/src/Interfaces/IHats.sol";
import { SafeManagerLib } from "./lib/SafeManagerLib.sol";
import { IHatsSignerGate } from "./interfaces/IHatsSignerGate.sol";
import { Initializable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { BaseGuard } from "../lib/zodiac/contracts/guard/BaseGuard.sol";
import { GuardableUnowned } from "./lib/zodiac-modified/GuardableUnowned.sol";
import { ModifierUnowned } from "./lib/zodiac-modified/ModifierUnowned.sol";
import { Multicallable } from "../lib/solady/src/utils/Multicallable.sol";
import { SignatureDecoder } from "../lib/safe-smart-account/contracts/common/SignatureDecoder.sol";
import { ISafe, Enum } from "./lib/safe-interfaces/ISafe.sol";

/// @title HatsSignerGate
/// @author Haberdasher Labs
/// @author @spengrah
/// @author @gershido
/// @notice A Zodiac compatible contract for managing a Safe's signers and signatures via Hats Protocol.
/// - As a module on the Safe, it allows for signers to be added and removed based on Hats Protocol hats.
/// - As a guard on the Safe, it ensures that transactions can only be executed by valid hat-wearing signers.
/// - It also serves as a Zodiac modifier, allowing the Safe's functionality to be safely extended by attaching modules
/// and a guard to HatsSignerGate itself.
/// - An owner can control the HatsSignerGate's settings and behavior through various owner-only functions.
/// @dev This contract is designed to work with the Zodiac Module Factory, from which instances are deployed.
contract HatsSignerGate is
  IHatsSignerGate,
  BaseGuard,
  GuardableUnowned,
  ModifierUnowned,
  Multicallable,
  SignatureDecoder,
  Initializable
{
  using SafeManagerLib for ISafe;

  /*//////////////////////////////////////////////////////////////
                            CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  IHats public immutable HATS;

  /// @dev The address of the Safe singleton contract used to deploy new Safes
  address internal immutable SAFE_SINGLETON;

  /// @dev The address of the Safe fallback library used to deploy new Safes
  address internal immutable SAFE_FALLBACK_LIBRARY;

  /// @dev The address of the Safe multisend library used to deploy new Safes
  address internal immutable SAFE_MULTISEND_LIBRARY;

  /// @dev The address of the Safe proxy factory used to deploy new Safes
  address internal immutable SAFE_PROXY_FACTORY;

  /// @inheritdoc IHatsSignerGate
  string public constant version = "2.0.0";

  /*//////////////////////////////////////////////////////////////
                         PUBLIC MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  ISafe public safe;

  /// @inheritdoc IHatsSignerGate
  bool public locked;

  /// @inheritdoc IHatsSignerGate
  bool public claimableFor;

  /// @inheritdoc IHatsSignerGate
  address public implementation;

  /// @inheritdoc IHatsSignerGate
  uint256 public ownerHat;

  /// @inheritdoc IHatsSignerGate
  mapping(address => bool) public enabledDelegatecallTargets;

  /// @inheritdoc IHatsSignerGate
  mapping(address => uint256) public registeredSignerHats;

  /*//////////////////////////////////////////////////////////////
                        INTERNAL MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  /// @dev Append-only tracker of approved signer hats
  mapping(uint256 => bool) internal _validSignerHats;

  /// @dev The threshold configuration
  ThresholdConfig internal _thresholdConfig;

  /*//////////////////////////////////////////////////////////////
                          TRANSIENT STATE
  //////////////////////////////////////////////////////////////*/
  
  /// @dev Temporary record of the existing owners on the `safe` when a transaction is submitted
  bytes32 transient _existingOwnersHash;
  
  /// @dev Temporary record of the existing threshold on the `safe` when a transaction is submitted
  uint256 transient _existingThreshold;
  
  /// @dev Temporary record of the existing fallback handler on the `safe` when a transaction is submitted
  address transient _existingFallbackHandler;
  
  /// @dev Temporary record of the operation type when a transaction is submitted
  Enum.Operation transient _operation;
  
  /// @dev A simple re-entrancy guard
  uint256 transient _reentrancyGuard;
  
  /// @dev The safe's nonce at the beginning of a transaction
  uint256 transient _initialNonce;
  
  /// @dev The number of times the checkTransaction function has been called in a transaction
  uint256 transient _entrancyCounter;
  
  /*//////////////////////////////////////////////////////////////
                      AUTHENTICATION FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Internal function to check if the caller is wearing the owner hat
  function _checkOwner() internal view {
    if (!HATS.isWearerOfHat(msg.sender, ownerHat)) revert NotOwnerHatWearer();
  }

  /// @dev Internal function to check if the contract is unlocked
  function _checkUnlocked() internal view {
    if (locked) revert Locked();
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(
    address _hats,
    address _safeSingleton,
    address _safeFallbackLibrary,
    address _safeMultisendLibrary,
    address _safeProxyFactory
  ) initializer {
    HATS = IHats(_hats);
    SAFE_PROXY_FACTORY = _safeProxyFactory;
    SAFE_SINGLETON = _safeSingleton;
    SAFE_FALLBACK_LIBRARY = _safeFallbackLibrary;
    SAFE_MULTISEND_LIBRARY = _safeMultisendLibrary;

    // set the implementation's owner hat to a nonexistent hat to prevent state changes to the implementation
    ownerHat = 1;
  }

  /*//////////////////////////////////////////////////////////////
                              INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  function setUp(bytes calldata initializeParams) public payable initializer {
    SetupParams memory params = abi.decode(initializeParams, (SetupParams));

    // deploy a new safe if there is no provided safe
    if (params.safe == address(0)) {
      params.safe = SafeManagerLib.deploySafeAndAttachHSG(
        SAFE_PROXY_FACTORY, SAFE_SINGLETON, SAFE_FALLBACK_LIBRARY, SAFE_MULTISEND_LIBRARY
      );
    }

    // set the instance's owner hat
    _setOwnerHat(params.ownerHat);
    // lock the instance if configured as such
    if (params.locked) _lock();

    // set the instance's claimableFor flag
    _setClaimableFor(params.claimableFor);

    // set the instance's safe and signer parameters
    safe = ISafe(params.safe);
    _addSignerHats(params.signerHats);
    _setThresholdConfig(params.thresholdConfig);

    // set the instance's metadata
    implementation = params.implementation;

    // initialize the modules linked list, and set initial modules, if any
    setupModules();
    for (uint256 i; i < params.hsgModules.length; ++i) {
      _enableModule(params.hsgModules[i]);
    }

    // set the initial guard, if any
    if (params.hsgGuard != address(0)) _setGuard(params.hsgGuard);

    // enable default delegatecall targets
    _setDelegatecallTarget(0x40A2aCCbd92BCA938b02010E17A5b8929b49130D, true); // multisend-call-only v1.3.0 "canonical"
    _setDelegatecallTarget(0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B, true); // multisend-call-only v1.3.0 "eip155"
    _setDelegatecallTarget(0x9641d764fc13c8B624c04430C7356C1C7C8102e2, true); // multisend-call-only v1.4.1 "canonical"
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  function claimSigner(uint256 _hatId) public {
    // register the signer
    _registerSigner({ _hatToRegister: _hatId, _signer: msg.sender, _allowReregistration: true });

    // add the signer
    _addSigner(msg.sender);
  }

  /// @inheritdoc IHatsSignerGate
  function claimSignerFor(uint256 _hatId, address _signer) public {
    // check that signer permissions are claimable for
    if (!claimableFor) revert NotClaimableFor();

    // register the signer, reverting if invalid or already registered
    _registerSigner({ _hatToRegister: _hatId, _signer: _signer, _allowReregistration: false });

    // add the signer
    _addSigner(_signer);
  }

  /// @inheritdoc IHatsSignerGate
  function claimSignersFor(uint256[] calldata _hatIds, address[] calldata _signers) public {
    // check that signer permissions are claimable for
    if (!claimableFor) revert NotClaimableFor();

    // check that the arrays are the same length
    uint256 toClaimCount = _signers.length;
    if (_hatIds.length != toClaimCount) revert InvalidArrayLength();

    ISafe s = safe;
    // get the current threshold
    uint256 threshold = s.getThreshold();
    // get the current owners
    address[] memory owners = s.getOwners();

    // check if the only owner is this contract, meaning no owners have been added yet
    bool isInitialOwnersState = owners.length == 1 && owners[0] == address(this);

    // count the number of owners after the claim
    uint256 newNumOwners = owners.length;

    // iterate through the arrays, adding each signer
    for (uint256 i; i < toClaimCount; ++i) {
      uint256 hatId = _hatIds[i];
      address signer = _signers[i];

      // register the signer, reverting if invalid or already registered
      _registerSigner({ _hatToRegister: hatId, _signer: signer, _allowReregistration: false });

      // if the signer is not an owner, add them
      if (!s.isOwner(signer)) {
        // initiate the addOwnerData, to be conditionally set below
        bytes memory addOwnerData;

        // for the first signer, check if the only owner is this contract and swap it out if so
        if (i == 0 && isInitialOwnersState) {
          addOwnerData = SafeManagerLib.encodeSwapOwnerAction(SafeManagerLib.SENTINELS, address(this), signer);
        } else {
          // otherwise, add the claimer as a new owner
          addOwnerData = SafeManagerLib.encodeAddOwnerWithThresholdAction(signer, threshold);
          newNumOwners++;
        }

        // execute the call
        s.execSafeTransactionFromHSG(addOwnerData);
      }
    }

    // update the threshold if necessary
    uint256 newThreshold = _getNewThreshold(newNumOwners);
    if (newThreshold != threshold) {
      safe.execChangeThreshold(newThreshold);
    }
  }

  /// @inheritdoc IHatsSignerGate
  function removeSigner(address _signer) public {
    if (isValidSigner(_signer)) revert StillWearsSignerHat();

    // remove the signer from the safe and unregister them
    _removeSigner(_signer);
  }

  /*//////////////////////////////////////////////////////////////
                        OWNER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  function lock() public {
    _checkUnlocked();
    _checkOwner();
    _lock();
  }

  /// @inheritdoc IHatsSignerGate
  function setOwnerHat(uint256 _ownerHat) public {
    _checkUnlocked();
    _checkOwner();
    _setOwnerHat(_ownerHat);
  }

  /// @inheritdoc IHatsSignerGate
  function addSignerHats(uint256[] calldata _newSignerHats) external {
    _checkUnlocked();
    _checkOwner();
    _addSignerHats(_newSignerHats);
  }

  /// @inheritdoc IHatsSignerGate
  function setThresholdConfig(ThresholdConfig calldata _config) public {
    _checkUnlocked();
    _checkOwner();
    _setThresholdConfig(_config);

    // update the safe's threshold to match the new config
    address[] memory owners = safe.getOwners();
    // get the required amount of valid signatures according to the new threshold config
    // and the current number of owners
    uint256 newThreshold = _getRequiredValidSignatures(owners.length);
    // the safe's threshold cannot be higher than the number of owners (safe's invariant)
    if (newThreshold > owners.length) {
      newThreshold = owners.length;
    }

    safe.execChangeThreshold(newThreshold);
  }

  /// @inheritdoc IHatsSignerGate
  function setClaimableFor(bool _claimableFor) public {
    _checkUnlocked();
    _checkOwner();
    _setClaimableFor(_claimableFor);
  }

  /// @inheritdoc IHatsSignerGate
  function detachHSG() public {
    _checkUnlocked();
    _checkOwner();
    ISafe s = safe; // save SLOAD

    // first remove as guard, then as module
    s.execRemoveHSGAsGuard();
    s.execDisableHSGAsOnlyModule();
    emit Detached();
  }

  /// @inheritdoc IHatsSignerGate
  function migrateToNewHSG(address _newHSG, uint256[] calldata _signerHatIds, address[] calldata _signersToMigrate)
    public
  {
    _checkUnlocked();
    _checkOwner();

    ISafe s = safe; // save SLOADS
    // remove existing HSG as guard
    s.execRemoveHSGAsGuard();
    // enable new HSG as module and guard
    s.execAttachNewHSG(_newHSG);
    // remove existing HSG as module
    s.execDisableHSGAsModule(_newHSG);

    // if _signersToMigrate is provided, migrate them to the new HSG by calling claimSignersFor()
    uint256 toMigrateCount = _signersToMigrate.length;
    if (toMigrateCount > 0) {
      // check that the arrays are the same length
      if (_signerHatIds.length != toMigrateCount) revert InvalidArrayLength();

      IHatsSignerGate(_newHSG).claimSignersFor(_signerHatIds, _signersToMigrate);
    }
    emit Migrated(_newHSG);
  }

  /// @inheritdoc IHatsSignerGate
  function enableDelegatecallTarget(address _target) public {
    _checkUnlocked();
    _checkOwner();

    _setDelegatecallTarget(_target, true);
  }

  /// @inheritdoc IHatsSignerGate
  function disableDelegatecallTarget(address _target) public {
    _checkUnlocked();
    _checkOwner();

    _setDelegatecallTarget(_target, false);
  }

  /*//////////////////////////////////////////////////////////////
                      ZODIAC GUARD FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc BaseGuard
  /// @notice Only approved delegatecall targets are allowed
  function checkTransaction(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address payable refundReceiver,
    bytes memory signatures,
    address // msgSender
  ) public override {
    // ensure that the call is coming from the safe
    if (msg.sender != address(safe)) revert NotCalledFromSafe();

    // if _reentrancyGuard equals 1 it means that there is an ongoing execution either from execTransactionFromModule or
    // execTransactionFromModuleReturnData.
    // this check prevents entering the checkTransaction in this case in order to avoid overriding the snapshot of the
    // Safe state
    if (_reentrancyGuard == 1) revert NoReentryAllowed();

    // record the initial nonce of the safe at the beginning of the transaction
    if (_entrancyCounter == 0) {
      _initialNonce = safe.nonce() - 1;
    }

    // increment the entrancy count
    _entrancyCounter++;

    // Whenever this function is called from a source other than Safe.execTransaction, it`s possible that
    // it is a malicious call attempting to manipulate the transient storage so that an attacker can
    // make malicious changes to the Safe state without detection by this guard in
    // IGuard.checkAfterExecution. To prevent this, we rely on the invariant that the Safe nonce
    // increments every time Safe.execTransaction calls out to IGuard.checkTransaction, allowing us to
    // ensure that this function is only called the same number of times in a single transaction as
    // Safe.execTransaction calls, ie by how much the Safe's nonce increases.
    if (safe.nonce() - _initialNonce != _entrancyCounter) revert NoReentryAllowed();

    // module guard preflight check
    if (guard != address(0)) {
      BaseGuard(guard).checkTransaction(
        to,
        value,
        data,
        operation,
        // Zero out the redundant transaction information only used for Safe multisig transctions.
        0,
        0,
        0,
        address(0),
        payable(0),
        "",
        address(0)
      );
    }

    // get the existing owners and threshold
    address[] memory owners = safe.getOwners();
    uint256 threshold = safe.getThreshold();

    // We record the operation type to guide the post-flight checks
    _operation = operation;

    if (operation == Enum.Operation.DelegateCall) {
      // case: DELEGATECALL
      // We disallow delegatecalls to unapproved targets
      if (!enabledDelegatecallTargets[to]) revert DelegatecallTargetNotEnabled();

      // Otherwise record the existing owners and threshold for post-flight checks to ensure that Safe state has not
      // been altered
      _existingOwnersHash = keccak256(abi.encode(owners));
      _existingThreshold = threshold;
      _existingFallbackHandler = safe.getSafeFallbackHandler();
    } else if (to == address(safe)) {
      // case: CALL to the safe
      // We disallow external calls to the safe itself. Together with the above check, this ensures there are no
      // unauthorized calls into the Safe itself
      revert CannotCallSafe();
    }

    // case: CALL to a non-Safe target
    // We can proceed to signer validation

    // the safe's threshold is always the minimum between the required amount of valid signatures and the number of
    // owners. if the threshold is lower than the required amount of valid signatures, it means that there are currently
    // not enough owners to approve the tx, so we can revert without further checks
    if (threshold != _getRequiredValidSignatures(owners.length)) revert ThresholdTooLow();

    // get the tx hash
    bytes32 txHash = safe.getTransactionHash(
      to,
      value,
      data,
      operation,
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      // We subtract 1 since nonce was just incremented in the parent function call
      safe.nonce() - 1
    );

    // count the number of valid signatures and revert if there aren't enough
    if (_countValidSignatures(txHash, signatures, threshold) < threshold) revert InsufficientValidSignatures();
  }

  /**
   * @notice Post-flight check to prevent `safe` signers from performing any of the following actions:
   *         1. removing this contract guard
   *         2. changing any modules
   *         3. changing the threshold
   *         4. changing the owners
   *     CAUTION: If the safe has any authority over the signersHat(s) — i.e. wears their admin hat(s) or is an
   *     eligibility or toggle module — then in some cases protections (3) and (4) may not hold. Proceed with caution if
   *     considering granting such authority to the safe.
   * @dev Modified from
   * https://github.com/gnosis/zodiac-guard-mod/blob/988ebc7b71e352f121a0be5f6ae37e79e47a4541/contracts/ModGuard.sol#L86
   */
  function checkAfterExecution(bytes32, bool) public override {
    // module guard postflight check
    if (guard != address(0)) {
      BaseGuard(guard).checkAfterExecution(bytes32(0), false);
    }

    // if the transaction was a delegatecall, perform the post-flight check on the Safe state
    // we don't need to check the Safe state for regular calls since the Safe state cannot be altered except by calling
    // into the Safe, which is explicitly disallowed
    if (_operation == Enum.Operation.DelegateCall) {
      _checkSafeState(safe);
    }
  }

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsSignerGate
  function thresholdConfig() public view returns (ThresholdConfig memory) {
    return _thresholdConfig;
  }

  /// @inheritdoc IHatsSignerGate
  function isValidSigner(address _account) public view returns (bool valid) {
    /// @dev existing `registeredSignerHats` are always valid, since `_validSignerHats` is append-only
    /// We don't need a special case for `_account == address(0)` because the 0 hat id does not exist
    valid = HATS.isWearerOfHat(_account, registeredSignerHats[_account]);
  }

  /// @inheritdoc IHatsSignerGate
  function isValidSignerHat(uint256 _hatId) public view returns (bool valid) {
    valid = _validSignerHats[_hatId];
  }

  /// @inheritdoc IHatsSignerGate
  function validSignerCount() public view returns (uint256 signerCount) {
    signerCount = _countValidSigners(safe.getOwners());
  }

  /// @inheritdoc IHatsSignerGate
  function canAttachToSafe(ISafe _safe) public view returns (bool) {
    return _safe.canAttachHSG();
  }

  /// @inheritdoc IHatsSignerGate
  function getSafeDeployParamAddresses()
    public
    view
    returns (
      address _safeSingleton,
      address _safeFallbackLibrary,
      address _safeMultisendLibrary,
      address _safeProxyFactory
    )
  {
    return (SAFE_SINGLETON, SAFE_FALLBACK_LIBRARY, SAFE_MULTISEND_LIBRARY, SAFE_PROXY_FACTORY);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Internal function to set the owner hat
  /// @param _ownerHat The hat id to set as the owner hat
  function _setOwnerHat(uint256 _ownerHat) internal {
    ownerHat = _ownerHat;
    emit OwnerHatSet(_ownerHat);
  }

  /// @dev Internal function to approve new signer hats. Empty arrays and duplicate hats cause no harm, so they are
  /// allowed.
  /// @param _newSignerHats Array of hat ids to add as approved signer hats
  function _addSignerHats(uint256[] memory _newSignerHats) internal {
    for (uint256 i; i < _newSignerHats.length; ++i) {
      _validSignerHats[_newSignerHats[i]] = true;
    }

    emit SignerHatsAdded(_newSignerHats);
  }

  /// @dev Internal function to set the threshold config
  /// @param _config the new threshold config
  function _setThresholdConfig(ThresholdConfig memory _config) internal {
    // min threshold cannot be 0
    if (_config.min == 0) revert InvalidThresholdConfig();

    if (_config.thresholdType == TargetThresholdType.ABSOLUTE) {
      // absolute target threshold cannot be lower than min threshold
      if (_config.target < _config.min) revert InvalidThresholdConfig();
    } else {
      // proportional threshold cannot be greater than 100%
      if (_config.target > 10_000) revert InvalidThresholdConfig();
    }
    // set the threshold config
    _thresholdConfig = _config;

    // log the change
    emit ThresholdConfigSet(_config);
  }

  /// @dev Internal function to count the number of valid signers in an array of addresses. Does not check for
  /// duplicates.
  /// @param owners The addresses to check for validity
  /// @return signerCount The number of valid signers in `owners`
  function _countValidSigners(address[] memory owners) internal view returns (uint256 signerCount) {
    // count the existing safe owners that wear the signer hat
    for (uint256 i; i < owners.length; ++i) {
      if (isValidSigner(owners[i])) {
        // shouldn't overflow given reasonable owners array length
        unchecked {
          ++signerCount;
        }
      }
    }
  }

  /// @dev Counts the number of hats-valid signatures within a set of `signatures`
  /// @dev modified from
  /// https://github.com/safe-global/safe-contracts/blob/c36bcab46578a442862d043e12a83fec41143dec/contracts/Safe.sol#L240
  /// @param dataHash The signed data
  /// @param signatures The set of signatures to check
  /// @param sigCount The number of signatures to check
  /// @return validSigCount The number of hats-valid signatures
  function _countValidSignatures(bytes32 dataHash, bytes memory signatures, uint256 sigCount)
    internal
    view
    returns (uint256 validSigCount)
  {
    // There cannot be an owner with address 0.
    address currentOwner;
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 i;

    for (i; i < sigCount; ++i) {
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
        // To support eth_sign and similar we adjust v and hash the messageHash with the Ethereum message prefix before
        // applying ecrecover
        currentOwner = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)), v - 4, r, s);
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
    }
  }

  /// @dev Internal function to set the claimableFor parameter
  /// @param _claimableFor Whether signer permissions are claimable on behalf of valid hat wearers
  function _setClaimableFor(bool _claimableFor) internal {
    claimableFor = _claimableFor;
    emit ClaimableForSet(_claimableFor);
  }

  /// @dev Internal function to register a signer's hat if they are wearing a valid signer hat.
  /// @param _hatToRegister The id of the hat to register
  /// @param _signer The address to register
  /// @param _allowReregistration Whether to allow registration of a different hat for an existing signer
  function _registerSigner(uint256 _hatToRegister, address _signer, bool _allowReregistration) internal {
    // check that the hat is valid
    if (!isValidSignerHat(_hatToRegister)) revert InvalidSignerHat(_hatToRegister);

    // check that the signer is wearing the hat
    if (!HATS.isWearerOfHat(_signer, _hatToRegister)) revert NotSignerHatWearer(_signer);

    // if specified, disallow re-registering a new hat for an existing signer that is still wearing their
    // currently-registered hat
    if (!_allowReregistration) {
      if (HATS.isWearerOfHat(_signer, registeredSignerHats[_signer])) revert ReregistrationNotAllowed();
    }

    // register the hat used to claim. This will be the hat checked in `checkTransaction()` for this signer
    registeredSignerHats[_signer] = _hatToRegister;

    // log the registration
    emit Registered(_hatToRegister, _signer);
  }

  /// @dev Internal function to add a `_signer` to the `safe` if they are not already an owner.
  /// If this contract is the only owner on the `safe`, it will be swapped out for `_signer`. Otherwise, `_signer` will
  /// be added as a new owner.
  /// @param _signer The address to add as a new `safe` owner
  function _addSigner(address _signer) internal {
    ISafe s = safe;

    // if the signer is not already an owner, add them
    if (!s.isOwner(_signer)) {
      // get the current owners
      address[] memory owners = s.getOwners();

      // initiate the addOwnerData, to be conditionally set below
      bytes memory addOwnerData;

      // if the only owner is this contract (set as an owner on initialization), replace it with _signer
      if (owners.length == 1 && owners[0] == address(this)) {
        // set up the swapOwner call
        addOwnerData = SafeManagerLib.encodeSwapOwnerAction(SafeManagerLib.SENTINELS, address(this), _signer);
      } else {
        // update the threshold
        uint256 newThreshold = _getNewThreshold(owners.length + 1);
        // set up the addOwner call
        addOwnerData = SafeManagerLib.encodeAddOwnerWithThresholdAction(_signer, newThreshold);
      }

      // execute the call
      s.execSafeTransactionFromHSG(addOwnerData);
    }
  }

  /// @dev Internal function to remove a signer from the `safe`, updating the threshold if appropriate
  /// Unsafe. Does not check for signer validity before removal
  /// @param _signer The address to remove
  function _removeSigner(address _signer) internal {
    ISafe s = safe;
    bytes memory removeOwnerData;
    address[] memory owners = s.getOwners();

    delete registeredSignerHats[_signer];

    if (owners.length == 1) {
      // make address(this) the only owner
      removeOwnerData = SafeManagerLib.encodeSwapOwnerAction(SafeManagerLib.SENTINELS, _signer, address(this));
    } else {
      // update the threshold
      uint256 newThreshold = _getNewThreshold(owners.length - 1);

      removeOwnerData =
        SafeManagerLib.encodeRemoveOwnerAction(SafeManagerLib.findPrevOwner(owners, _signer), _signer, newThreshold);
    }

    // execute the call
    s.execSafeTransactionFromHSG(removeOwnerData);
  }

  /// @dev Internal function to calculate the required amount of valid signatures according to the current number of
  /// owners in the safe and the threshold config
  /// @param numOwners The number of owners in the safe
  /// @return _requiredValidSignatures The required amount of valid signatures
  function _getRequiredValidSignatures(uint256 numOwners) internal view returns (uint256 _requiredValidSignatures) {
    // get the threshold config
    ThresholdConfig memory config = _thresholdConfig;

    // calculate the correct threshold
    if (config.thresholdType == TargetThresholdType.ABSOLUTE) {
      // ABSOLUTE
      if (numOwners < config.min) _requiredValidSignatures = config.min;
      else if (numOwners > config.target) _requiredValidSignatures = config.target;
      else _requiredValidSignatures = numOwners;
    } else {
      // PROPORTIONAL
      // add 9999 to round up
      _requiredValidSignatures = ((numOwners * config.target) + 9999) / 10_000;
      // ensure that the threshold is not lower than the min threshold
      if (_requiredValidSignatures < config.min) _requiredValidSignatures = config.min;
    }
  }

  /// @dev Internal function to get the safe's threshold according to the current number of owners and the threshold
  /// config. The threshold is always the minimum between the required amount of valid signatures and the number of
  /// owners
  /// @param numOwners The number of owners in the safe
  /// @return _threshold The safe's threshold
  function _getNewThreshold(uint256 numOwners) internal view returns (uint256 _threshold) {
    // get the required amount of valid signatures according to the current number of owners and the threshold config
    _threshold = _getRequiredValidSignatures(numOwners);
    // the threshold cannot be higher than the number of owners
    if (_threshold > numOwners) {
      _threshold = numOwners;
    }
  }

  /// @dev Locks the contract, preventing any further owner changes
  function _lock() internal {
    locked = true;
    emit HSGLocked();
  }

  /// @dev Internal function to set a delegatecall target
  /// @param _target The address to set
  /// @param _enabled Whether to enable or disable the target
  function _setDelegatecallTarget(address _target, bool _enabled) internal {
    enabledDelegatecallTargets[_target] = _enabled;
    emit DelegatecallTargetEnabled(_target, _enabled);
  }

  // solhint-disallow-next-line payable-fallback
  fallback() external {
    // We don't revert on fallback to avoid issues in case of a Safe upgrade
    // E.g. The expected check method might change and then the Safe would be locked.
  }

  // /*//////////////////////////////////////////////////////////////
  //                     ZODIAC MODIFIER FUNCTIONS
  // //////////////////////////////////////////////////////////////*/

  /// @notice Allows a module to execute a call from the context of the Safe. Modules are not allowed to...
  /// - delegatecall to unapproved targets
  /// - change any Safe state, whether via a delegatecall to an approved target or a direct call
  /// @dev Can only be called by an enabled module.
  /// @dev Must emit ExecutionFromModuleSuccess(address module) if successful.
  /// @dev Must emit ExecutionFromModuleFailure(address module) if unsuccessful.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function execTransactionFromModule(address to, uint256 value, bytes calldata data, Enum.Operation operation)
    public
    override
    moduleOnly
    returns (bool success)
  {
    // perform pre-flight checks
    ISafe s = _beforeExecTransactionFromModule(to, operation);

    // forward the call to the safe
    success = s.execTransactionFromModule(to, value, data, operation);

    // perform post-flight checks and emit event
    _afterExecTransactionFromModule(success, operation, s);
  }

  /// @notice Allows a module to execute a call from the context of the Safe. Modules are not allowed to...
  /// - delegatecall to unapproved targets
  /// - change any Safe state, whether via a delegatecall to an approved target or a direct call
  /// @dev Can only be called by an enabled module.
  /// @dev Must emit ExecutionFromModuleSuccess(address module) if successful.
  /// @dev Must emit ExecutionFromModuleFailure(address module) if unsuccessful.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, Enum.Operation operation)
    public
    override
    moduleOnly
    returns (bool success, bytes memory returnData)
  {
    // perform pre-flight checks
    ISafe s = _beforeExecTransactionFromModule(to, operation);

    // forward the call to the safe
    (success, returnData) = s.execTransactionFromModuleReturnData(to, value, data, operation);

    // perform post-flight checks and emit event
    _afterExecTransactionFromModule(success, operation, s);
  }

  /// @inheritdoc ModifierUnowned
  /// @dev Only callable by a wearer of the owner hat, and only if the contract is not locked.
  function disableModule(address prevModule, address module) public override {
    _checkUnlocked();
    _checkOwner();
    super.disableModule(prevModule, module);
  }

  /// @notice Enables a module that can add transactions to the queue
  /// @dev Only callable by a wearer of the owner hat, and only if the contract is not locked.
  /// @param module Address of the module to be enabled
  function enableModule(address module) public {
    _checkUnlocked();
    _checkOwner();
    _enableModule(module);
  }

  /*//////////////////////////////////////////////////////////////
                      ZODIAC GUARD FUNCTION
  //////////////////////////////////////////////////////////////*/

  /// @notice Set a guard that checks transactions before execution.
  /// @dev Only callable by a wearer of the owner hat, and only if the contract is not locked.
  /// @param _guard The address of the guard to be used or the 0 address to disable the guard.
  function setGuard(address _guard) public {
    _checkUnlocked();
    _checkOwner();
    _setGuard(_guard);
  }

  /*//////////////////////////////////////////////////////////////
                    INTERNAL ZODIAC HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Internal function to check that a module transaction is valid. Modules are not allowed to...
  /// - delegatecall to unapproved targets
  /// - change any Safe state via a delegatecall to an approved target
  /// - call the safe directly (prevents Safe state changes)
  /// @param _to The address of the target of the module transaction
  /// @param operation_ The operation type of the module transaction
  /// @param _safe The safe that is executing the module transaction
  function _checkModuleTransaction(address _to, Enum.Operation operation_, ISafe _safe) internal {
    // preflight checks
    if (operation_ == Enum.Operation.DelegateCall) {
      // case: DELEGATECALL
      // We disallow delegatecalls to unapproved targets
      if (!enabledDelegatecallTargets[_to]) revert DelegatecallTargetNotEnabled();

      // If the delegatecall target is approved, we record the existing owners, threshold, and fallback handler for
      // post-flight check
      _existingOwnersHash = keccak256(abi.encode(_safe.getOwners()));
      _existingThreshold = _safe.getThreshold();
      _existingFallbackHandler = _safe.getSafeFallbackHandler();
    } else if (_to == address(_safe)) {
      // case: CALL to the safe
      // We disallow external calls to the safe itself. Together with the above check, this ensure there are no
      // unauthorized calls into the Safe itself
      revert CannotCallSafe();
    }

    // case: CALL to a non-Safe target
    // Return and proceed to subsequent logic
  }

  /// @dev Internal function to check that a delegatecall executed by the signers or a module do not change the
  /// `_safe`'s
  /// state.
  function _checkSafeState(ISafe _safe) internal view {
    if (_safe.getSafeGuard() != address(this)) revert CannotDisableThisGuard();

    // prevent signers from changing the threshold
    if (_safe.getThreshold() != _existingThreshold) revert CannotChangeThreshold();

    // prevent signers from changing the owners
    if (keccak256(abi.encode(_safe.getOwners())) != _existingOwnersHash) revert CannotChangeOwners();

    // prevent changes to the fallback handler
    if (_safe.getSafeFallbackHandler() != _existingFallbackHandler) revert CannotChangeFallbackHandler();

    // prevent signers from removing this module or adding any other modules
    (address[] memory modulesWith1, address next) = _safe.getModulesWith1();

    // ensure that there is only one module...
    // if the length is 0, we know this module has been removed
    // per Safe ModuleManager.sol#137, "If all entries fit into a single page, the next pointer will be 0x1", ie
    // SENTINELS. Therefore, if `next` is not SENTINELS, we know another module has been added.
    // We also check that the only module is this contract
    if (modulesWith1.length == 0 || next != SafeManagerLib.SENTINELS || modulesWith1[0] != address(this)) {
      revert CannotChangeModules();
    }
  }

  /// @dev Internal function to run the pre-flight checks for execTransactionFromModule and
  /// execTransactionFromModuleReturnData
  /// @param _to The address of the target of the module transaction
  /// @param operation_ The operation type of the module transaction
  /// @return _safe The safe that is executing the module transaction
  function _beforeExecTransactionFromModule(address _to, Enum.Operation operation_) internal returns (ISafe _safe) {
    // The _entrancyCounter transient variable counts the number of times that the checkTransaction function
    // was called in the current transaction. Calling checkTransaction prior to this function is unsafe since it may
    // override the safe state snapshot, so we revert.
    // The _reentrancyGuard tracks entrance into either execTransactionFromModule or execTransactionFromModuleReturnData.
    // Reentering either of those functions is unsafe since it may override the safe state snapshot, so we revert.
    if (_entrancyCounter > 0 || _reentrancyGuard == 1) revert NoReentryAllowed();

    // set the reentrancy guard
    _reentrancyGuard = 1;

    _safe = safe;

    // preflight checks
    _checkModuleTransaction(_to, operation_, _safe);
  }

  /// @dev Internal function to emit the appropriate execution status event and run the post-flight checks for
  /// execTransactionFromModule and execTransactionFromModuleReturnData
  /// @param _success The success status of the module transaction
  /// @param operation_ The operation type of the module transaction
  /// @param _safe The safe that is executing the module transaction
  function _afterExecTransactionFromModule(bool _success, Enum.Operation operation_, ISafe _safe) internal {
    // emit the appropriate execution status event
    if (_success) {
      emit ExecutionFromModuleSuccess(msg.sender);
    } else {
      emit ExecutionFromModuleFailure(msg.sender);
    }

    // Ensure that the Safe state is not altered by delegatecalls. We don't need to check the Safe state for regular
    // calls since the Safe state cannot be altered except by calling into the Safe, which is explicitly disallowed.
    if (operation_ == Enum.Operation.DelegateCall) _checkSafeState(_safe);

    // reset the reentrancy guard to enable future legitimate calls within the same transaction
    _reentrancyGuard = 0;
  }
}
