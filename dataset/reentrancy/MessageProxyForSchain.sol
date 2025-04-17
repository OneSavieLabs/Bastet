// SPDX-License-Identifier: AGPL-3.0-only

/**
 *   MessageProxyForSchain.sol - SKALE Interchain Messaging Agent
 *   Copyright (C) 2019-Present SKALE Labs
 *   @author Artem Payvin
 *
 *   SKALE IMA is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as published
 *   by the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   SKALE IMA is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with SKALE IMA.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@skalenetwork/ima-interfaces/schain/IMessageProxyForSchain.sol";
import "@skalenetwork/etherbase-interfaces/IEtherbaseUpgradeable.sol";

import "../MessageProxy.sol";
import "./bls/SkaleVerifier.sol";

interface IMessageProxyForSchainInitializeFunction is IMessageProxyForSchain {
    function initializeAllRegisteredContracts(
        bytes32 schainHash,
        address[] calldata contracts
    ) external;
}


/**
 * @title MessageProxyForSchain
 * @dev Entry point for messages that come from mainnet or other SKALE chains
 * and contract that emits messages for mainnet or other SKALE chains.
 * 
 * Messages are submitted by IMA-agent and secured with threshold signature.
 * 
 * IMA-agent monitors events of {MessageProxyForSchain} and sends messages to other chains.

 * NOTE: 16 Agents
 * Synchronize time with time.nist.gov
 * Every agent checks if it is their time slot
 * Time slots are in increments of 5 minutes
 * At the start of their slot each agent:
 * For each connected schain:
 * Read incoming counter on the dst chain
 * Read outgoing counter on the src chain
 * Calculate the difference outgoing - incoming
 * Call postIncomingMessages function passing (un)signed message array
 * ID of this schain, Chain 0 represents ETH mainnet,
 */
