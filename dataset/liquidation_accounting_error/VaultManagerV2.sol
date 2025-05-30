// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {DNft}            from "./DNft.sol";
import {Dyad}            from "./Dyad.sol";
import {Licenser}        from "./Licenser.sol";
import {Vault}           from "./Vault.sol";
import {IVaultManager}   from "../interfaces/IVaultManager.sol";
import {KerosineManager} from "../../src/core/KerosineManager.sol";

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ERC20}             from "@solmate/src/tokens/ERC20.sol";
import {SafeTransferLib}   from "@solmate/src/utils/SafeTransferLib.sol";
import {EnumerableSet}     from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable}     from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract VaultManagerV2 is IVaultManager, Initializable {
  using EnumerableSet     for EnumerableSet.AddressSet;
  using FixedPointMathLib for uint;
  using SafeTransferLib   for ERC20;

  uint public constant MAX_VAULTS          = 5;
  uint public constant MAX_VAULTS_KEROSENE = 5;

  uint public constant MIN_COLLATERIZATION_RATIO = 1.5e18; // 150%
  uint public constant LIQUIDATION_REWARD        = 0.2e18; //  20%

  DNft     public immutable dNft;
  Dyad     public immutable dyad;
  Licenser public immutable vaultLicenser;

  KerosineManager public keroseneManager;

  mapping (uint => EnumerableSet.AddressSet) internal vaults; 
  mapping (uint => EnumerableSet.AddressSet) internal vaultsKerosene; 

  mapping (uint => uint) public idToBlockOfLastDeposit;

  modifier isDNftOwner(uint id) {
    if (dNft.ownerOf(id) != msg.sender)   revert NotOwner();    _;
  }
  modifier isValidDNft(uint id) {
    if (dNft.ownerOf(id) == address(0))   revert InvalidDNft(); _;
  }
  modifier isLicensed(address vault) {
    if (!vaultLicenser.isLicensed(vault)) revert NotLicensed(); _;
  }

  constructor(
    DNft          _dNft,
    Dyad          _dyad,
    Licenser      _licenser
  ) {
    dNft          = _dNft;
    dyad          = _dyad;
    vaultLicenser = _licenser;
  }

  function setKeroseneManager(KerosineManager _keroseneManager) 
    external
      initializer 
    {
      keroseneManager = _keroseneManager;
  }

  /// @inheritdoc IVaultManager
  function add(
      uint    id,
      address vault
  ) 
    external
      isDNftOwner(id)
  {
    if (vaults[id].length() >= MAX_VAULTS) revert TooManyVaults();
    if (!vaultLicenser.isLicensed(vault))  revert VaultNotLicensed();
    if (!vaults[id].add(vault))            revert VaultAlreadyAdded();
    emit Added(id, vault);
  }

  function addKerosene(
      uint    id,
      address vault
  ) 
    external
      isDNftOwner(id)
  {
    if (vaultsKerosene[id].length() >= MAX_VAULTS_KEROSENE) revert TooManyVaults();
    if (!keroseneManager.isLicensed(vault))                 revert VaultNotLicensed();
    if (!vaultsKerosene[id].add(vault))                     revert VaultAlreadyAdded();
    emit Added(id, vault);
  }

  /// @inheritdoc IVaultManager
  function remove(
      uint    id,
      address vault
  ) 
    external
      isDNftOwner(id)
  {
    if (Vault(vault).id2asset(id) > 0) revert VaultHasAssets();
    if (!vaults[id].remove(vault))     revert VaultNotAdded();
    emit Removed(id, vault);
  }

  function removeKerosene(
      uint    id,
      address vault
  ) 
    external
      isDNftOwner(id)
  {
    if (Vault(vault).id2asset(id) > 0)     revert VaultHasAssets();
    if (!vaultsKerosene[id].remove(vault)) revert VaultNotAdded();
    emit Removed(id, vault);
  }

  /// @inheritdoc IVaultManager
  function deposit(
    uint    id,
    address vault,
    uint    amount
  ) 
    external 
      isValidDNft(id)
  {
    idToBlockOfLastDeposit[id] = block.number;
    Vault _vault = Vault(vault);
    _vault.asset().safeTransferFrom(msg.sender, address(vault), amount);
    _vault.deposit(id, amount);
  }

  /// @inheritdoc IVaultManager
  function withdraw(
    uint    id,
    address vault,
    uint    amount,
    address to
  ) 
    public
      isDNftOwner(id)
  {
    if (idToBlockOfLastDeposit[id] == block.number) revert DepositedInSameBlock();
    uint dyadMinted = dyad.mintedDyad(address(this), id);
    Vault _vault = Vault(vault);
    uint value = amount * _vault.assetPrice() 
                  * 1e18 
                  / 10**_vault.oracle().decimals() 
                  / 10**_vault.asset().decimals();
    if (getNonKeroseneValue(id) - value < dyadMinted) revert NotEnoughExoCollat();
    _vault.withdraw(id, to, amount);
    if (collatRatio(id) < MIN_COLLATERIZATION_RATIO)  revert CrTooLow(); 
  }

  /// @inheritdoc IVaultManager
  function mintDyad(
    uint    id,
    uint    amount,
    address to
  )
    external 
      isDNftOwner(id)
  {
    uint newDyadMinted = dyad.mintedDyad(address(this), id) + amount;
    if (getNonKeroseneValue(id) < newDyadMinted)     revert NotEnoughExoCollat();
    dyad.mint(id, to, amount);
    if (collatRatio(id) < MIN_COLLATERIZATION_RATIO) revert CrTooLow(); 
    emit MintDyad(id, amount, to);
  }

  /// @inheritdoc IVaultManager
  function burnDyad(
    uint id,
    uint amount
  ) 
    external 
      isValidDNft(id)
  {
    dyad.burn(id, msg.sender, amount);
    emit BurnDyad(id, amount, msg.sender);
  }

  /// @inheritdoc IVaultManager
  function redeemDyad(
    uint    id,
    address vault,
    uint    amount,
    address to
  )
    external 
      isDNftOwner(id)
    returns (uint) { 
      dyad.burn(id, msg.sender, amount);
      Vault _vault = Vault(vault);
      uint asset = amount 
                    * (10**(_vault.oracle().decimals() + _vault.asset().decimals())) 
                    / _vault.assetPrice() 
                    / 1e18;
      withdraw(id, vault, asset, to);
      emit RedeemDyad(id, vault, amount, to);
      return asset;
  }

  /// @inheritdoc IVaultManager
  function liquidate(
    uint id,
    uint to
  ) 
    external 
      isValidDNft(id)
      isValidDNft(to)
    {
      uint cr = collatRatio(id);
      if (cr >= MIN_COLLATERIZATION_RATIO) revert CrTooHigh();
      dyad.burn(id, msg.sender, dyad.mintedDyad(address(this), id));

      uint cappedCr               = cr < 1e18 ? 1e18 : cr;
      uint liquidationEquityShare = (cappedCr - 1e18).mulWadDown(LIQUIDATION_REWARD);
      uint liquidationAssetShare  = (liquidationEquityShare + 1e18).divWadDown(cappedCr);

      uint numberOfVaults = vaults[id].length();
      for (uint i = 0; i < numberOfVaults; i++) {
          Vault vault      = Vault(vaults[id].at(i));
          uint  collateral = vault.id2asset(id).mulWadUp(liquidationAssetShare);
          vault.move(id, to, collateral);
      }
      emit Liquidate(id, msg.sender, to);
  }

  function collatRatio(
    uint id
  )
    public 
    view
    returns (uint) {
      uint _dyad = dyad.mintedDyad(address(this), id);
      if (_dyad == 0) return type(uint).max;
      return getTotalUsdValue(id).divWadDown(_dyad);
  }

  function getTotalUsdValue(
    uint id
  ) 
    public 
    view
    returns (uint) {
      return getNonKeroseneValue(id) + getKeroseneValue(id);
  }

  function getNonKeroseneValue(
    uint id
  ) 
    public 
    view
    returns (uint) {
      uint totalUsdValue;
      uint numberOfVaults = vaults[id].length(); 
      for (uint i = 0; i < numberOfVaults; i++) {
        Vault vault = Vault(vaults[id].at(i));
        uint usdValue;
        if (vaultLicenser.isLicensed(address(vault))) {
          usdValue = vault.getUsdValue(id);        
        }
        totalUsdValue += usdValue;
      }
      return totalUsdValue;
  }

  function getKeroseneValue(
    uint id
  ) 
    public 
    view
    returns (uint) {
      uint totalUsdValue;
      uint numberOfVaults = vaultsKerosene[id].length(); 
      for (uint i = 0; i < numberOfVaults; i++) {
        Vault vault = Vault(vaultsKerosene[id].at(i));
        uint usdValue;
        if (keroseneManager.isLicensed(address(vault))) {
          usdValue = vault.getUsdValue(id);        
        }
        totalUsdValue += usdValue;
      }
      return totalUsdValue;
  }

  // ----------------- MISC ----------------- //

  function getVaults(
    uint id
  ) 
    external 
    view 
    returns (address[] memory) {
      return vaults[id].values();
  }

  function hasVault(
    uint    id,
    address vault
  ) 
    external 
    view 
    returns (bool) {
      return vaults[id].contains(vault);
  }
}
