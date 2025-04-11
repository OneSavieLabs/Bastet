// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { StakehouseAPI } from "@blockswaplab/stakehouse-solidity-api/contracts/StakehouseAPI.sol";
import { ITransactionRouter } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/ITransactionRouter.sol";
import { IDataStructures } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IDataStructures.sol";
import { IStakeHouseRegistry } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IStakeHouseRegistry.sol";

import { SavETHVaultDeployer } from "./SavETHVaultDeployer.sol";
import { StakingFundsVaultDeployer } from "./StakingFundsVaultDeployer.sol";
import { StakingFundsVault } from "./StakingFundsVault.sol";
import { SavETHVault } from "./SavETHVault.sol";
import { LPToken } from "./LPToken.sol";
import { LPTokenFactory } from "./LPTokenFactory.sol";
import { SyndicateFactory } from "../syndicate/SyndicateFactory.sol";
import { Syndicate } from "../syndicate/Syndicate.sol";
import { OptionalHouseGatekeeper } from "./OptionalHouseGatekeeper.sol";
import { OptionalGatekeeperFactory } from "./OptionalGatekeeperFactory.sol";
import { OwnableSmartWalletFactory } from "../smart-wallet/OwnableSmartWalletFactory.sol";
import { IOwnableSmartWalletFactory } from "../smart-wallet/interfaces/IOwnableSmartWalletFactory.sol";
import { IOwnableSmartWallet } from "../smart-wallet/interfaces/IOwnableSmartWallet.sol";
import { ISyndicateFactory } from "../interfaces/ISyndicateFactory.sol";
import { ILiquidStakingManager } from "../interfaces/ILiquidStakingManager.sol";
import { IBrandNFT } from "../interfaces/IBrandNFT.sol";