contract MessageProxyForSchain is MessageProxy, IMessageProxyForSchainInitializeFunction {
    using AddressUpgradeable for address;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    IEtherbaseUpgradeable public constant ETHERBASE = IEtherbaseUpgradeable(
        payable(0xd2bA3e0000000000000000000000000000000000)
    );
    uint public constant MINIMUM_BALANCE = 1 ether;

    /**
     * @dev Structure that contains information about outgoing message.
     */

    /**
     * @dev Address of {KeyStorage}.
     */
    IKeyStorage public keyStorage;

    /**
     * @dev Keccak256 hash of schain name.
     */
    bytes32 public schainHash;

    /**
     * @dev Hashed of meta information of outgoing messages.
     */
    //      schainHash  =>      message_id  => MessageData
    mapping(bytes32 => mapping(uint256 => bytes32)) private _outgoingMessageDataHash;

    /**
     * @dev First unprocessed outgoing message.
     */
    //      schainHash  => head of unprocessed messages
    mapping(bytes32 => uint) private _idxHead;

    /**
     * @dev Last unprocessed outgoing message.
     */
    //      schainHash  => tail of unprocessed messages
    mapping(bytes32 => uint) private _idxTail;

    mapping(bytes32 => EnumerableSetUpgradeable.AddressSet) private _registryContracts;

    string public version;

    /**
     * @dev Allows DEFAULT_ADMIN_ROLE to initialize registered contracts
     * Notice - this function will be executed only once during upgrade
     * 
     * Requirements:
     * 
     * `msg.sender` should have DEFAULT_ADMIN_ROLE
     */
    function initializeAllRegisteredContracts(
        bytes32 chainHash,
        address[] calldata contracts
    ) external override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Sender is not authorized");
        for (uint256 i = 0; i < contracts.length; i++) {
            if (
                deprecatedRegistryContracts[chainHash][contracts[i]] &&
                !_registryContracts[chainHash].contains(contracts[i])
            ) {
                _registryContracts[chainHash].add(contracts[i]);
                delete deprecatedRegistryContracts[chainHash][contracts[i]];
            }
        }
    }

    /**
     * @dev Allows MessageProxy to register extra contract to transfer messages from custom contracts.
     * 
     * Requirements:
     * 
     * - Function caller has to be granted with {EXTRA_CONTRACT_REGISTRAR_ROLE}.
     * - Destination chain hash cannot be equal to itself
     */
    function registerExtraContract(
        string memory chainName,
        address extraContract
    )
        external
        override
        onlyExtraContractRegistrar
    {
        bytes32 chainHash = keccak256(abi.encodePacked(chainName));
        require(chainHash != schainHash, "Destination chain hash cannot be equal to itself");
        _registerExtraContract(chainHash, extraContract);
    }

    /**
     * @dev Allows MessageProxy to remove extra contract,
     * thus `extraContract` will no longer be available to transfer messages from chain to chain.
     * 
     * Requirements:
     * 
     * - Function caller has to be granted with {EXTRA_CONTRACT_REGISTRAR_ROLE}.
     * - Destination chain hash cannot be equal to itself
     */
    function removeExtraContract(
        string memory chainName,
        address extraContract
    )
        external
        override
        onlyExtraContractRegistrar
    {
        bytes32 chainHash = keccak256(abi.encodePacked(chainName));
        require(chainHash != schainHash, "Destination chain hash cannot be equal to itself");
        _removeExtraContract(chainHash, extraContract);
    }

    /**
     * @dev Link external chain.
     *
     * NOTE: Mainnet is linked automatically.
     * 
     * Requirements:
     * 
     * - Function caller has to be granted with {CHAIN_CONNECTOR_ROLE}.
     * - Target chain must be different from the current.
     */
    function addConnectedChain(string calldata chainName) external override {
        bytes32 chainHash = keccak256(abi.encodePacked(chainName));
        require(chainHash != schainHash, "Schain cannot connect itself");
        _addConnectedChain(chainHash);
    }    

    /**
     * @dev Entry point for incoming messages.
     * This function is called by IMA-agent to deliver incoming messages from external chains.
     * 
     * Requirements:
     * 
     * - Origin chain has to be registered.
     * - Amount of messages must be no more than {MESSAGES_LENGTH}.
     * - Messages batch has to be signed with threshold signature.
     * by super majority of current SKALE chain nodes.
     * - All previous messages must be already delivered.
     */
    function postIncomingMessages(
        string calldata fromChainName,
        uint256 startingCounter,
        Message[] calldata messages,
        Signature calldata signature 
    )
        external
        override(IMessageProxy, MessageProxy)
    {
        bytes32 fromChainHash = keccak256(abi.encodePacked(fromChainName));
        require(connectedChains[fromChainHash].inited, "Chain is not initialized");
        require(messages.length <= MESSAGES_LENGTH, "Too many messages");
        require(
            _verifyMessages(
                _hashedArray(messages, startingCounter, fromChainName),
                signature
            ),
            "Signature is not verified"
        );
        require(
            startingCounter == connectedChains[fromChainHash].incomingMessageCounter,
            "Starting counter is not qual to incoming message counter");
        for (uint256 i = 0; i < messages.length; i++) {
            _callReceiverContract(fromChainHash, messages[i], startingCounter + 1);
        }
        connectedChains[fromChainHash].incomingMessageCounter += messages.length;
        _topUpBalance();
    }

    /**
     * @dev Sets new version of contracts on schain
     * 
     * Requirements:
     * 
     * - `msg.sender` must be granted DEFAULT_ADMIN_ROLE.
     */
    function setVersion(string calldata newVersion) external override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "DEFAULT_ADMIN_ROLE is required");
        emit VersionUpdated(version, newVersion);
        version = newVersion;
    }

    /**
     * @dev Verify if the message metadata is valid.
     */
    function verifyOutgoingMessageData(
        OutgoingMessageData memory message
    )
        external
        view
        override
        returns (bool isValidMessage)
    {
        bytes32 messageDataHash = _outgoingMessageDataHash[message.dstChainHash][message.msgCounter];
        if (messageDataHash == _hashOfMessage(message))
            isValidMessage = true;
    }

    /**
     * @dev Verify signature of hashed message
     */
    function verifySignature(bytes32 hashedMessage, MessageProxyForSchain.Signature calldata signature)
        external
        view
        override
        returns (bool)
    {
        return _verifyMessages(hashedMessage, signature);
    }

    /**
     * @dev Is called once during contract deployment.
     */
    function initialize(IKeyStorage blsKeyStorage, string memory schainName)
        public
        override
        virtual
        initializer
    {
        MessageProxy.initializeMessageProxy(3e6);
        keyStorage = blsKeyStorage;
        connectedChains[
            MAINNET_HASH
        ] = ConnectedChainInfo(
            0,
            0,
            true
        );
	    schainHash = keccak256(abi.encodePacked(schainName));

        // In predeployed mode all token managers and community locker
        // will be added to registryContracts
    }

    /**
     * @dev Unlink external SKALE chain.
     * 
     * Requirements:
     * 
     * - Function caller has to be granted with {CHAIN_CONNECTOR_ROLE}.
     * - Target chain must be different from Mainnet.
     */
    function removeConnectedChain(
        string memory chainName
    )
        public
        override(IMessageProxy, MessageProxy)
        onlyChainConnector
    {
        bytes32 chainHash = keccak256(abi.encodePacked(chainName));
        require(chainHash != MAINNET_HASH, "Mainnet cannot be removed");
        super.removeConnectedChain(chainName);
    }

    /**
     * @dev This function is called by a smart contract
     * that wants to make a cross-chain call.
     * 
     * Requirements:
     * 
     * - Destination chain has to be registered.
     * - Sender contract has to be registered.
     */
    function postOutgoingMessage(
        bytes32 targetChainHash,
        address targetContract,
        bytes memory data
    )
        public
        override(IMessageProxy, MessageProxy)
    {
        super.postOutgoingMessage(targetChainHash, targetContract, data);

        OutgoingMessageData memory outgoingMessageData = OutgoingMessageData(
            targetChainHash,
            connectedChains[targetChainHash].outgoingMessageCounter - 1,
            msg.sender,
            targetContract,
            data
        );

        bytes32 dstChainHash = outgoingMessageData.dstChainHash;
        _outgoingMessageDataHash[dstChainHash][_idxTail[dstChainHash]] = _hashOfMessage(outgoingMessageData);
        _idxTail[dstChainHash] += 1;
    }

    // private

    /**
     * @dev Converts calldata structure to memory structure and checks
     * whether message BLS signature is valid.
     * Returns true if signature is valid.
     */
    function _verifyMessages(
        bytes32 hashedMessages,
        MessageProxyForSchain.Signature calldata signature
    )
        internal
        view
        virtual
        returns (bool)
    {
        return SkaleVerifier.verify(
            IFieldOperations.Fp2Point({
                a: signature.blsSignature[0],
                b: signature.blsSignature[1]
            }),
            hashedMessages,
            signature.counter,
            signature.hashA,
            signature.hashB,
            keyStorage.getBlsCommonPublicKey()
        );
    }

    /**
     * @dev Returns list of registered custom extra contracts.
     */
    function _getRegistryContracts()
        internal
        view
        override
        returns (mapping(bytes32 => EnumerableSetUpgradeable.AddressSet) storage)
    {
        return _registryContracts;
    }

    /**
     * @dev Returns Etherbase contract
     */
    function _getEtherbase() internal view virtual returns (IEtherbaseUpgradeable) {
        return ETHERBASE;
    }

    /**
     * @dev Move skETH from Etherbase if the balance is too low
     */
    function _topUpBalance() private {
        uint balance = msg.sender.balance + gasleft() * tx.gasprice;
        IEtherbaseUpgradeable etherbase = _getEtherbase();
        if (address(etherbase).isContract()
            && etherbase.hasRole(etherbase.ETHER_MANAGER_ROLE(), address(this)) 
            && balance < MINIMUM_BALANCE
        ) {
            uint missingAmount = MINIMUM_BALANCE - balance;
            if (missingAmount < address(etherbase).balance) {
                etherbase.partiallyRetrieve(payable(msg.sender), missingAmount);
            } else {
                etherbase.retrieve(payable(msg.sender));
            }
        }
    }

    /**
     * @dev Calculate a message hash.
     */
    function _hashOfMessage(OutgoingMessageData memory message) private pure returns (bytes32) {
        bytes memory data = abi.encodePacked(
            message.dstChainHash,
            bytes32(message.msgCounter),
            bytes32(bytes20(message.srcContract)),
            bytes32(bytes20(message.dstContract)),
            message.data
        );
        return keccak256(data);
    }    
}
