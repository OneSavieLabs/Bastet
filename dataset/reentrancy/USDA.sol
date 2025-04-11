// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ExponentialNoError} from '@contracts/utils/ExponentialNoError.sol';
import {Roles} from '@contracts/utils/Roles.sol';
import {UFragments} from '@contracts/utils/UFragments.sol';

import {IUSDA} from '@interfaces/core/IUSDA.sol';
import {IVaultController} from '@interfaces/core/IVaultController.sol';

import {IERC20Metadata, IERC20} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';
import {Context} from '@openzeppelin/contracts/utils/Context.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

/// @notice USDA token contract, handles all minting/burning of usda
/// @dev extends UFragments
contract USDA is Pausable, UFragments, IUSDA, ExponentialNoError, Roles {
  using EnumerableSet for EnumerableSet.AddressSet;

  bytes32 public constant VAULT_CONTROLLER_ROLE = keccak256('VAULT_CONTROLLER');

  EnumerableSet.AddressSet internal _vaultControllers;

  /// @dev The reserve token
  IERC20 public sUSD;

  /// @dev The address of the pauser
  address public pauser;

  /// @dev The reserve amount
  uint256 public reserveAmount;

  /// @notice Checks if _msgSender() is a valid VaultController
  modifier onlyVaultController() {
    _checkRole(VAULT_CONTROLLER_ROLE, _msgSender());
    _;
  }

  /// @notice Checks if _msgSender() is pauser
  modifier onlyPauser() {
    if (_msgSender() != address(pauser)) revert USDA_OnlyPauser();
    _;
  }

  /// @notice Any function with this modifier will call the pay_interest() function before any function logic is called
  modifier paysInterest() {
    for (uint256 _i; _i < _vaultControllers.length();) {
      IVaultController(_vaultControllers.at(_i)).calculateInterest();
      unchecked {
        _i++;
      }
    }
    _;
  }

  constructor(IERC20 _sUSDAddr) UFragments('USDA Token', 'USDA') {
    sUSD = _sUSDAddr;
  }

  /// @notice Sets the pauser for both USDA and VaultController
  /// @dev The pauser is a separate role from the owner
  function setPauser(address _pauser) external override onlyOwner {
    pauser = _pauser;

    emit PauserSet(_pauser);
  }

  /// @notice Pause contract
  /// @dev Can only be called by the pauser
  function pause() external override onlyPauser {
    _pause();
  }

  /// @notice Unpause contract, pauser only
  /// @dev Can only be called by the pauser
  function unpause() external override onlyPauser {
    _unpause();
  }

  /// @notice Deposit sUSD to mint USDA
  /// @dev Caller should obtain 1 USDA for each sUSD
  /// the calculations for deposit mimic the calculations done by mint in the ampleforth contract, simply with the susd transfer
  /// 'fragments' are the units that we see, so 1000 fragments == 1000 USDA
  /// 'gons' are the internal accounting unit, used to keep scale.
  /// We use the variable _gonsPerFragment in order to convert between the two
  /// try dimensional analysis when doing the math in order to verify units are correct
  /// @param _susdAmount The amount of sUSD to deposit
  function deposit(uint256 _susdAmount) external override {
    _deposit(_susdAmount, _msgSender());
  }

  /// @notice Deposits sUSD to mint USDA and transfer to a different address
  /// @param _susdAmount The amount of sUSD to deposit
  /// @param _target The address to receive the USDA tokens
  function depositTo(uint256 _susdAmount, address _target) external override {
    _deposit(_susdAmount, _target);
  }

  /// @notice Business logic to deposit sUSD and mint USDA for the caller
  function _deposit(uint256 _susdAmount, address _target) internal paysInterest whenNotPaused {
    if (_susdAmount == 0) revert USDA_ZeroAmount();
    sUSD.transferFrom(_msgSender(), address(this), _susdAmount);
    _mint(_target, _susdAmount);
    // Account for the susd received
    reserveAmount += _susdAmount;

    emit Deposit(_target, _susdAmount);
  }

  /// @notice Withdraw sUSD by burning USDA
  /// @dev The caller should obtain 1 sUSD for every 1 USDA
  /// @param _susdAmount The amount of sUSD to withdraw
  function withdraw(uint256 _susdAmount) external override {
    _withdraw(_susdAmount, _msgSender());
  }

  /// @notice Withdraw sUSD to a specific address by burning USDA from the caller
  /// @dev The _target address should obtain 1 sUSD for every 1 USDA burned from the caller
  /// @param _susdAmount amount of sUSD to withdraw
  /// @param _target address to receive the sUSD
  function withdrawTo(uint256 _susdAmount, address _target) external override {
    _withdraw(_susdAmount, _target);
  }

  /// @notice Withdraw sUSD by burning USDA
  /// @dev The caller should obtain 1 sUSD for every 1 USDA
  /// @dev This function is effectively just withdraw, but we calculate the amount for the sender
  /// @param _susdWithdrawn The amount os sUSD withdrawn
  function withdrawAll() external override returns (uint256 _susdWithdrawn) {
    uint256 _balance = this.balanceOf(_msgSender());
    _susdWithdrawn = _balance > reserveAmount ? reserveAmount : _balance;
    _withdraw(_susdWithdrawn, _msgSender());
  }

  /// @notice Withdraw sUSD by burning USDA
  /// @dev This function is effectively just withdraw, but we calculate the amount for the _target
  /// @param _target should obtain 1 sUSD for every 1 USDA burned from caller
  /// @param _susdWithdrawn The amount os sUSD withdrawn
  function withdrawAllTo(address _target) external override returns (uint256 _susdWithdrawn) {
    uint256 _balance = this.balanceOf(_msgSender());
    _susdWithdrawn = _balance > reserveAmount ? reserveAmount : _balance;
    _withdraw(_susdWithdrawn, _target);
  }

  /// @notice business logic to withdraw sUSD and burn USDA from the caller
  function _withdraw(uint256 _susdAmount, address _target) internal paysInterest whenNotPaused {
    if (reserveAmount == 0) revert USDA_EmptyReserve();
    if (_susdAmount == 0) revert USDA_ZeroAmount();
    if (_susdAmount > this.balanceOf(_msgSender())) revert USDA_InsufficientFunds();
    // Account for the susd withdrawn
    reserveAmount -= _susdAmount;
    sUSD.transfer(_target, _susdAmount);
    _burn(_msgSender(), _susdAmount);

    emit Withdraw(_target, _susdAmount);
  }

  /// @notice Admin function to mint USDA
  /// @param _susdAmount The amount of USDA to mint, denominated in sUSD
  function mint(uint256 _susdAmount) external override paysInterest onlyOwner {
    if (_susdAmount == 0) revert USDA_ZeroAmount();
    _mint(_msgSender(), _susdAmount);
  }

  /// @dev mint a specific `amount` of tokens to the `target`
  function _mint(address _target, uint256 _amount) internal {
    uint256 __gonsPerFragment = _gonsPerFragment;
    // the gonbalances of the sender is in gons, therefore we must multiply the deposit amount, which is in fragments, by gonsperfragment
    _gonBalances[_target] += _amount * __gonsPerFragment;
    // total supply is in fragments, and so we add amount
    _totalSupply += _amount;
    // and totalgons of course is in gons, and so we multiply amount by gonsperfragment to get the amount of gons we must add to totalGons
    _totalGons += _amount * __gonsPerFragment;
    // emit both a mint and transfer event
    emit Transfer(address(0), _target, _amount);
    emit Mint(_target, _amount);
  }

  /// @notice Admin function to burn USDA
  /// @param _susdAmount The amount of USDA to burn, denominated in sUSD
  function burn(uint256 _susdAmount) external override paysInterest onlyOwner {
    if (_susdAmount == 0) revert USDA_ZeroAmount();
    _burn(_msgSender(), _susdAmount);
  }

  /// @dev burn a specific `amount` of tokens from the `target`
  function _burn(address _target, uint256 _amount) internal {
    uint256 __gonsPerFragment = _gonsPerFragment;
    // modify the gonbalances of the sender, subtracting the amount of gons, therefore amount * gonsperfragment
    _gonBalances[_target] -= (_amount * __gonsPerFragment);
    // modify totalSupply and totalGons
    _totalSupply -= _amount;
    _totalGons -= (_amount * __gonsPerFragment);
    // emit both a burn and transfer event
    emit Transfer(_target, address(0), _amount);
    emit Burn(_target, _amount);
  }

  /// @notice Donates susd to the protocol reserve
  /// @param _susdAmount The amount of sUSD to donate
  function donate(uint256 _susdAmount) external override paysInterest whenNotPaused {
    if (_susdAmount == 0) revert USDA_ZeroAmount();
    // Account for the susd received
    reserveAmount += _susdAmount;
    sUSD.transferFrom(_msgSender(), address(this), _susdAmount);
    _donation(_susdAmount);
  }

  /// @notice Recovers accidentally sent sUSD to this contract
  /// @param _to The receiver of the dust
  function recoverDust(address _to) external onlyOwner {
    // All sUSD sent directly to the contract is not accounted into the reserveAmount
    // This function allows governance to recover it
    uint256 _amount = sUSD.balanceOf(address(this)) - reserveAmount;
    sUSD.transfer(_to, _amount);

    emit RecoveredDust(owner(), _amount);
  }

  /// @notice Function for the vaultController to mint
  /// @param _target The address to mint the USDA to
  /// @param _amount The amount of USDA to mint
  function vaultControllerMint(address _target, uint256 _amount) external override onlyVaultController whenNotPaused {
    _mint(_target, _amount);
  }

  /// @notice Function for the vaultController to burn
  /// @param _target The address to burn the USDA from
  /// @param _amount The amount of USDA to burn
  function vaultControllerBurn(address _target, uint256 _amount) external override onlyVaultController {
    if (_gonBalances[_target] < (_amount * _gonsPerFragment)) revert USDA_NotEnoughBalance();
    _burn(_target, _amount);
  }

  /// @notice Allows VaultController to send sUSD from the reserve
  /// @param _target The address to receive the sUSD from reserve
  /// @param _susdAmount The amount of sUSD to send
  function vaultControllerTransfer(
    address _target,
    uint256 _susdAmount
  ) external override onlyVaultController whenNotPaused {
    // Account for the susd withdrawn
    reserveAmount -= _susdAmount;
    // ensure transfer success
    sUSD.transfer(_target, _susdAmount);

    emit VaultControllerTransfer(_target, _susdAmount);
  }

  /// @notice Function for the vaultController to scale all USDA balances
  /// @param _amount The amount of USDA (e18) to donate
  function vaultControllerDonate(uint256 _amount) external override onlyVaultController {
    _donation(_amount);
  }

  /// @notice Function for distributing the donation to all USDA holders
  /// @param _amount The amount of USDA to donate
  function _donation(uint256 _amount) internal {
    _totalSupply += _amount;
    if (_totalSupply > MAX_SUPPLY) _totalSupply = MAX_SUPPLY;
    _gonsPerFragment = _totalGons / _totalSupply;
    emit Donation(_msgSender(), _amount, _totalSupply);
  }

  /// @notice Returns the reserve ratio
  /// @return _e18reserveRatio The USDA reserve ratio
  function reserveRatio() external view override returns (uint192 _e18reserveRatio) {
    _e18reserveRatio = _safeu192((reserveAmount * EXP_SCALE) / _totalSupply);
  }

  /*///////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

  /// @notice Adds a new vault controller
  /// @param _vaultController The new vault controller to add
  function addVaultController(address _vaultController) external onlyOwner {
    _vaultControllers.add(_vaultController);
    _grantRole(VAULT_CONTROLLER_ROLE, _vaultController);

    emit VaultControllerAdded(_vaultController);
  }

  /// @notice Removes a vault controller
  /// @param _vaultController The vault controller to remove
  function removeVaultController(address _vaultController) external onlyOwner {
    _vaultControllers.remove(_vaultController);
    _revokeRole(VAULT_CONTROLLER_ROLE, _vaultController);

    emit VaultControllerRemoved(_vaultController);
  }

  /// @notice Removes a vault controller from the list
  /// @param _vaultController The vault controller to remove
  /// @dev The vault controller is removed from the list but keeps the role as to not brick it
  function removeVaultControllerFromList(address _vaultController) external onlyOwner {
    _vaultControllers.remove(_vaultController);

    emit VaultControllerRemovedFromList(_vaultController);
  }
}