contract LiquidStakingManager is ILiquidStakingManager, Initializable, ReentrancyGuard, StakehouseAPI {

    /// @notice signalize change in status of whitelisting
    event WhitelistingStatusChanged(address indexed dao, bool updatedStatus);

    /// @notice signalize updated whitelist status of node runner
    event NodeRunnerWhitelistingStatusChanged(address indexed nodeRunner, bool updatedStatus);

    /// @notice signalize creation of a new smart wallet
    event SmartWalletCreated(address indexed smartWallet, address indexed nodeRunner);

    /// @notice signalize appointing of a representative for a smart wallet by the node runner
    event RepresentativeAppointed(address indexed smartWallet, address indexed eoaRepresentative);

    /// @notice signalize wallet being credited with ETH
    event WalletCredited(address indexed smartWallet, uint256 amount);

    /// @notice signalize staking of a KNOT
    event KnotStaked(bytes _blsPublicKeyOfKnot, address indexed trigerringAddress);

    /// @notice signalize creation of stakehouse
    event StakehouseCreated(string stakehouseTicker, address indexed stakehouse);

    /// @notice signalize joining a stakehouse
    event StakehouseJoined(bytes blsPubKey);

    ///@notice signalize removal of representative from smart wallet
    event RepresentativeRemoved(address indexed smartWallet, address indexed eoaRepresentative);

    /// @notice signalize dormant representative
    event DormantRepresentative(address indexed associatedSmartWallet, address representative);

    /// @notice signalize refund of withdrawal of 4 ETH for a BLS public key by the node runner
    event ETHWithdrawnFromSmartWallet(address indexed associatedSmartWallet, bytes blsPublicKeyOfKnot, address nodeRunner);

    /// @notice signalize that the network has updated its ticker before its house was created
    event NetworkTickerUpdated(string newTicker);

    /// @notice signalize that the node runner has claimed rewards from the syndicate
    event NodeRunnerRewardsClaimed(address indexed nodeRunner, address indexed recipient);

    /// @notice signalize that the node runner of the smart wallet has been rotated
    event NodeRunnerOfSmartWalletRotated(address indexed wallet, address indexed oldRunner, address indexed newRunner);

    /// @notice signalize banning of a node runner
    event NodeRunnerBanned(address indexed nodeRunner);

    /// @notice signalize that the dao management address has been moved
    event UpdateDAOAddress(address indexed oldAddress, address indexed newAddress);

    /// @notice signalize that the dao commission from network revenue has been updated
    event DAOCommissionUpdated(uint256 old, uint256 newCommission);

    /// @notice signalize that a new BLS public key for an LSD validator has been registered
    event NewLSDValidatorRegistered(address indexed nodeRunner, bytes blsPublicKey);

    /// @notice Address of brand NFT
    address public brand;

    /// @notice stakehouse created by the LSD network
    address public override stakehouse;

    /// @notice Fees and MEV EIP1559 distribution contract for the LSD network
    address public syndicate;

    /// @notice address of the DAO deploying the contract
    address public dao;

    /// @notice address of optional gatekeeper for admiting new knots to the house created by the network
    OptionalHouseGatekeeper public gatekeeper;

    /// @notice instance of the syndicate factory that deploys the syndicates
    ISyndicateFactory public syndicateFactory;

    /// @notice instance of the smart wallet factory that deploys the smart wallets for node runners
    IOwnableSmartWalletFactory public smartWalletFactory;

    /// @notice string name for the stakehouse 3-5 characters long
    string public stakehouseTicker;

    /// @notice DAO staking funds vault
    StakingFundsVault public stakingFundsVault;

    /// @notice SavETH vault
    SavETHVault public savETHVault;

    /// @notice whitelisting indicator. true for enables and false for disabled
    bool public enableWhitelisting;

    /// @notice mapping to store if a node runner is whitelisted
    mapping(address => bool) public isNodeRunnerWhitelisted;

    /// @notice EOA representative appointed for a smart wallet
    mapping(address => address) public smartWalletRepresentative;

    /// @notice Smart wallet used to deploy KNOT
    mapping(bytes => address) public smartWalletOfKnot;

    /// @notice Smart wallet issued to the Node runner. Node runner address <> Smart wallet address
    mapping(address => address) public smartWalletOfNodeRunner;

    /// @notice Node runner issued to Smart wallet. Smart wallet address <> Node runner address
    mapping(address => address) public nodeRunnerOfSmartWallet;

    /// @notice Track number of staked KNOTs of a smart wallet
    mapping(address => uint256) public stakedKnotsOfSmartWallet;

    /// @notice smart wallet <> dormant rep.
    mapping(address => address) public smartWalletDormantRepresentative;

    /// @notice Track BLS public keys that have been banned. 
    /// If banned, the BLS public key will be mapped to its respective smart wallet
    mapping(bytes => address) public bannedBLSPublicKeys;

    /// @notice Track node runner addresses that are banned.
    /// Malicious node runners can be banned by the DAO
    mapping(address => bool) public bannedNodeRunners;

    /// @notice count of KNOTs interacted with LSD network
    uint256 public numberOfKnots;

    /// @notice Commission percentage to 5 decimal places
    uint256 public daoCommissionPercentage;

    /// @notice 100% to 5 decimal places
    uint256 public MODULO = 100_00000;

    modifier onlyDAO() {
        require(msg.sender == dao, "Must be DAO");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @inheritdoc ILiquidStakingManager
    function init(
        address _dao,
        address _syndicateFactory,
        address _smartWalletFactory,
        address _lpTokenFactory,
        address _brand,
        address _savETHVaultDeployer,
        address _stakingFundsVaultDeployer,
        address _optionalGatekeeperDeployer,
        uint256 _optionalCommission,
        bool _deployOptionalGatekeeper,
        string calldata _stakehouseTicker
    ) external virtual override initializer {
        _init(
            _dao,
            _syndicateFactory,
            _smartWalletFactory,
            _lpTokenFactory,
            _brand,
            _savETHVaultDeployer,
            _stakingFundsVaultDeployer,
            _optionalGatekeeperDeployer,
            _optionalCommission,
            _deployOptionalGatekeeper,
            _stakehouseTicker
        );
    }

    /// @notice Enable operations proxied through DAO contract to another contract
    /// @param _nodeRunner Address of the node runner that created the wallet
    /// @param _to Address of the target contract
    /// @param _data Encoded data of the function call
    /// @param _value Total value attached to the transaction
    function executeAsSmartWallet(
        address _nodeRunner,
        address _to,
        bytes calldata _data,
        uint256 _value
    ) external payable onlyDAO {
        address smartWallet = smartWalletOfNodeRunner[_nodeRunner];
        require(smartWallet != address(0), "No wallet found");
        IOwnableSmartWallet(smartWallet).execute(
            _to,
            _data,
            _value
        );
    }

    /// @notice For knots no longer operational, DAO can de register the knot from the syndicate
    function deRegisterKnotFromSyndicate(bytes[] calldata _blsPublicKeys) external onlyDAO {
        Syndicate(payable(syndicate)).deRegisterKnots(_blsPublicKeys);
    }

    /// @notice In preparation of a rage quit, restore sETH to a smart wallet which are recoverable with the execution methods in the event this step does not go to plan
    /// @param _smartWallet Address of the smart wallet that will undertake the rage quit
    /// @param _blsPublicKeys List of BLS public keys being processed (assuming DAO only has BLS pub keys from correct smart wallet)
    /// @param _amounts Amounts of free floating sETH that will be unstaked
    function restoreFreeFloatingSharesToSmartWalletForRageQuit(
        address _smartWallet,
        bytes[] calldata _blsPublicKeys,
        uint256[] calldata _amounts
    ) external onlyDAO {
        stakingFundsVault.unstakeSyndicateSharesForRageQuit(
            _smartWallet,
            _blsPublicKeys,
            _amounts
        );
    }

    /// @notice Allow DAO to migrate to a new address
    function updateDAOAddress(address _newAddress) external onlyDAO {
        require(_newAddress != address(0), "Zero address");
        require(_newAddress != dao, "Same address");

        emit UpdateDAOAddress(dao, _newAddress);

        dao = _newAddress;
    }

    /// @notice Allow DAO to take a commission of network revenue
    function updateDAORevenueCommission(uint256 _commissionPercentage) external onlyDAO {
        require(_commissionPercentage != daoCommissionPercentage, "Same commission percentage");
        _updateDAORevenueCommission(_commissionPercentage);
    }

    /// @notice Allow the DAO to rotate the network ticker before the network house is created
    function updateTicker(string calldata _newTicker) external onlyDAO {
        require(bytes(_newTicker).length >= 3, "String must be 3-5 characters long");
        require(bytes(_newTicker).length <= 5, "String must be 3-5 characters long");
        require(numberOfKnots == 0, "Cannot change ticker once house is created");

        stakehouseTicker = _newTicker;

        emit NetworkTickerUpdated(_newTicker);
    }

    /// @notice function to change whether node runner whitelisting of node runners is required by the DAO
    /// @param _changeWhitelist boolean value. true to enable and false to disable
    function updateWhitelisting(bool _changeWhitelist) external onlyDAO returns (bool) {
        require(_changeWhitelist != enableWhitelisting, "Unnecessary update to same status");
        enableWhitelisting = _changeWhitelist;
        emit WhitelistingStatusChanged(msg.sender, enableWhitelisting);

        return enableWhitelisting;
    }

    /// @notice function to enable/disable whitelisting of a noderunner
    /// @param _nodeRunner address of the node runner
    /// @param isWhitelisted true if the node runner should be whitelisted. false otherwise.
    function updateNodeRunnerWhitelistStatus(address _nodeRunner, bool isWhitelisted) external onlyDAO {
        require(_nodeRunner != address(0), "Zero address");
        require(isNodeRunnerWhitelisted[_nodeRunner] != isNodeRunnerWhitelisted[_nodeRunner], "Unnecessary update to same status");

        isNodeRunnerWhitelisted[_nodeRunner] = isWhitelisted;
        emit NodeRunnerWhitelistingStatusChanged(_nodeRunner, isWhitelisted);
    }

    /// @notice Allow a node runner to rotate the EOA representative they use for their smart wallet
    /// @dev if any KNOT is staked for a smart wallet, no rep can be appointed or updated until the derivatives are minted
    /// @param _newRepresentative address of the new representative to be appointed
    function rotateEOARepresentative(address _newRepresentative) external {
        require(_newRepresentative != address(0), "Zero address");
        require(isNodeRunnerBanned(msg.sender) == false, "Node runner is banned from LSD network");

        address smartWallet = smartWalletOfNodeRunner[msg.sender];
        require(smartWallet != address(0), "No smart wallet");
        require(stakedKnotsOfSmartWallet[smartWallet] == 0, "Not all KNOTs are minted");
        require(smartWalletRepresentative[smartWallet] != _newRepresentative, "Invalid rotation to same EOA");

        // unauthorize old representative
        _authorizeRepresentative(smartWallet, smartWalletRepresentative[smartWallet], false);

        // authorize new representative
        _authorizeRepresentative(smartWallet, _newRepresentative, true);
    }

    /// @notice Allow DAO to rotate representative in the case that node runner is not available (to facilitate staking)
    /// @param _nodeRunner address of the node runner
    /// @param _newRepresentative address of the new representative to be appointed for the node runner
    function rotateEOARepresentativeOfNodeRunner(address _nodeRunner, address _newRepresentative) external onlyDAO {
        require(_newRepresentative != address(0), "Zero address");

        address smartWallet = smartWalletOfNodeRunner[_nodeRunner];
        require(smartWallet != address(0), "No smart wallet");
        require(stakedKnotsOfSmartWallet[smartWallet] == 0, "Not all KNOTs are minted");
        require(smartWalletRepresentative[smartWallet] != _newRepresentative, "Invalid rotation to same EOA");

        // unauthorize old representative
        _authorizeRepresentative(smartWallet, smartWalletRepresentative[smartWallet], false);

        // authorize new representative
        _authorizeRepresentative(smartWallet, _newRepresentative, true);
    }

    /// @notice Allow node runners to withdraw ETH from their smart wallet. ETH can only be withdrawn until the KNOT has not been staked.
    /// @dev A banned node runner cannot withdraw ETH for the KNOT. 
    /// @param _blsPublicKeyOfKnot BLS public key of the KNOT for which the ETH needs to be withdrawn
    function withdrawETHForKnot(address _recipient, bytes calldata _blsPublicKeyOfKnot) external {
        require(_recipient != address(0), "Zero address");
        require(isBLSPublicKeyBanned(_blsPublicKeyOfKnot) == false, "BLS public key has already withdrawn or not a part of LSD network");

        address associatedSmartWallet = smartWalletOfKnot[_blsPublicKeyOfKnot];
        require(smartWalletOfNodeRunner[msg.sender] == associatedSmartWallet, "Not the node runner for the smart wallet ");
        require(isNodeRunnerBanned(nodeRunnerOfSmartWallet[associatedSmartWallet]) == false, "Node runner is banned from LSD network");
        require(associatedSmartWallet.balance >= 4 ether, "Insufficient balance");
        require(
            getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKeyOfKnot) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
            "Initials not registered"
        );

        // refund 4 ether from smart wallet to node runner's EOA
        IOwnableSmartWallet(associatedSmartWallet).rawExecute(
            _recipient,
            "",
            4 ether
        );

        // update the mapping
        bannedBLSPublicKeys[_blsPublicKeyOfKnot] = associatedSmartWallet;

        emit ETHWithdrawnFromSmartWallet(associatedSmartWallet, _blsPublicKeyOfKnot, msg.sender);
    }

    /// @notice In the event the node runner coordinates with the DAO to sell their wallet, allow rotation
    /// @dev EOA representative rotation done outside this method because there may be knots currently staked etc.
    /// @param _current address of the present node runner of the smart wallet
    /// @param _new address of the new node runner of the smart wallet
    function rotateNodeRunnerOfSmartWallet(address _current, address _new, bool _wasPreviousNodeRunnerMalicious) external {
        require(_new != address(0) && _current != _new, "New is zero or current");

        address wallet = smartWalletOfNodeRunner[_current];
        require(wallet != address(0), "Wallet does not exist");
        require(_current == msg.sender || dao == msg.sender, "Not current owner or DAO");

        address newRunnerCurrentWallet = smartWalletOfNodeRunner[_new];
        require(newRunnerCurrentWallet == address(0), "New runner has a wallet");

        smartWalletOfNodeRunner[_new] = wallet;
        nodeRunnerOfSmartWallet[wallet] = _new;

        delete smartWalletOfNodeRunner[_current];

        if (msg.sender == dao && _wasPreviousNodeRunnerMalicious) {
            bannedNodeRunners[_current] = true;
            emit NodeRunnerBanned(_current);
        }

        emit NodeRunnerOfSmartWalletRotated(wallet, _current, _new);
    }

    /// @notice function to allow a node runner to claim ETH from the syndicate from their smart wallet
    /// @param _recipient End recipient of ETH from syndicate rewards
    /// @param _blsPubKeys list of BLS public keys to claim reward for
    function claimRewardsAsNodeRunner(
        address _recipient,
        bytes[] calldata _blsPubKeys
    ) external nonReentrant {
        require(_blsPubKeys.length > 0, "No BLS keys specified");
        require(_recipient != address(0), "Zero address");

        address smartWallet = smartWalletOfNodeRunner[msg.sender];
        require(smartWallet != address(0), "Unknown node runner");

        for(uint256 i; i < _blsPubKeys.length; ++i) {
            require(isBLSPublicKeyBanned(_blsPubKeys[i]) == false, "BLS public key is banned or not a part of LSD network");

            // check that the node runner doesn't claim rewards for KNOTs from other smart wallets
            require(smartWalletOfKnot[_blsPubKeys[i]] == smartWallet, "BLS public key doesn't belong to the node runner");
        }

        // Fetch ETH accrued
        uint256 balBefore = address(this).balance;
        IOwnableSmartWallet(smartWallet).execute(
            syndicate,
            abi.encodeWithSelector(
                Syndicate.claimAsCollateralizedSLOTOwner.selector,
                address(this),
                _blsPubKeys
            )
        );

        (uint256 nodeRunnerAmount, uint256 daoAmount) = _calculateCommission(address(this).balance - balBefore);
        (bool transferResult, ) = _recipient.call{value: nodeRunnerAmount}("");
        require(transferResult, "Failed to transfer");

        if (daoAmount > 0) {
            (transferResult, ) = dao.call{value: daoAmount}("");
            require(transferResult, "Failed to transfer");
        }

        emit NodeRunnerRewardsClaimed(msg.sender, _recipient);
    }

    /// @notice register a node runner to LSD by creating a new smart wallet
    /// @param _blsPublicKeys list of BLS public keys
    /// @param _blsSignatures list of BLS signatures
    /// @param _eoaRepresentative EOA representative of wallet
    function registerBLSPublicKeys(
        bytes[] calldata _blsPublicKeys,
        bytes[] calldata _blsSignatures,
        address _eoaRepresentative
    ) external payable nonReentrant {
        uint256 len = _blsPublicKeys.length;
        require(len >= 1, "No value provided");
        require(len == _blsSignatures.length, "Unequal number of array values");
        require(msg.value == len * 4 ether, "Insufficient ether provided");
        require(!Address.isContract(_eoaRepresentative), "Only EOA representative permitted");
        require(_isNodeRunnerValid(msg.sender) == true, "Unrecognised node runner");
        require(isNodeRunnerBanned(msg.sender) == false, "Node runner is banned from LSD network");

        address smartWallet = smartWalletOfNodeRunner[msg.sender];

        if(smartWallet == address(0)) {
            // create new wallet owned by liquid staking manager
            smartWallet = smartWalletFactory.createWallet(address(this));
            emit SmartWalletCreated(smartWallet, msg.sender);

            // associate node runner with the newly created wallet
            smartWalletOfNodeRunner[msg.sender] = smartWallet;
            nodeRunnerOfSmartWallet[smartWallet] = msg.sender;

            _authorizeRepresentative(smartWallet, _eoaRepresentative, true);
        }

        // Ensure that the node runner does not whitelist multiple EOA representatives - they can only have 1 active at a time
        if(smartWalletRepresentative[smartWallet] != address(0)) {
            require(smartWalletRepresentative[smartWallet] == _eoaRepresentative, "Different EOA specified - rotate outside");
        }

        {
            // transfer ETH to smart wallet
            (bool result,) = smartWallet.call{value: msg.value}("");
            require(result, "Transfer failed");
            emit WalletCredited(smartWallet, msg.value);
        }

        for(uint256 i; i < len; ++i) {
            bytes calldata _blsPublicKey = _blsPublicKeys[i];

            // check if the BLS public key is part of LSD network and is not banned
            require(isBLSPublicKeyPartOfLSDNetwork(_blsPublicKey) == false, "BLS public key is banned or not a part of LSD network");

            require(
                getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKey) == IDataStructures.LifecycleStatus.UNBEGUN,
                "Lifecycle status must be zero"
            );

            // register validtor initals for each of the KNOTs
            IOwnableSmartWallet(smartWallet).execute(
                address(getTransactionRouter()),
                abi.encodeWithSelector(
                    ITransactionRouter.registerValidatorInitials.selector,
                    smartWallet,
                    _blsPublicKey,
                    _blsSignatures[i]
                )
            );

            // register the smart wallet with the BLS public key
            smartWalletOfKnot[_blsPublicKey] = smartWallet;

            emit NewLSDValidatorRegistered(msg.sender, _blsPublicKey);
        }
    }

    /// @inheritdoc ILiquidStakingManager
    function isBLSPublicKeyPartOfLSDNetwork(bytes calldata _blsPublicKeyOfKnot) public virtual view returns (bool) {
        return smartWalletOfKnot[_blsPublicKeyOfKnot] != address(0);
    }

    /// @inheritdoc ILiquidStakingManager
    function isBLSPublicKeyBanned(bytes calldata _blsPublicKeyOfKnot) public virtual view returns (bool) {
        return !isBLSPublicKeyPartOfLSDNetwork(_blsPublicKeyOfKnot) || bannedBLSPublicKeys[_blsPublicKeyOfKnot] != address(0);
    }

    /// @notice function to check if a node runner address is banned
    /// @param _nodeRunner address of the node runner
    /// @return true if the node runner is banned, false otherwise
    function isNodeRunnerBanned(address _nodeRunner) public view returns (bool) {
        return bannedNodeRunners[_nodeRunner];
    }

    /// @notice function to check if a KNOT is deregistered
    /// @param _blsPublicKey BLS public key of the KNOT
    /// @return true if the KNOT is deregistered, false otherwise
    function isKnotDeregistered(bytes calldata _blsPublicKey) public view returns (bool) {
        return Syndicate(payable(syndicate)).isNoLongerPartOfSyndicate(_blsPublicKey);
    }

    /// @notice Anyone can call this to trigger staking once they have all of the required input params from BLS authentication
    /// @param _blsPublicKeyOfKnots List of knots being staked with the Ethereum deposit contract (32 ETH sourced within the network)
    /// @param _ciphertexts List of backed up validator operations encrypted and stored to the Ethereum blockchain
    /// @param _aesEncryptorKeys List of public identifiers of credentials that performed the trustless backup
    /// @param _encryptionSignatures List of EIP712 signatures attesting to the correctness of the BLS signature
    /// @param _dataRoots List of serialized SSZ containers of the DepositData message for each validator used by Ethereum deposit contract
    function stake(
        bytes[] calldata _blsPublicKeyOfKnots,
        bytes[] calldata _ciphertexts,
        bytes[] calldata _aesEncryptorKeys,
        IDataStructures.EIP712Signature[] calldata _encryptionSignatures,
        bytes32[] calldata _dataRoots
    ) external {
        uint256 numOfValidators = _blsPublicKeyOfKnots.length;
        require(numOfValidators > 0, "No data");
        require(numOfValidators == _ciphertexts.length, "Inconsistent array lengths");
        require(numOfValidators == _aesEncryptorKeys.length, "Inconsistent array lengths");
        require(numOfValidators == _encryptionSignatures.length, "Inconsistent array lengths");
        require(numOfValidators == _dataRoots.length, "Inconsistent array lengths");

        for (uint256 i; i < numOfValidators; ++i) {
            bytes calldata blsPubKey = _blsPublicKeyOfKnots[i];
            // check if BLS public key is registered with liquid staking derivative network and not banned
            require(isBLSPublicKeyBanned(blsPubKey) == false, "BLS public key is banned or not a part of LSD network");

            address associatedSmartWallet = smartWalletOfKnot[blsPubKey];
            require(associatedSmartWallet != address(0), "Unknown BLS public key");
            require(
                getAccountManager().blsPublicKeyToLifecycleStatus(blsPubKey) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
                "Initials not registered"
            );

            // check minimum balance of smart wallet, dao staking fund vault and savETH vault
            _assertEtherIsReadyForValidatorStaking(blsPubKey);

            _stake(
                _blsPublicKeyOfKnots[i],
                _ciphertexts[i],
                _aesEncryptorKeys[i],
                _encryptionSignatures[i],
                _dataRoots[i]
            );

            address representative = smartWalletRepresentative[associatedSmartWallet];

            if(representative != address(0)) {
                // unauthorize the EOA representative on the Stakehouse
                _authorizeRepresentative(associatedSmartWallet, representative, false);
                // make the representative dormant before unauthorizing it
                smartWalletDormantRepresentative[associatedSmartWallet] = representative;
                emit DormantRepresentative(associatedSmartWallet, representative);
            }
        }
    }

    /// @notice Anyone can call this to trigger creating a knot which will mint derivatives once the balance has been reported
    /// @param _blsPublicKeyOfKnots List of BLS public keys registered with the network becoming knots and minting derivatives
    /// @param _beaconChainBalanceReports List of beacon chain balance reports
    /// @param _reportSignatures List of attestations for the beacon chain balance reports
    function mintDerivatives(
        bytes[] calldata _blsPublicKeyOfKnots,
        IDataStructures.ETH2DataReport[] calldata _beaconChainBalanceReports,
        IDataStructures.EIP712Signature[] calldata _reportSignatures
    ) external {
        uint256 numOfKnotsToProcess = _blsPublicKeyOfKnots.length;
        require(numOfKnotsToProcess > 0, "Empty array");
        require(numOfKnotsToProcess == _beaconChainBalanceReports.length, "Inconsistent array lengths");
        require(numOfKnotsToProcess == _reportSignatures.length, "Inconsistent array lengths");

        for (uint256 i; i < numOfKnotsToProcess; ++i) {
            // check if BLS public key is registered and not banned
            require(isBLSPublicKeyBanned(_blsPublicKeyOfKnots[i]) == false, "BLS public key is banned or not a part of LSD network");

            // check that the BLS pub key has deposited lifecycle
            require(
                getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKeyOfKnots[i]) == IDataStructures.LifecycleStatus.DEPOSIT_COMPLETED,
                "Lifecycle status must be two"
            );

            // The first knot will create the Stakehouse
            if(numberOfKnots == 0) {
                _createLSDNStakehouse(
                    _blsPublicKeyOfKnots[i],
                    _beaconChainBalanceReports[i],
                    _reportSignatures[i]
                );
            }
            else {
                // join stakehouse
                _joinLSDNStakehouse(
                    _blsPublicKeyOfKnots[i],
                    _beaconChainBalanceReports[i],
                    _reportSignatures[i]
                );
            }

            address smartWallet = smartWalletOfKnot[_blsPublicKeyOfKnots[i]];
            stakedKnotsOfSmartWallet[smartWallet] -= 1;

            if(stakedKnotsOfSmartWallet[smartWallet] == 0) {
                _authorizeRepresentative(smartWallet, smartWalletDormantRepresentative[smartWallet], true);

                // delete the dormant representative as it is set active
                delete smartWalletDormantRepresentative[smartWallet];
            }

            // Expand the staking funds vault shares that can claim rewards
            stakingFundsVault.updateDerivativesMinted();
        }
    }

    receive() external payable {}

    /// @notice Every liquid staking derivative network has a single fee recipient determined by its syndicate contract
    /// @dev The syndicate contract is only deployed after the first KNOT to mint derivatives creates the network Stakehouse
    /// @dev Because the syndicate contract for the LSDN is deployed with CREATE2, we can predict the fee recipient ahead of time
    /// @dev This is important because node runners need to configure their nodes before or immediately after staking
    function getNetworkFeeRecipient() external view returns (address) {
        // Always 1 knot initially registered to the syndicate because we expand it one by one
        return syndicateFactory.calculateSyndicateDeploymentAddress(
            address(this),
            address(this),
            1
        );
    }

    /// @dev Internal method for managing the initialization of the staking manager contract
    function _init(
        address _dao,
        address _syndicateFactory,
        address _smartWalletFactory,
        address _lpTokenFactory,
        address _brand,
        address _savETHVaultDeployer,
        address _stakingFundsVaultDeployer,
        address _optionalGatekeeperDeployer,
        uint256 _optionalCommission,
        bool _deployOptionalGatekeeper,
        string calldata _stakehouseTicker
    ) internal {
        require(_dao != address(0), "Zero address");
        require(_syndicateFactory != address(0), "Zero address");
        require(_smartWalletFactory != address(0), "Zero address");
        require(_brand != address(0), "Zero address");
        require(bytes(_stakehouseTicker).length >= 3, "String must be 3-5 characters long");
        require(bytes(_stakehouseTicker).length <= 5, "String must be 3-5 characters long");

        brand = _brand;
        dao = _dao;
        syndicateFactory = ISyndicateFactory(_syndicateFactory);
        smartWalletFactory = IOwnableSmartWalletFactory(_smartWalletFactory);
        stakehouseTicker = _stakehouseTicker;

        _updateDAORevenueCommission(_optionalCommission);

        _initStakingFundsVault(_stakingFundsVaultDeployer, _lpTokenFactory);
        _initSavETHVault(_savETHVaultDeployer, _lpTokenFactory);

        if (_deployOptionalGatekeeper) {
            gatekeeper = OptionalGatekeeperFactory(_optionalGatekeeperDeployer).deploy(address(this));
        }
    }

    /// @dev function checks if a node runner is valid depending upon whitelisting status
    /// @param _nodeRunner address of the user requesting to become node runner
    /// @return true if eligible. reverts with message if not eligible
    function _isNodeRunnerValid(address _nodeRunner) internal view returns (bool) {
        require(_nodeRunner != address(0), "Zero address");

        if(enableWhitelisting) {
            require(isNodeRunnerWhitelisted[_nodeRunner] == true, "Invalid node runner");
        }

        return true;
    }

    /// @dev Manage the removal and appointing of smart wallet representatives including managing state
    function _authorizeRepresentative(
        address _smartWallet, 
        address _eoaRepresentative, 
        bool _isEnabled
    ) internal {
        if(!_isEnabled && smartWalletRepresentative[_smartWallet] != address(0)) {

            // authorize the EOA representative on the Stakehouse
            IOwnableSmartWallet(_smartWallet).execute(
                address(getTransactionRouter()),
                abi.encodeWithSelector(
                    ITransactionRouter.authorizeRepresentative.selector,
                    _eoaRepresentative,
                    _isEnabled
                )
            );

            // delete the mapping
            delete smartWalletRepresentative[_smartWallet];

            emit RepresentativeRemoved(_smartWallet, _eoaRepresentative);
        }
        else if(_isEnabled && smartWalletRepresentative[_smartWallet] == address(0)) {

            // authorize the EOA representative on the Stakehouse
            IOwnableSmartWallet(_smartWallet).execute(
                address(getTransactionRouter()),
                abi.encodeWithSelector(
                    ITransactionRouter.authorizeRepresentative.selector,
                    _eoaRepresentative,
                    _isEnabled
                )
            );

            // store EOA to the wallet mapping
            smartWalletRepresentative[_smartWallet] = _eoaRepresentative;

            emit RepresentativeAppointed(_smartWallet, _eoaRepresentative);
        } else {
            revert("Unexpected state");
        }
    }

    /// @dev Internal method for doing just staking - pre-checks done outside this method to avoid stack too deep
    function _stake(
        bytes calldata _blsPublicKey,
        bytes calldata _cipherText,
        bytes calldata _aesEncryptorKey,
        IDataStructures.EIP712Signature calldata _encryptionSignature,
        bytes32 dataRoot
    ) internal {
        address smartWallet = smartWalletOfKnot[_blsPublicKey];

        // send 24 ether from savETH vault to smart wallet
        savETHVault.withdrawETHForStaking(smartWallet, 24 ether);

        // send 4 ether from DAO staking funds vault
        stakingFundsVault.withdrawETH(smartWallet, 4 ether);

        // interact with transaction router using smart wallet to deposit 32 ETH
        IOwnableSmartWallet(smartWallet).execute(
            address(getTransactionRouter()),
            abi.encodeWithSelector(
                ITransactionRouter.registerValidator.selector,
                smartWallet,
                _blsPublicKey,
                _cipherText,
                _aesEncryptorKey,
                _encryptionSignature,
                dataRoot
            ),
            32 ether
        );

        // increment number of staked KNOTs in the wallet
        stakedKnotsOfSmartWallet[smartWallet] += 1;

        emit KnotStaked(_blsPublicKey, msg.sender);
    }

    /// @dev The second knot onwards will join the LSDN stakehouse and expand the registered syndicate knots
    function _joinLSDNStakehouse(
        bytes calldata _blsPubKey,
        IDataStructures.ETH2DataReport calldata _beaconChainBalanceReport,
        IDataStructures.EIP712Signature calldata _reportSignature
    ) internal {
        // total number of knots created with the syndicate increases
        numberOfKnots += 1;

        // The savETH will go to the savETH vault, the collateralized SLOT for syndication owned by the smart wallet
        // sETH will also be minted in the smart wallet but will be moved out and distributed to the syndicate for claiming by the DAO
        address associatedSmartWallet = smartWalletOfKnot[_blsPubKey];

        // Join the LSDN stakehouse
        string memory lowerTicker = IBrandNFT(brand).toLowerCase(stakehouseTicker);
        IOwnableSmartWallet(associatedSmartWallet).execute(
            address(getTransactionRouter()),
            abi.encodeWithSelector(
                ITransactionRouter.joinStakehouse.selector,
                associatedSmartWallet,
                _blsPubKey,
                stakehouse,
                IBrandNFT(brand).lowercaseBrandTickerToTokenId(lowerTicker),
                savETHVault.indexOwnedByTheVault(),
                _beaconChainBalanceReport,
                _reportSignature
            )
        );

        // Register the knot to the syndicate
        bytes[] memory _blsPublicKeyOfKnots = new bytes[](1);
        _blsPublicKeyOfKnots[0] = _blsPubKey;
        Syndicate(payable(syndicate)).registerKnotsToSyndicate(_blsPublicKeyOfKnots);

        // Autostake DAO sETH with the syndicate
        _autoStakeWithSyndicate(associatedSmartWallet, _blsPubKey);

        emit StakehouseJoined(_blsPubKey);
    }

    /// @dev Perform all the steps required to create the LSDN stakehouse that other knots will join
    function _createLSDNStakehouse(
        bytes calldata _blsPublicKeyOfKnot,
        IDataStructures.ETH2DataReport calldata _beaconChainBalanceReport,
        IDataStructures.EIP712Signature calldata _reportSignature
    ) internal {
        // create stakehouse and mint derivative for first bls key - the others are just used to create the syndicate
        // The savETH will go to the savETH vault, the collateralized SLOT for syndication owned by the smart wallet
        // sETH will also be minted in the smart wallet but will be moved out and distributed to the syndicate for claiming by the DAO
        address associatedSmartWallet = smartWalletOfKnot[_blsPublicKeyOfKnot];
        IOwnableSmartWallet(associatedSmartWallet).execute(
            address(getTransactionRouter()),
            abi.encodeWithSelector(
                ITransactionRouter.createStakehouse.selector,
                associatedSmartWallet,
                _blsPublicKeyOfKnot,
                stakehouseTicker,
                savETHVault.indexOwnedByTheVault(),
                _beaconChainBalanceReport,
                _reportSignature
            )
        );

        // Number of knots has increased
        numberOfKnots += 1;

        // Capture the address of the Stakehouse for future knots to join
        stakehouse = getStakeHouseUniverse().memberKnotToStakeHouse(_blsPublicKeyOfKnot);
        IERC20 sETH = IERC20(getSlotRegistry().stakeHouseShareTokens(stakehouse));

        // Give liquid staking manager ability to manage keepers and set a house keeper if decided by the network
        IOwnableSmartWallet(associatedSmartWallet).execute(
            stakehouse,
            abi.encodeWithSelector(
                Ownable.transferOwnership.selector,
                address(this)
            )
        );

        if (address(gatekeeper) != address(0)) {
            IStakeHouseRegistry(stakehouse).setGateKeeper(address(gatekeeper));
        }

        // Deploy the EIP1559 transaction reward sharing contract but no priority required because sETH will be auto staked
        address[] memory priorityStakers = new address[](0);
        bytes[] memory initialKnots = new bytes[](1);
        initialKnots[0] = _blsPublicKeyOfKnot;
        syndicate = syndicateFactory.deploySyndicate(
            address(this),
            0,
            priorityStakers,
            initialKnots
        );

        // Contract approves syndicate to take sETH on behalf of the DAO
        sETH.approve(syndicate, (2 ** 256) - 1);

        // Auto-stake sETH by pulling sETH out the smart wallet and staking in the syndicate
        _autoStakeWithSyndicate(associatedSmartWallet, _blsPublicKeyOfKnot);

        emit StakehouseCreated(stakehouseTicker, stakehouse);
    }

    /// @dev Remove the sETH from the node runner smart wallet in order to auto-stake the sETH in the syndicate
    function _autoStakeWithSyndicate(address _associatedSmartWallet, bytes memory _blsPubKey) internal {
        IERC20 sETH = IERC20(getSlotRegistry().stakeHouseShareTokens(stakehouse));

        uint256 stakeAmount = 12 ether;
        IOwnableSmartWallet(_associatedSmartWallet).execute(
            address(sETH),
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                address(this),
                stakeAmount
            )
        );

        // Create the payload for staking
        bytes[] memory stakingKeys = new bytes[](1);
        stakingKeys[0] = _blsPubKey;

        uint256[] memory stakeAmounts = new uint256[](1);
        stakeAmounts[0] = stakeAmount;

        // Stake the sETH to be received by the LPs of the Staking Funds Vault (fees and mev)
        Syndicate(payable(syndicate)).stake(stakingKeys, stakeAmounts, address(stakingFundsVault));
    }

    /// @dev Something that can be overriden during testing
    function _initSavETHVault(address _savETHVaultDeployer, address _lpTokenFactory) internal virtual {
        // Use an external deployer to reduce the size of the liquid staking manager
        savETHVault = SavETHVault(
            SavETHVaultDeployer(_savETHVaultDeployer).deploySavETHVault(address(this), _lpTokenFactory)
        );
    }

    function _initStakingFundsVault(address _stakingFundsVaultDeployer, address _tokenFactory) internal virtual {
        stakingFundsVault = StakingFundsVault(
            payable(StakingFundsVaultDeployer(_stakingFundsVaultDeployer).deployStakingFundsVault(
                address(this),
                _tokenFactory
            ))
        );
    }

    /// @dev This can be overriden to customise fee percentages
    function _calculateCommission(uint256 _received) internal virtual view returns (uint256 _nodeRunner, uint256 _dao) {
        require(_received > 0, "Nothing received");

        if (daoCommissionPercentage > 0) {
            uint256 daoAmount = (_received * daoCommissionPercentage) / MODULO;
            uint256 rest = _received - daoAmount;
            return (rest, daoAmount);
        }

        return (_received, 0);
    }

    /// @dev Check the savETH vault, staking funds vault and node runner smart wallet to ensure 32 ether required for staking has been achieved
    function _assertEtherIsReadyForValidatorStaking(bytes calldata blsPubKey) internal view {
        address associatedSmartWallet = smartWalletOfKnot[blsPubKey];
        require(associatedSmartWallet.balance >= 4 ether, "Smart wallet balance must be at least 4 ether");

        LPToken stakingFundsLP = stakingFundsVault.lpTokenForKnot(blsPubKey);
        require(address(stakingFundsLP) != address(0), "No funds staked in staking funds vault");
        require(stakingFundsLP.totalSupply() == 4 ether, "DAO staking funds vault balance must be at least 4 ether");

        LPToken savETHVaultLP = savETHVault.lpTokenForKnot(blsPubKey);
        require(address(savETHVaultLP) != address(0), "No funds staked in savETH vault");
        require(savETHVaultLP.totalSupply() == 24 ether, "KNOT must have 24 ETH in savETH vault");
    }

    /// @dev Internal method for dao to trigger updating commission it takes of node runner revenue
    function _updateDAORevenueCommission(uint256 _commissionPercentage) internal {
        require(_commissionPercentage <= MODULO, "Invalid commission");

        emit DAOCommissionUpdated(daoCommissionPercentage, _commissionPercentage);

        daoCommissionPercentage = _commissionPercentage;
    }
}
