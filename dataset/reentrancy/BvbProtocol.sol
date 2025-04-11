// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {WETH} from "solmate/tokens/WETH.sol";

contract BvbProtocol is EIP712("BullvBear", "1"), Ownable, ReentrancyGuard, ERC721TokenReceiver {
    using SafeERC20 for IERC20;

    /*    TYPES    */

    /**
     * @notice Order details
     * @param premium The amount paid by the bear
     * @param collateral The amount paid by the bull
     * @param validity The timestamp after which this order is invalid
     * @param expiry The timestamp after which this contract is expired
     * @param nonce A number used to check order validity and to prevent order reuse
     * @param fee Fees that should be applied
     * @param maker The address of the user making the order
     * @param asset The address of the ERC20 asset used to pay the contract
     * @param collection The address of the ERC721 collection
     * @param isBull Is the maker on the bull side (short put)
     */
    struct Order {
        uint premium;
        uint collateral;
        uint validity;
        uint expiry;
        uint nonce;
        uint16 fee;
        address maker;
        address asset;
        address collection;
        bool isBull;
    }

    /**
     * @notice SellOrder details
     * @param orderHash The EIP712 hash of the order/contract
     * @param price The minimum amount to buy the position
     * @param start The timestamp after which this sell order can be used, 
     * @param end The timestamp after which this order can't be used
     * @param nonce A number used to check sell order validity
     * @param maker The address of the user making the sell order
     * @param asset The address of the ERC20 asset used to buy the position
     * @param whitelist Addresses whitelisted to use this sell order, anyone if empty
     * @param isBull Is it the Bull or Bear position to sell
     */
    struct SellOrder {
        bytes32 orderHash;
        uint price;
        uint start;
        uint end;
        uint nonce;
        address maker;
        address asset;
        address[] whitelist;
        bool isBull;
    }

    /*    STATE    */

    /**
     * @notice Order type hash used for EIP712
     */
    bytes32 public constant ORDER_TYPE_HASH = keccak256(
        "Order(uint premium,uint collateral,uint validity,uint expiry,uint nonce,uint16 fee,address maker,address asset,address collection,bool isBull)"
    );

     /**
     * @notice Sell Order type hash used for EIP712
     */
    bytes32 public constant SELL_ORDER_TYPE_HASH = keccak256(
        "SellOrder(bytes32 orderHash,uint price,uint start,uint end,uint nonce,address maker,address asset,address[] whitelist,bool isBull)"
    );

    /**
     * @notice The address of WETH contract
     */
    address payable public immutable weth;

    /**
     * @notice Fee rate applied
     * 1 = 0.1%
     */
    uint16 public fee;

    /**
     * @notice Amount of fees withdrawable by the owner
     * assetAddress => amount
     */
    mapping(address => uint) public withdrawableFees;

    /**
     * @notice Is the asset supported as payment by the protocol
     * assetAddress => isSupported
     */
    mapping(address => bool) public allowedAsset;

    /**
     * @notice Is the collection supported by the protocol
     * collectionAddress => isSupported
     */
    mapping(address => bool) public allowedCollection;

    /**
     * @notice Order filled with this id
     * contractId => Order
     */
    mapping(uint => Order) public matchedOrders;

    /**
     * @notice Sell Order bought with this id
     * sellOrderHash => SellOrder
     */
    mapping(bytes32 => SellOrder) public boughtSellOrders;

    /**
     * @notice Address of the bull for a contract
     * contractId => Bull address
     */
    mapping(uint => address) public bulls;

    /**
     * @notice Address of the bear for a contract
     * contractId => Bear address
     */
    mapping(uint => address) public bears;

    /**
     * @notice Is the contract settled
     * contractId => isSettled
     */
    mapping(uint => bool) public settledContracts;

    /**
     * @notice Is the contract reclaimed
     * contractId => isReclaimed
     */
    mapping(uint => bool) public reclaimedContracts;

    /**
     * @notice Is the order canceled
     * orderHash => isCanceled
     */
    mapping(bytes32 => bool) public canceledOrders;

    /**
     * @notice Is the sell order canceled
     * sellOrderHash => isCanceled
     */
    mapping(bytes32 => bool) public canceledSellOrders;

    /**
     * @notice Recipient allowed to withdraw a collection token from BvbProtocol
     * collection => tokenID => recipient
     */
    mapping(address => mapping(uint => address)) public withdrawableCollectionTokenId;

    /**
     * @notice Minimum valid nonce of a user
     * userAddress => nonce
     */
    mapping(address => uint) public minimumValidNonce;

    /**
     * @notice Minimum valid nonce sell of a user
     * userAddress => nonce
     */
    mapping(address => uint) public minimumValidNonceSell;

    /*    EVENTS    */

    /**
     * @notice Emitted when a collection status has changed
     * @param collection The ERC721 collection address
     * @param allowed Is the collection supported or not
     */
    event AllowCollection(address collection, bool allowed);

    /**
     * @notice Emitted when an asset status has changed
     * @param asset The ERC20 asset address
     * @param allowed Is the collection supported or not
     */
    event AllowAsset(address asset, bool allowed);

    /**
     * @notice Emitted when fee rate is updated
     * @param fee The new fee rate
     */
    event UpdatedFee(uint16 fee);

    /**
     * @notice Emitted when fees are withdrawn
     * @param asset The address of the ERC20 asset
     * @param amount Amount withdrawn
     */
    event WithdrawnFees(address asset, uint amount);

    /**
     * @notice Emitted when minimum valid nonce is updated
     * @param user The user whom increased his minimum valid nonce
     * @param minimumValidNonce The new minimum valid nonce of a user
     */
    event UpdatedMinimumValidNonce(address indexed user, uint minimumValidNonce);

    /**
     * @notice Emitted when sell minimum valid nonce is updated
     * @param user The user whom increased his sell minimum valid nonce
     * @param minimumValidNonceSell The new sell minimum valid nonce of a user
     */
    event UpdatedMinimumValidNonceSell(address indexed user, uint minimumValidNonceSell);

    /**
     * @notice Emitted when an order is canceled
     * @param orderHash The EIP712 hash of the order canceled
     * @param bull The Bull of this contract
     * @param bear The Bear of this contract
     * @param order The matched order
     */
    event MatchedOrder(bytes32 orderHash, address indexed bull, address indexed bear, Order order);

    /**
     * @notice Emitted when a contract (order matched) is settled
     * @param orderHash The EIP712 hash of the order
     * @param tokenId The id of the token used to settle the contract
     * @param order The order
     */
    event SettledContract(bytes32 orderHash, uint tokenId, Order order);

    /**
     * @notice Emitted when a contract (order matched) is reclaimed
     * @param orderHash The EIP712 hash of the order
     * @param order The order
     */
    event ReclaimedContract(bytes32 orderHash, Order order);

    /**
     * @notice Emitted when a token is withdrawn
     * @param orderHash The EIP712 hash of the order
     * @param tokenId The ID of the token withdrawn
     * @param recipient The recipient of the token
     */
    event WithdrawnToken(bytes32 orderHash, uint tokenId, address recipient);

    /**
     * @notice Emitted when a position is sold
     * @param sellOrderHash The EIP712 hash of the sell order
     * @param sellOrder The sell order
     * @param orderHash The EIP712 hash of the order
     * @param order The order
     * @param buyer The buyer of the position
     */
    event SoldPosition(bytes32 sellOrderHash, SellOrder sellOrder, bytes32 orderHash, Order order, address indexed buyer);

    /**
     * @notice Emitted when a position is transfered
     * @param orderHash The EIP712 hash of the order
     * @param isBull Is it the Bull position
     * @param recipient The new owner of this position
     */
    event TransferedPosition(bytes32 orderHash, bool isBull, address recipient);

    /**
     * @notice Emitted when an order is canceled
     * @param orderHash The EIP712 hash of the order canceled
     * @param order The canceled order
     */
    event CanceledOrder(bytes32 orderHash, Order order);

    /**
     * @notice Emitted when a sell order is canceled
     * @param sellOrderHash The EIP712 hash of the sell order canceled
     * @param sellOrder The canceled sell order
     */
    event CanceledSellOrder(bytes32 sellOrderHash, SellOrder sellOrder);

    /**
     * @param _fee The initial fee
     * @param _weth Address of WETH contract
     */
    constructor(uint16 _fee, address _weth) {
        weth = payable(_weth);

        setFee(_fee);
    }

    /*    USER METHODS    */

    /**
     * @notice Take the opposite side of an order and launch a contract between maker and taker
     * @param order The order to match with
     * @param signature The signature of the order hashed
     * @return contractId The ID of the contract, defined by the order hash 
     */
    function matchOrder(Order calldata order, bytes calldata signature) public payable nonReentrant returns (uint) {
        bytes32 orderHash = hashOrder(order);

        // ContractId
        uint contractId = uint(orderHash);

        // Check that this order is valid
        checkIsValidOrder(order, orderHash, signature);

        // Fees
        uint bullFees;
        uint bearFees;
        if (fee > 0) {
            bullFees = (order.collateral * fee) / 1000;
            bearFees = (order.premium * fee) / 1000;

            withdrawableFees[order.asset] += bullFees + bearFees;
        }

        address bull;
        address bear;
        uint makerPrice;
        uint takerPrice;

        if (order.isBull) {
            bull = order.maker;
            bear = msg.sender;

            makerPrice = order.collateral + bullFees;
            takerPrice = order.premium + bearFees;
        } else {
            bull = msg.sender;
            bear = order.maker;

            makerPrice = order.premium + bearFees;
            takerPrice = order.collateral + bullFees;
        }

        bulls[contractId] = bull;
        bears[contractId] = bear;

        // Retrieve Taker payment
        if (msg.value > 0) {
            require(msg.value == takerPrice, "INVALID_ETH_VALUE");
            require(order.asset == weth, "INCOMPATIBLE_ASSET_ETH_VALUE");

            WETH(weth).deposit{value: msg.value}();
        } else if(takerPrice > 0) {
            IERC20(order.asset).safeTransferFrom(msg.sender, address(this), takerPrice);
        }
        // Retrieve Maker payment
        if (makerPrice > 0) {
            IERC20(order.asset).safeTransferFrom(order.maker, address(this), makerPrice);
        }

        // Store the order
        matchedOrders[contractId] = order;

        emit MatchedOrder(orderHash, bull, bear, order);

        return contractId;
    }

    /**
     * @notice Settle the contract by sending a NFT to the bull
     * @param order The order used to launch the contract
     * @param tokenId The token used to settle the contract
     */
    function settleContract(Order calldata order, uint tokenId) public nonReentrant {
        bytes32 orderHash = hashOrder(order);

        // ContractId
        uint contractId = uint(orderHash);

        address bear = bears[contractId];

        // Check that only the bear can settle the contract
        require(msg.sender == bear, "ONLY_BEAR");

        // Check that the contract is not expired
        require(block.timestamp < order.expiry, "EXPIRED_CONTRACT");

        // Check that the contract is not already settled
        require(!settledContracts[contractId], "SETTLED_CONTRACT");

        address bull = bulls[contractId];

        // Try to transfer the NFT to the bull (needed in case of a malicious bull that block transfers)
        try IERC721(order.collection).safeTransferFrom(bear, bull, tokenId) {}
        catch (bytes memory) {
            // Transfer NFT to BvbProtocol
            IERC721(order.collection).safeTransferFrom(bear, address(this), tokenId);
            // Store that the bull has to retrieve it
            withdrawableCollectionTokenId[order.collection][tokenId] = bull;
        }

        uint bearAssetAmount = order.premium + order.collateral;
        if (bearAssetAmount > 0) {
            // Transfer payment tokens to the Bear
            IERC20(order.asset).safeTransfer(bear, bearAssetAmount);
        }

        settledContracts[contractId] = true;

        emit SettledContract(orderHash, tokenId, order);
    }

    /**
     * @notice Reclaim the contract after it expired without settlement
     * @param order The order used to launch the contract
     */
    function reclaimContract(Order calldata order) public nonReentrant {
        bytes32 orderHash = hashOrder(order);

        // ContractId
        uint contractId = uint(orderHash);

        address bull = bulls[contractId];

        // Check that the contract is expired
        require(block.timestamp > order.expiry, "NOT_EXPIRED_CONTRACT");

        // Check that the contract is not settled
        require(!settledContracts[contractId], "SETTLED_CONTRACT");

        // Check that the contract is not reclaimed
        require(!reclaimedContracts[contractId], "RECLAIMED_CONTRACT");

        uint bullAssetAmount = order.premium + order.collateral;
        if (bullAssetAmount > 0) {
            // Transfer payment tokens to the Bull
            IERC20(order.asset).safeTransfer(bull, bullAssetAmount);
        }

        reclaimedContracts[contractId] = true;

        emit ReclaimedContract(orderHash, order);
    }

    /**
     * @notice Withdraw a NFT from BvbProtocol
     * @param orderHash The EIP712 hash of the order
     * @param tokenId The ID of the token to withdraw
     */
    function withdrawToken(bytes32 orderHash, uint tokenId) public {
        address collection = matchedOrders[uint(orderHash)].collection;

        address recipient = withdrawableCollectionTokenId[collection][tokenId];

        // Transfer NFT to recipient
        IERC721(collection).safeTransferFrom(address(this), recipient, tokenId);

        // This token is not withdrawable anymore
        withdrawableCollectionTokenId[collection][tokenId] = address(0);

        emit WithdrawnToken(orderHash, tokenId, recipient);
    }

    /**
     * @notice Buy a Contract position from the Bull or Bear
     * @param sellOrder The sell order of the position
     * @param signature The signature of the sell order hashed
     * @return sellOrderId The ID of the sell order, defined by the order hash 
     */
    function buyPosition(SellOrder calldata sellOrder, bytes calldata signature) public payable nonReentrant returns (uint) {
        bytes32 orderHash = sellOrder.orderHash;

        bytes32 sellOrderHash = hashSellOrder(sellOrder);

        // ContractId
        uint contractId = uint(orderHash);

        // SellOrderId
        uint sellOrderId = uint(sellOrderHash);

        // Contract order
        Order memory order = matchedOrders[contractId];

        // Check that this sell order is valid
        checkIsValidSellOrder(sellOrder, sellOrderHash, order, orderHash, signature);

        // Check that the buyer is allowed to buy
        require(sellOrder.whitelist.length == 0 || isWhitelisted(sellOrder.whitelist, msg.sender), "INVALID_BUYER");

        if (msg.value > 0) {
            // Buyer could send more ETH than asked
            require(msg.value >= sellOrder.price, "INVALID_ETH_VALUE");
            require(sellOrder.asset == weth, "INCOMPATIBLE_ASSET_ETH_VALUE");

            WETH(weth).deposit{value: msg.value}();
            IERC20(weth).safeTransfer(sellOrder.maker, msg.value);
        } else if (sellOrder.price > 0) {
            IERC20(sellOrder.asset).safeTransferFrom(msg.sender, sellOrder.maker, sellOrder.price);
        }

        if (sellOrder.isBull) {
            bulls[contractId] = msg.sender;
        } else {
            bears[contractId] = msg.sender;
        }

        // Save the Sell Order
        boughtSellOrders[sellOrderHash] = sellOrder;

        emit SoldPosition(sellOrderHash, sellOrder, orderHash, order, msg.sender);

        return sellOrderId;
    }

    /**
     * @notice Transfer a contract position
     * @param orderHash The EIP712 hash of the order
     * @param isBull Is it the Bull or Bear position to transfer
     * @param recipient The address of the new owner of the position
     */
    function transferPosition(bytes32 orderHash, bool isBull, address recipient) public {
        // ContractId
        uint contractId = uint(orderHash);

        if (isBull) {
            // Check that the msg.sender is the Bull
            require(msg.sender == bulls[contractId], "SENDER_NOT_BULL");

            bulls[contractId] = recipient;
        } else {
            // Check that the msg.sender is the Bear
            require(msg.sender == bears[contractId], "SENDER_NOT_BEAR");

            bears[contractId] = recipient;
        }

        emit TransferedPosition(orderHash, isBull, recipient);
    }

    /**
     * @notice Method allowing to match several order in one call
     * @param orders Orders to match with
     * @param signatures Signatures of orders' hashes
     * @return contractIds IDs of contracts, defined by the order hashes 
     */
    function batchMatchOrders(Order[] calldata orders, bytes[] calldata signatures) external returns (uint[] memory) {
        require(orders.length == signatures.length, "INVALID_ORDERS_COUNT");

        uint[] memory contractIds = new uint[](orders.length);

        for (uint i; i<orders.length; i++) {
            contractIds[i] = matchOrder(orders[i], signatures[i]);
        }

        return contractIds;
    }

    /**
     * @notice Method allowing to reclaim several contracts in one call
     * @param orders Orders used to launch contracts to settle
     * @param tokenIds Tokens used to settle contracts
     */
    function batchSettleContracts(Order[] calldata orders, uint[] calldata tokenIds) external {
        require(orders.length == tokenIds.length, "INVALID_ORDERS_COUNT");

        for (uint i; i<orders.length; i++) {
            settleContract(orders[i], tokenIds[i]);
        }
    }

    /**
     * @notice Method allowing to reclaim several contracts in one call
     * @param orders Orders used to launch contracts to reclaim
     */
    function batchReclaimContracts(Order[] calldata orders) external {
        for (uint i; i<orders.length; i++) {
            reclaimContract(orders[i]);
        }
    }

    /**
     * @notice Cancel an order
     * @param order The order to cancel
     */
    function cancelOrder(Order memory order) external {
        require(order.maker == msg.sender, "NOT_SIGNER");

        bytes32 orderHash = hashOrder(order);

        require(!canceledOrders[orderHash], "ALREADY_CANCELED");

        require(matchedOrders[uint(orderHash)].maker == address(0), "ORDER_MATCHED");

        canceledOrders[orderHash] = true;

        emit CanceledOrder(orderHash, order);
    }

    /**
     * @notice Cancel a sell order
     * @param sellOrder The sell order to cancel
     */
    function cancelSellOrder(SellOrder memory sellOrder) external {
        require(sellOrder.maker == msg.sender, "NOT_SIGNER");

        bytes32 sellOrderHash = hashSellOrder(sellOrder);

        require(!canceledSellOrders[sellOrderHash], "ALREADY_CANCELED");

        require(boughtSellOrders[sellOrderHash].maker == address(0), "POSITION_SOLD");

        canceledSellOrders[sellOrderHash] = true;

        emit CanceledSellOrder(sellOrderHash, sellOrder);
    }

    /**
     * @notice Sets a new minimal valid nonce
     * @param _minimumValidNonce The new minimal valid nonce
     */
    function setMinimumValidNonce(uint _minimumValidNonce) external {
        require(_minimumValidNonce > minimumValidNonce[msg.sender], "NONCE_TOO_LOW");

        minimumValidNonce[msg.sender] = _minimumValidNonce;

        emit UpdatedMinimumValidNonce(msg.sender, _minimumValidNonce);
    }

    /**
     * @notice Sets a new sell minimal valid nonce
     * @param _minimumValidNonceSell The new sell minimal valid nonce
     */
    function setMinimumValidNonceSell(uint _minimumValidNonceSell) external {
        require(_minimumValidNonceSell > minimumValidNonceSell[msg.sender], "NONCE_TOO_LOW");

        minimumValidNonceSell[msg.sender] = _minimumValidNonceSell;

        emit UpdatedMinimumValidNonceSell(msg.sender, _minimumValidNonceSell);
    }

    /*    EIP712    */

    /**
     * @notice Hashes an order according to EIP712
     * @param order The order to hash
     * @return The EIP712 hash of the order
     */
    function hashOrder(Order memory order) public view returns (bytes32) {
        bytes32 orderHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                order.premium,
                order.collateral,
                order.validity,
                order.expiry,
                order.nonce,
                order.fee,
                order.maker,
                order.asset,
                order.collection,
                order.isBull
            )
        );

        return _hashTypedDataV4(orderHash);
    }

    /**
     * @notice Hashes a sell order according to EIP712
     * @param sellOrder The sell order to hash
     * @return The EIP712 hash of the sell order
     */
    function hashSellOrder(SellOrder memory sellOrder) public view returns (bytes32) {
        bytes32 sellOrderHash = keccak256(
            abi.encode(
                SELL_ORDER_TYPE_HASH,
                sellOrder.orderHash,
                sellOrder.price,
                sellOrder.start,
                sellOrder.end,
                sellOrder.nonce,
                sellOrder.maker,
                sellOrder.asset,
                keccak256(abi.encodePacked(sellOrder.whitelist)),
                sellOrder.isBull
            )
        );

        return _hashTypedDataV4(sellOrderHash);
    }

    /**
     * @notice Checks if a signature is valid for a given signer and an order hash
     * @param signer The address used to sign
     * @param orderHash The EIP712 hash of the order
     * @param signature The signature of the order hash
     * @return true if the signature was made by the signer
     */
    function isValidSignature(address signer, bytes32 orderHash, bytes calldata signature) public pure returns (bool) {
        return ECDSA.recover(orderHash, signature) == signer;
    }

    /**
     * @notice Return the domain separator of this contract used to calculte EIP712 order hash
     * @return The domain separator
     */
    function domainSeparatorV4() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*    HELPERS METHODS    */

    /**
     * @notice Checks if a buyer is whitelisted
     * @param whitelist The array of whitelisted address
     * @param buyer The buyer address
     * @return If the buyer is in the whitelist or not
     */
    function isWhitelisted(address[] memory whitelist, address buyer) public pure returns (bool) {
        for (uint i; i<whitelist.length; i++) {
            if (buyer == whitelist[i]) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Checks if an order is valid
     * @param order The order/contract
     * @param orderHash The EIP712 hash of the order
     * @param signature The signature of the order hashed
     */
    function checkIsValidOrder(Order calldata order, bytes32 orderHash, bytes calldata signature) public view {
        // Check that the signature is valid
        require(isValidSignature(order.maker, orderHash, signature), "INVALID_SIGNATURE");

        // Check that this order is still valid
        require(order.validity > block.timestamp, "EXPIRED_VALIDITY_TIME");

        // Check that this order was not canceled
        require(!canceledOrders[orderHash], "ORDER_CANCELED");

        // Check that the nonce is valid
        require(order.nonce >= minimumValidNonce[order.maker], "INVALID_NONCE");
        
        // Check that this contract will expire in the future
        require(order.expiry > order.validity, "INVALID_EXPIRY_TIME");

        // Check that fees match
        require(order.fee >= fee, "INVALID_FEE");

        // Check that this is an approved ERC20 token
        require(allowedAsset[order.asset], "INVALID_ASSET");

        // Check that this if an approved ERC721 collection
        require(allowedCollection[order.collection], "INVALID_COLLECTION");

        // Check that there is no bull set for this order -> not matched
        require(bulls[uint(orderHash)] == address(0), "ORDER_ALREADY_MATCHED");
    }

    /**
     * @notice Checks if a sell order is valid
     * @param sellOrder The sell order of the position
     * @param sellOrderHash The EIP712 hash of the sell order
     * @param order The order/contract
     * @param orderHash The EIP712 hash of the order
     * @param signature The signature of the sell order hashed
     */
    function checkIsValidSellOrder(SellOrder calldata sellOrder, bytes32 sellOrderHash, Order memory order, bytes32 orderHash, bytes calldata signature) public view {
        // ContractId
        uint contractId = uint(orderHash);
        
        // Check that the signature is valid
        require(isValidSignature(sellOrder.maker, sellOrderHash, signature), "INVALID_SIGNATURE");

        if (sellOrder.isBull) {
            // Check that the maker is the Bull
            require(sellOrder.maker == bulls[contractId], "MAKER_NOT_BULL");

            // Check that the contract is not reclaimed
            require(!reclaimedContracts[contractId], "RECLAIMED_CONTRACT");
        } else {
            // Check that the maker is the Bear
            require(sellOrder.maker == bears[contractId], "MAKER_NOT_BEAR");

            // Check that the contract hasn't expired
            require(block.timestamp < order.expiry, "CONTRACT_EXPIRED");
        }

        // Check that there is no maker set for this sell order -> not bought
        require(boughtSellOrders[sellOrderHash].maker == address(0), "SELL_ORDER_ALREADY_BOUGHT");

        // Check that this order was not canceled
        require(!canceledSellOrders[sellOrderHash], "SELL_ORDER_CANCELED");

        // Check that this sell order has started
        require(block.timestamp >= sellOrder.start, "INVALID_START_TIME");

        // Check that the sell order hasn't expired
        require(block.timestamp <= sellOrder.end, "SELL_ORDER_EXPIRED");

        // Check that the contract is not settled
        require(!settledContracts[contractId], "SETTLED_CONTRACT");
        
        // Check that the nonce is valid
        require(sellOrder.nonce >= minimumValidNonceSell[sellOrder.maker], "INVALID_NONCE");

        // Check that this is an approved ERC20 token
        require(allowedAsset[sellOrder.asset], "INVALID_ASSET");
    }

    /*    OWNER METHODS    */

    /**
     * @notice Sets the collection as supported or not by the protocol
     * @param collection The collection
     * @param allowed Is the collection supported or not
     */
    function setAllowedCollection(address collection, bool allowed) public onlyOwner {
        allowedCollection[collection] = allowed;

        emit AllowCollection(collection, allowed);
    }

    /**
     * @notice Sets the asset as supported as payment or not by the protocol
     * @param asset The collection
     * @param allowed Is the collection supported or not
     */
    function setAllowedAsset(address asset, bool allowed) public onlyOwner {
        allowedAsset[asset] = allowed;

        emit AllowAsset(asset, allowed);
    }

    /**
     * @notice Sets a new fee rate
     * @param _fee The new fee rate
     */
    function setFee(uint16 _fee) public onlyOwner {
        // Fee rate can't be greater than 5%
        require(_fee <= 50, "INVALID_FEE_RATE");

        fee = _fee;

        emit UpdatedFee(_fee);
    }

    /**
     * @notice Withdraw fees
     * @param asset The ERC20 asset address
     * @param recipient The recipient of the fees
     */
    function withdrawFees(address asset, address recipient) external onlyOwner {
        uint amount = withdrawableFees[asset];

        withdrawableFees[asset] = 0;

        IERC20(asset).safeTransfer(recipient, amount);

        emit WithdrawnFees(asset, amount);
    }
}