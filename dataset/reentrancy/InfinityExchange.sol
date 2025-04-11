// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

// external imports
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import {IERC165} from '@openzeppelin/contracts/interfaces/IERC165.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC20, SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

// internal imports
import {OrderTypes} from '../libs/OrderTypes.sol';
import {IComplication} from '../interfaces/IComplication.sol';
import {SignatureChecker} from '../libs/SignatureChecker.sol';

/**
@title InfinityExchange
@author nneverlander. Twitter @nneverlander
@notice The main NFT exchange contract that holds state and does asset transfers
@dev This contract can be extended via 'complications' - strategies that let the exchange execute various types of orders
      like dutch auctions, reverse dutch auctions, floor price orders, private sales, etc.

NFTNFTNFT...........................................NFTNFTNFT
NFTNFT                                                 NFTNFT
NFT                                                       NFT
.                                                           .
.                                                           .
.                                                           .
.                                                           .
.               NFTNFTNFT            NFTNFTNFT              .
.            NFTNFTNFTNFTNFT      NFTNFTNFTNFTNFT           .
.           NFTNFTNFTNFTNFTNFT   NFTNFTNFTNFTNFTNFT         .
.         NFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFT        .
.         NFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFT        .
.         NFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFTNFT        .
.          NFTNFTNFTNFTNFTNFTN   NFTNFTNFTNFTNFTNFT         .
.            NFTNFTNFTNFTNFT      NFTNFTNFTNFTNFT           .
.               NFTNFTNFT            NFTNFTNFT              .
.                                                           .
.                                                           .
.                                                           .
.                                                           .
NFT                                                       NFT
NFTNFT                                                 NFTNFT
NFTNFTNFT...........................................NFTNFTNFT 

*/
contract InfinityExchange is ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @dev WETH address of a chain; set at deploy time to the WETH address of the chain that this contract is deployed to
  address public immutable WETH;
  /// @dev Used in order signing with EIP-712
  bytes32 public immutable DOMAIN_SEPARATOR;
  /// @dev This is the adress that is used to send auto sniped orders for execution on chain
  address public MATCH_EXECUTOR;
  /// @dev Gas cost for auto sniped orders are paid by the buyers and refunded to this contract in the form of WETH
  uint32 public WETH_TRANSFER_GAS_UNITS = 50000;
  /// @notice Exchange fee in basis points (250 bps = 2.5%)
  uint16 public PROTOCOL_FEE_BPS = 250;

  /**
   @dev All orders should have a nonce >= to this value. 
        Any orders with nonce value less than this are non-executable. 
        Used for cancelling all outstanding orders.
  */
  mapping(address => uint256) public userMinOrderNonce;

  /// @dev This records already executed or cancelled orders to prevent replay attacks.
  mapping(address => mapping(uint256 => bool)) public isUserOrderNonceExecutedOrCancelled;

  /// @dev Storage variable that keeps track of valid complications (order execution strategies)
  EnumerableSet.AddressSet private _complications;
  /// @dev Storate variable that keeps track of valid currencies (tokens)
  EnumerableSet.AddressSet private _currencies;

  event CancelAllOrders(address user, uint256 newMinNonce);
  event CancelMultipleOrders(address user, uint256[] orderNonces);
  event NewWethTransferGasUnits(uint32 wethTransferGasUnits);
  event NewProtocolFee(uint16 protocolFee);

  event MatchOrderFulfilled(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    address seller,
    address buyer,
    address complication, // address of the complication that defines the execution
    address currency, // token address of the transacting currency
    uint256 amount // amount spent on the order
  );

  event TakeOrderFulfilled(
    bytes32 orderHash,
    address seller,
    address buyer,
    address complication, // address of the complication that defines the execution
    address currency, // token address of the transacting currency
    uint256 amount // amount spent on the order
  );

  constructor(address _WETH, address _matchExecutor) {
    // Calculate the domain separator
    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('InfinityExchange'),
        keccak256(bytes('1')), // for versionId = 1
        block.chainid,
        address(this)
      )
    );
    WETH = _WETH;
    MATCH_EXECUTOR = _matchExecutor;
  }

  fallback() external payable {}

  receive() external payable {}

  // =================================================== USER FUNCTIONS =======================================================

  /**
   @notice Matches orders one to one where each order has 1 NFT. Example: Match 1 specific NFT buy with one specific NFT sell.
   @dev Can execute orders in batches for gas efficiency. Can only be called by the match executor. Refunds gas cost incurred by the
        match executor to this contract. Checks whether the given complication can execute the match.
   @param makerOrders1 Maker order 1
   @param makerOrders2 Maker order 2
  */
  function matchOneToOneOrders(
    OrderTypes.MakerOrder[] calldata makerOrders1,
    OrderTypes.MakerOrder[] calldata makerOrders2
  ) external {
    uint256 startGas = gasleft();
    uint256 numMakerOrders = makerOrders1.length;
    require(msg.sender == MATCH_EXECUTOR, 'OME');
    require(numMakerOrders == makerOrders2.length, 'mismatched lengths');

    // the below 3 variables are copied to memory once to save on gas
    // an SLOAD costs minimum 100 gas where an MLOAD only costs minimum 3 gas
    // since these values won't change during function execution, we can save on gas by copying them to memory once
    // instead of SLOADing once for each loop iteration
    uint16 protocolFeeBps = PROTOCOL_FEE_BPS;
    uint32 wethTransferGasUnits = WETH_TRANSFER_GAS_UNITS;
    address weth = WETH;
    for (uint256 i = 0; i < numMakerOrders; ) {
      uint256 startGasPerOrder = gasleft() + ((startGas - gasleft()) / numMakerOrders);
      require(_complications.contains(makerOrders1[i].execParams[0]), 'invalid complication');
      (bool canExec, uint256 execPrice) = IComplication(makerOrders1[i].execParams[0]).canExecMatchOneToOne(
        makerOrders1[i],
        makerOrders2[i]
      );
      require(canExec, 'cannot execute');
      _matchOneToOneOrders(
        makerOrders1[i],
        makerOrders2[i],
        startGasPerOrder,
        execPrice,
        protocolFeeBps,
        wethTransferGasUnits,
        weth
      );
      unchecked {
        ++i;
      }
    }
  }

  /**
   @notice Matches one  order to many orders. Example: A buy order with 5 specific NFTs with 5 sell orders with those specific NFTs.
   @dev Can only be called by the match executor. Refunds gas cost incurred by the
        match executor to this contract. Checks whether the given complication can execute the match.
   @param makerOrder The one order to match
   @param manyMakerOrders Array of multiple orders to match the one order against
  */
  function matchOneToManyOrders(
    OrderTypes.MakerOrder calldata makerOrder,
    OrderTypes.MakerOrder[] calldata manyMakerOrders
  ) external {
    uint256 startGas = gasleft();
    require(msg.sender == MATCH_EXECUTOR, 'OME');
    require(_complications.contains(makerOrder.execParams[0]), 'invalid complication');
    require(
      IComplication(makerOrder.execParams[0]).canExecMatchOneToMany(makerOrder, manyMakerOrders),
      'cannot execute'
    );
    bytes32 makerOrderHash = _hash(makerOrder);
    require(isOrderValid(makerOrder, makerOrderHash), 'invalid maker order');
    uint256 ordersLength = manyMakerOrders.length;
    // the below 3 variables are copied to memory once to save on gas
    // an SLOAD costs minimum 100 gas where an MLOAD only costs minimum 3 gas
    // since these values won't change during function execution, we can save on gas by copying them to memory once
    // instead of SLOADing once for each loop iteration
    uint16 protocolFeeBps = PROTOCOL_FEE_BPS;
    uint32 wethTransferGasUnits = WETH_TRANSFER_GAS_UNITS;
    address weth = WETH;
    if (makerOrder.isSellOrder) {
      for (uint256 i = 0; i < ordersLength; ) {
        // 20000 for the SSTORE op that updates maker nonce status from zero to a non zero status
        uint256 startGasPerOrder = gasleft() + ((startGas + 20000 - gasleft()) / ordersLength);
        _matchOneMakerSellToManyMakerBuys(
          makerOrderHash,
          makerOrder,
          manyMakerOrders[i],
          startGasPerOrder,
          protocolFeeBps,
          wethTransferGasUnits,
          weth
        );
        unchecked {
          ++i;
        }
      }
      isUserOrderNonceExecutedOrCancelled[makerOrder.signer][makerOrder.constraints[5]] = true;
    } else {
      uint256 protocolFee;
      for (uint256 i = 0; i < ordersLength; ) {
        protocolFee += _matchOneMakerBuyToManyMakerSells(
          makerOrderHash,
          manyMakerOrders[i],
          makerOrder,
          protocolFeeBps
        );
        unchecked {
          ++i;
        }
      }
      isUserOrderNonceExecutedOrCancelled[makerOrder.signer][makerOrder.constraints[5]] = true;
      uint256 gasCost = (startGas - gasleft() + WETH_TRANSFER_GAS_UNITS) * tx.gasprice;
      // if the execution currency is weth, we can send the protocol fee and gas cost in one transfer to save gas
      // else we need to send the protocol fee separately in the execution currency
      // since the buyer is common across many sell orders, this part can be executed outside the above for loop
      // in contrast to the case where if the one order is a sell order, we need to do this in each for loop
      if (makerOrder.execParams[1] == weth) {
        IERC20(weth).safeTransferFrom(makerOrder.signer, address(this), protocolFee + gasCost);
      } else {
        IERC20(makerOrder.execParams[1]).safeTransferFrom(makerOrder.signer, address(this), protocolFee);
        IERC20(weth).safeTransferFrom(makerOrder.signer, address(this), gasCost);
      }
    }
  }

  /**
   @notice Matches orders one to one where no specific NFTs are specified. 
          Example: A collection wide buy order with any 2 NFTs with a sell order that has any 2 NFTs from that collection.
   @dev Can only be called by the match executor. Refunds gas cost incurred by the
        match executor to this contract. Checks whether the given complication can execute the match.
        The constructs param specifies the actual NFTs that will be executed since buys and sells need not specify actual NFTs - only 
        a higher level intent.
   @param sells User signed sell orders
   @param buys User signed buy orders
   @param constructs Intersection of the NFTs in the sells and buys. Constructed by an off chain matching engine.
  */
  function matchOrders(
    OrderTypes.MakerOrder[] calldata sells,
    OrderTypes.MakerOrder[] calldata buys,
    OrderTypes.OrderItem[][] calldata constructs
  ) external {
    uint256 startGas = gasleft();
    uint256 numSells = sells.length;
    require(msg.sender == MATCH_EXECUTOR, 'OME');
    require(numSells == buys.length && numSells == constructs.length, 'mismatched lengths');
    // the below 3 variables are copied to memory once to save on gas
    // an SLOAD costs minimum 100 gas where an MLOAD only costs minimum 3 gas
    // since these values won't change during function execution, we can save on gas by copying them to memory once
    // instead of SLOADing once for each loop iteration
    uint16 protocolFeeBps = PROTOCOL_FEE_BPS;
    uint32 wethTransferGasUnits = WETH_TRANSFER_GAS_UNITS;
    address weth = WETH;
    for (uint256 i = 0; i < numSells; ) {
      uint256 startGasPerOrder = gasleft() + ((startGas - gasleft()) / numSells);
      (bool executionValid, uint256 execPrice) = IComplication(sells[i].execParams[0]).canExecMatchOrder(
        sells[i],
        buys[i],
        constructs[i]
      );
      require(executionValid, 'cannot execute');
      _matchOrders(
        sells[i],
        buys[i],
        constructs[i],
        startGasPerOrder,
        execPrice,
        protocolFeeBps,
        wethTransferGasUnits,
        weth
      );
      unchecked {
        ++i;
      }
    }
  }

  /**
   @notice Batch buys or sells orders with specific `1` NFTs. Transaction initiated by an end user.
   @param makerOrders The orders to fulfill
  */
  function takeMultipleOneOrders(OrderTypes.MakerOrder[] calldata makerOrders) external payable nonReentrant {
    uint256 numMakerOrders = makerOrders.length;
    uint256 totalPrice;
    address currency = makerOrders[0].execParams[1];
    bool isMakerSeller = makerOrders[0].isSellOrder;
    if (!isMakerSeller) {
      require(currency != address(0), 'offers only in ERC20');
    }
    for (uint256 i = 0; i < numMakerOrders; ) {
      bytes32 makerOrderHash = _hash(makerOrders[i]);
      require(isOrderValid(makerOrders[i], makerOrderHash), 'invalid maker order');
      bool isTimeValid = makerOrders[i].constraints[3] <= block.timestamp &&
        makerOrders[i].constraints[4] >= block.timestamp;
      require(isTimeValid, 'invalid time');
      require(currency == makerOrders[i].execParams[1], 'cannot mix currencies');
      require(isMakerSeller == makerOrders[i].isSellOrder, 'cannot mix order sides');
      uint256 execPrice = _getCurrentPrice(makerOrders[i]);
      totalPrice += execPrice;
      _execTakeOneOrder(makerOrderHash, makerOrders[i], isMakerSeller, execPrice);
      unchecked {
        ++i;
      }
    }
    // check to ensure that for ETH orders, enough ETH is sent
    // for non ETH orders, IERC20 safeTransferFrom will throw error if insufficient amount is sent
    if (isMakerSeller && currency == address(0)) {
      require(msg.value >= totalPrice, 'invalid total price');
    }
  }

  /**
   @notice Batch buys or sells orders where maker orders can have unspecified NFTs. Transaction initiated by an end user.
   @param makerOrders The orders to fulfill
   @param takerNfts The specific NFTs that the taker is willing to take that intersect with the higher order intent of the maker
   Example: If a makerOrder is 'buy any one of these 2 specific NFTs', then the takerNfts would be 'this one specific NFT'.
  */
  function takeOrders(OrderTypes.MakerOrder[] calldata makerOrders, OrderTypes.OrderItem[][] calldata takerNfts)
    external
    payable
    nonReentrant
  {
    uint256 ordersLength = makerOrders.length;
    require(ordersLength == takerNfts.length, 'mismatched lengths');
    uint256 totalPrice;
    address currency = makerOrders[0].execParams[1];
    bool isMakerSeller = makerOrders[0].isSellOrder;
    if (!isMakerSeller) {
      require(currency != address(0), 'offers only in ERC20');
    }
    for (uint256 i = 0; i < ordersLength; ) {
      require(currency == makerOrders[i].execParams[1], 'cannot mix currencies');
      require(isMakerSeller == makerOrders[i].isSellOrder, 'cannot mix order sides');
      uint256 execPrice = _getCurrentPrice(makerOrders[i]);
      totalPrice += execPrice;
      _takeOrders(makerOrders[i], takerNfts[i], execPrice);
      unchecked {
        ++i;
      }
    }
    // check to ensure that for ETH orders, enough ETH is sent
    // for non ETH orders, IERC20 safeTransferFrom will throw error if insufficient amount is sent
    if (isMakerSeller && currency == address(0)) {
      require(msg.value >= totalPrice, 'invalid total price');
    }
  }

  /**
   @notice Helper function (non exchange related) to send multiple NFTs in one go
   @param to The orders to fulfill
   @param items The specific NFTs to transfer
  */
  function transferMultipleNFTs(address to, OrderTypes.OrderItem[] calldata items) external nonReentrant {
    _transferMultipleNFTs(msg.sender, to, items);
  }

  /**
   * @notice Cancel all pending orders
   * @param minNonce minimum user nonce
   */
  function cancelAllOrders(uint256 minNonce) external {
    require(minNonce > userMinOrderNonce[msg.sender], 'nonce too low');
    require(minNonce < userMinOrderNonce[msg.sender] + 1000000, 'too many');
    userMinOrderNonce[msg.sender] = minNonce;
    emit CancelAllOrders(msg.sender, minNonce);
  }

  /**
   * @notice Cancel multiple orders
   * @param orderNonces array of order nonces
   */
  function cancelMultipleOrders(uint256[] calldata orderNonces) external {
    uint256 numNonces = orderNonces.length;
    require(numNonces > 0, 'cannot be empty');
    for (uint256 i = 0; i < numNonces; ) {
      require(orderNonces[i] >= userMinOrderNonce[msg.sender], 'nonce too low');
      require(!isUserOrderNonceExecutedOrCancelled[msg.sender][orderNonces[i]], 'nonce already executed or cancelled');
      isUserOrderNonceExecutedOrCancelled[msg.sender][orderNonces[i]] = true;
      unchecked {
        ++i;
      }
    }
    emit CancelMultipleOrders(msg.sender, orderNonces);
  }

  // ====================================================== VIEW FUNCTIONS ======================================================

  /**
   * @notice Check whether user order nonce is executed or cancelled
   * @param user address of user
   * @param nonce nonce of the order
   * @return whether nonce is valid
   */
  function isNonceValid(address user, uint256 nonce) external view returns (bool) {
    return !isUserOrderNonceExecutedOrCancelled[user][nonce] && nonce > userMinOrderNonce[user];
  }

  /**
   * @notice Check whether a user signed order has valid signature
   * @param order the order to verify
   * @return whether order has valid signature
   */
  function verifyOrderSig(OrderTypes.MakerOrder calldata order) external view returns (bool) {
    // Verify the validity of the signature
    (bytes32 r, bytes32 s, uint8 v) = abi.decode(order.sig, (bytes32, bytes32, uint8));
    return SignatureChecker.verify(_hash(order), order.signer, r, s, v, DOMAIN_SEPARATOR);
  }

  /**
   * @notice Checks whether orders are valid
   * @dev Checks whether currencies match, sides match, complications match and if each order is valid (see isOrderValid)
   * @param sellOrderHash hash of the sell order
   * @param buyOrderHash hash of the buy order
   * @param sell the sell order
   * @param buy the buy order
   * @return whether orders are valid
   */
  function verifyMatchOneToOneOrders(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy
  ) public view returns (bool) {
    bool currenciesMatch = sell.execParams[1] == buy.execParams[1] ||
      (sell.execParams[1] == address(0) && buy.execParams[1] == WETH);
    return (sell.isSellOrder &&
      !buy.isSellOrder &&
      sell.execParams[0] == buy.execParams[0] &&
      currenciesMatch &&
      isOrderValid(sell, sellOrderHash) &&
      isOrderValid(buy, buyOrderHash));
  }

  /**
   * @notice Checks whether orders are valid
   * @dev Checks whether currencies match, sides match, complications match and if each order is valid (see isOrderValid)
   * @param orderHash hash of the order
   * @param sell the sell order
   * @param buy the buy order
   * @return whether orders are valid
   */
  function verifyMatchOneToManyOrders(
    bytes32 orderHash,
    bool verifySellOrder,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy
  ) public view returns (bool) {
    bool currenciesMatch = sell.execParams[1] == buy.execParams[1] ||
      (sell.execParams[1] == address(0) && buy.execParams[1] == WETH);
    bool _orderValid;
    if (verifySellOrder) {
      _orderValid = isOrderValid(sell, orderHash);
    } else {
      _orderValid = isOrderValid(buy, orderHash);
    }
    return (sell.isSellOrder &&
      !buy.isSellOrder &&
      sell.execParams[0] == buy.execParams[0] &&
      currenciesMatch &&
      _orderValid);
  }

  /**
   * @notice Checks whether orders are valid
   * @dev Checks whether currencies match, sides match, complications match and if each order is valid (see isOrderValid)
          Also checks if the given complication can execute this order
   * @param sellOrderHash hash of the sell order
   * @param buyOrderHash hash of the buy order
   * @param sell the sell order
   * @param buy the buy order
   * @return whether orders are valid and the execution price
   */
  function verifyMatchOrders(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy
  ) public view returns (bool) {
    bool currenciesMatch = sell.execParams[1] == buy.execParams[1] ||
      (sell.execParams[1] == address(0) && buy.execParams[1] == WETH);
    return (sell.isSellOrder &&
      !buy.isSellOrder &&
      sell.execParams[0] == buy.execParams[0] &&
      currenciesMatch &&
      isOrderValid(sell, sellOrderHash) &&
      isOrderValid(buy, buyOrderHash));
  }

  /**
   * @notice Verifies the validity of the order
   * @dev checks whether order nonce was cancelled or already executed, 
          if signature is valid and if the complication and currency are valid
   * @param order the order
   * @param orderHash computed hash of the order
   */
  function isOrderValid(OrderTypes.MakerOrder calldata order, bytes32 orderHash) public view returns (bool) {
    bool orderExpired = isUserOrderNonceExecutedOrCancelled[order.signer][order.constraints[5]] ||
      order.constraints[5] < userMinOrderNonce[order.signer];
    // Verify the validity of the signature
    (bytes32 r, bytes32 s, uint8 v) = abi.decode(order.sig, (bytes32, bytes32, uint8));
    bool sigValid = SignatureChecker.verify(orderHash, order.signer, r, s, v, DOMAIN_SEPARATOR);
    if (
      orderExpired ||
      !sigValid ||
      order.signer == address(0) ||
      !_complications.contains(order.execParams[0]) ||
      !_currencies.contains(order.execParams[1])
    ) {
      return false;
    }
    return true;
  }

  /// @notice returns the number of complications supported by the exchange
  function numComplications() external view returns (uint256) {
    return _complications.length();
  }

  /// @notice returns the complication at the given index
  function getComplicationAt(uint256 index) external view returns (address) {
    return _complications.at(index);
  }

  /// @notice returns whether a given complication is valid
  function isValidComplication(address complication) external view returns (bool) {
    return _complications.contains(complication);
  }

  /// @notice returns the number of currencies supported by the exchange
  function numCurrencies() external view returns (uint256) {
    return _currencies.length();
  }

  /// @notice returns the currency at the given index
  function getCurrencyAt(uint256 index) external view returns (address) {
    return _currencies.at(index);
  }

  /// @notice returns whether a given currency is valid
  function isValidCurrency(address currency) external view returns (bool) {
    return _currencies.contains(currency);
  }

  // ====================================================== INTERNAL FUNCTIONS ================================================

  /**
   * @notice Internal helper function to match orders one to one
   * @param makerOrder1 first order
   * @param makerOrder2 second maker order
   * @param startGasPerOrder start gas when this order started execution
   * @param execPrice execution price
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth WETH address
   */
  function _matchOneToOneOrders(
    OrderTypes.MakerOrder calldata makerOrder1,
    OrderTypes.MakerOrder calldata makerOrder2,
    uint256 startGasPerOrder,
    uint256 execPrice,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    OrderTypes.MakerOrder calldata sell = makerOrder1.isSellOrder ? makerOrder1 : makerOrder2;
    OrderTypes.MakerOrder calldata buy = makerOrder1.isSellOrder ? makerOrder2 : makerOrder1;
    bytes32 sellOrderHash = _hash(sell);
    bytes32 buyOrderHash = _hash(buy);
    require(verifyMatchOneToOneOrders(sellOrderHash, buyOrderHash, sell, buy), 'order not verified');
    _execMatchOneToOneOrders(
      sellOrderHash,
      buyOrderHash,
      sell,
      buy,
      startGasPerOrder,
      execPrice,
      protocolFeeBps,
      wethTransferGasUnits,
      weth
    );
  }

  /**
   * @notice Internal helper function to match one maker sell order to many maker buys
   * @param sellOrderHash sell order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param startGasPerOrder start gas when this order started execution
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth WETH address
   */
  function _matchOneMakerSellToManyMakerBuys(
    bytes32 sellOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    uint256 startGasPerOrder,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    bytes32 buyOrderHash = _hash(buy);
    require(verifyMatchOneToManyOrders(buyOrderHash, false, sell, buy), 'order not verified');
    _execMatchOneMakerSellToManyMakerBuys(
      sellOrderHash,
      buyOrderHash,
      sell,
      buy,
      startGasPerOrder,
      _getCurrentPrice(buy),
      protocolFeeBps,
      wethTransferGasUnits,
      weth
    );
  }

  /**
   * @notice Internal helper function to match one maker buy order to many maker sells
   * @param buyOrderHash buy order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param protocolFeeBps exchange fee
   */
  function _matchOneMakerBuyToManyMakerSells(
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    uint16 protocolFeeBps
  ) internal returns (uint256) {
    bytes32 sellOrderHash = _hash(sell);
    require(verifyMatchOneToManyOrders(sellOrderHash, true, sell, buy), 'order not verified');
    return
      _execMatchOneMakerBuyToManyMakerSells(
        sellOrderHash,
        buyOrderHash,
        sell,
        buy,
        _getCurrentPrice(sell),
        protocolFeeBps
      );
  }

  /**
   * @notice Internal helper function to match orders specified via a higher order intent
   * @param sell the sell order
   * @param buy the buy order
   * @param constructedNfts the nfts constructed by an off chain matching that are guaranteed to intersect
            with the user specified signed intents (orders)
   * @param startGasPerOrder start gas when this order started execution
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth WETH address
   */
  function _matchOrders(
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    OrderTypes.OrderItem[] calldata constructedNfts,
    uint256 startGasPerOrder,
    uint256 execPrice,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    bytes32 sellOrderHash = _hash(sell);
    bytes32 buyOrderHash = _hash(buy);
    require(verifyMatchOrders(sellOrderHash, buyOrderHash, sell, buy), 'order not verified');
    _execMatchOrders(
      sellOrderHash,
      buyOrderHash,
      sell,
      buy,
      constructedNfts,
      startGasPerOrder,
      execPrice,
      protocolFeeBps,
      wethTransferGasUnits,
      weth
    );
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers for match one to one orders
   * @dev Updates order nonce states, does asset transfers and emits events. Also refunds gas expenditure to the contract
   * @param sellOrderHash sell order hash
   * @param buyOrderHash buy order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param startGasPerOrder start gas when this order started execution
   * @param execPrice execution price
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth WETH address
   */
  function _execMatchOneToOneOrders(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    uint256 startGasPerOrder,
    uint256 execPrice,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    isUserOrderNonceExecutedOrCancelled[sell.signer][sell.constraints[5]] = true;
    isUserOrderNonceExecutedOrCancelled[buy.signer][buy.constraints[5]] = true;
    uint256 protocolFee = (protocolFeeBps * execPrice) / 10000;
    uint256 remainingAmount = execPrice - protocolFee;
    _transferMultipleNFTs(sell.signer, buy.signer, sell.nfts);
    // transfer final amount (post-fees) to seller
    IERC20(buy.execParams[1]).safeTransferFrom(buy.signer, sell.signer, remainingAmount);
    _emitMatchEvent(
      sellOrderHash,
      buyOrderHash,
      sell.signer,
      buy.signer,
      buy.execParams[0],
      buy.execParams[1],
      execPrice
    );
    uint256 gasCost = (startGasPerOrder - gasleft() + wethTransferGasUnits) * tx.gasprice;
    // if the execution currency is weth, we can send the protocol fee and gas cost in one transfer to save gas
    // else we need to send the protocol fee separately in the execution currency
    if (buy.execParams[1] == weth) {
      IERC20(weth).safeTransferFrom(buy.signer, address(this), protocolFee + gasCost);
    } else {
      IERC20(buy.execParams[1]).safeTransferFrom(buy.signer, address(this), protocolFee);
      IERC20(weth).safeTransferFrom(buy.signer, address(this), gasCost);
    }
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers for match one sell to many buy orders
   * @dev Updates order nonce states, does asset transfers and emits events. Also refunds gas expenditure to the contract
   * @param sellOrderHash sell order hash
   * @param buyOrderHash buy order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param startGasPerOrder start gas when this order started execution
   * @param execPrice execution price
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth WETH address
   */
  function _execMatchOneMakerSellToManyMakerBuys(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    uint256 startGasPerOrder,
    uint256 execPrice,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    isUserOrderNonceExecutedOrCancelled[buy.signer][buy.constraints[5]] = true;
    uint256 protocolFee = (protocolFeeBps * execPrice) / 10000;
    uint256 remainingAmount = execPrice - protocolFee;
    _execMatchOneToManyOrders(sell.signer, buy.signer, buy.nfts, buy.execParams[1], remainingAmount);
    _emitMatchEvent(
      sellOrderHash,
      buyOrderHash,
      sell.signer,
      buy.signer,
      buy.execParams[0],
      buy.execParams[1],
      execPrice
    );
    uint256 gasCost = (startGasPerOrder - gasleft() + wethTransferGasUnits) * tx.gasprice;
    // if the execution currency is weth, we can send the protocol fee and gas cost in one transfer to save gas
    // else we need to send the protocol fee separately in the execution currency
    if (buy.execParams[1] == weth) {
      IERC20(weth).safeTransferFrom(buy.signer, address(this), protocolFee + gasCost);
    } else {
      IERC20(buy.execParams[1]).safeTransferFrom(buy.signer, address(this), protocolFee);
      IERC20(weth).safeTransferFrom(buy.signer, address(this), gasCost);
    }
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers for match one buy to many sell orders
   * @dev Updates order nonce states, does asset transfers and emits events. Gas expenditure refund is done in the caller
          since it does not need to be done in a loop
   * @param sellOrderHash sell order hash
   * @param buyOrderHash buy order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param execPrice execution price
   * @param protocolFeeBps exchange fee
   * @return the protocolFee so that the buyer can pay the protocol fee and gas cost in one go
   */
  function _execMatchOneMakerBuyToManyMakerSells(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    uint256 execPrice,
    uint16 protocolFeeBps
  ) internal returns (uint256) {
    isUserOrderNonceExecutedOrCancelled[sell.signer][sell.constraints[5]] = true;
    uint256 protocolFee = (protocolFeeBps * execPrice) / 10000;
    uint256 remainingAmount = execPrice - protocolFee;
    _execMatchOneToManyOrders(sell.signer, buy.signer, sell.nfts, buy.execParams[1], remainingAmount);
    _emitMatchEvent(
      sellOrderHash,
      buyOrderHash,
      sell.signer,
      buy.signer,
      buy.execParams[0],
      buy.execParams[1],
      execPrice
    );
    return protocolFee;
  }

  /// @dev this helper purely exists to help reduce contract size a bit and avoid any stack too deep errors
  function _execMatchOneToManyOrders(
    address seller,
    address buyer,
    OrderTypes.OrderItem[] calldata constructedNfts,
    address currency,
    uint256 amount
  ) internal {
    _transferMultipleNFTs(seller, buyer, constructedNfts);
    // transfer final amount (post-fees) to seller
    IERC20(currency).safeTransferFrom(buyer, seller, amount);
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers for match orders
   * @dev Updates order nonce states, does asset transfers, emits events and does gas refunds
   * @param sellOrderHash sell order hash
   * @param buyOrderHash buy order hash
   * @param sell the sell order
   * @param buy the buy order
   * @param constructedNfts the constructed nfts
   * @param startGasPerOrder gas when this order started execution
   * @param execPrice execution price
   * @param protocolFeeBps exchange fee
   * @param wethTransferGasUnits gas units that a WETH transfer will use
   * @param weth weth address
   */
  function _execMatchOrders(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    OrderTypes.MakerOrder calldata sell,
    OrderTypes.MakerOrder calldata buy,
    OrderTypes.OrderItem[] calldata constructedNfts,
    uint256 startGasPerOrder,
    uint256 execPrice,
    uint16 protocolFeeBps,
    uint32 wethTransferGasUnits,
    address weth
  ) internal {
    uint256 protocolFee = (protocolFeeBps * execPrice) / 10000;
    uint256 remainingAmount = execPrice - protocolFee;
    _execMatchOrder(
      sell.signer,
      buy.signer,
      sell.constraints[5],
      buy.constraints[5],
      constructedNfts,
      buy.execParams[1],
      remainingAmount
    );
    _emitMatchEvent(
      sellOrderHash,
      buyOrderHash,
      sell.signer,
      buy.signer,
      buy.execParams[0],
      buy.execParams[1],
      execPrice
    );
    uint256 gasCost = (startGasPerOrder - gasleft() + wethTransferGasUnits) * tx.gasprice;
    // if the execution currency is weth, we can send the protocol fee and gas cost in one transfer to save gas
    // else we need to send the protocol fee separately in the execution currency
    if (buy.execParams[1] == weth) {
      IERC20(weth).safeTransferFrom(buy.signer, address(this), protocolFee + gasCost);
    } else {
      IERC20(buy.execParams[1]).safeTransferFrom(buy.signer, address(this), protocolFee);
      IERC20(weth).safeTransferFrom(buy.signer, address(this), gasCost);
    }
  }

  /// @dev this helper purely exists to help reduce contract size a bit and avoid any stack too deep errors
  function _execMatchOrder(
    address seller,
    address buyer,
    uint256 sellNonce,
    uint256 buyNonce,
    OrderTypes.OrderItem[] calldata constructedNfts,
    address currency,
    uint256 amount
  ) internal {
    // Update order execution status to true (prevents replay)
    isUserOrderNonceExecutedOrCancelled[seller][sellNonce] = true;
    isUserOrderNonceExecutedOrCancelled[buyer][buyNonce] = true;
    _transferMultipleNFTs(seller, buyer, constructedNfts);
    // transfer final amount (post-fees) to seller
    IERC20(currency).safeTransferFrom(buyer, seller, amount);
  }

  function _emitMatchEvent(
    bytes32 sellOrderHash,
    bytes32 buyOrderHash,
    address seller,
    address buyer,
    address complication,
    address currency,
    uint256 amount
  ) internal {
    emit MatchOrderFulfilled(sellOrderHash, buyOrderHash, seller, buyer, complication, currency, amount);
  }

  /**
   * @notice Internal helper function to take orders
   * @dev verifies whether order can be executed
   * @param makerOrder the maker order
   * @param takerItems nfts to be transferred
   * @param execPrice execution price
   */
  function _takeOrders(
    OrderTypes.MakerOrder calldata makerOrder,
    OrderTypes.OrderItem[] calldata takerItems,
    uint256 execPrice
  ) internal {
    bytes32 makerOrderHash = _hash(makerOrder);
    bool makerOrderValid = isOrderValid(makerOrder, makerOrderHash);
    bool executionValid = IComplication(makerOrder.execParams[0]).canExecTakeOrder(makerOrder, takerItems);
    require(makerOrderValid && executionValid, 'order not verified');
    _execTakeOrders(makerOrderHash, makerOrder, takerItems, makerOrder.isSellOrder, execPrice);
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers 
              for take orders specifying a higher order intent
   * @dev Updates order nonce state, does asset transfers and emits events
   * @param makerOrderHash maker order hash
   * @param makerOrder the maker order
   * @param takerItems nfts to be transferred
   * @param isMakerSeller is the maker order a sell order
   * @param execPrice execution price
   */
  function _execTakeOrders(
    bytes32 makerOrderHash,
    OrderTypes.MakerOrder calldata makerOrder,
    OrderTypes.OrderItem[] calldata takerItems,
    bool isMakerSeller,
    uint256 execPrice
  ) internal {
    isUserOrderNonceExecutedOrCancelled[makerOrder.signer][makerOrder.constraints[5]] = true;
    if (isMakerSeller) {
      _transferNFTsAndFees(makerOrder.signer, msg.sender, takerItems, execPrice, makerOrder.execParams[1]);
      _emitTakerEvent(makerOrderHash, makerOrder.signer, msg.sender, makerOrder, execPrice);
    } else {
      _transferNFTsAndFees(msg.sender, makerOrder.signer, takerItems, execPrice, makerOrder.execParams[1]);
      _emitTakerEvent(makerOrderHash, msg.sender, makerOrder.signer, makerOrder, execPrice);
    }
  }

  /**
   * @notice Internal helper function that executes contract state changes and does asset transfers 
              for simple take orders
   * @dev Updates order nonce state, does asset transfers and emits events
   * @param makerOrderHash maker order hash
   * @param makerOrder the maker order
   * @param isMakerSeller is the maker order a sell order
   * @param execPrice execution price
   */
  function _execTakeOneOrder(
    bytes32 makerOrderHash,
    OrderTypes.MakerOrder calldata makerOrder,
    bool isMakerSeller,
    uint256 execPrice
  ) internal {
    isUserOrderNonceExecutedOrCancelled[makerOrder.signer][makerOrder.constraints[5]] = true;
    if (isMakerSeller) {
      _transferNFTsAndFees(makerOrder.signer, msg.sender, makerOrder.nfts, execPrice, makerOrder.execParams[1]);
      _emitTakerEvent(makerOrderHash, makerOrder.signer, msg.sender, makerOrder, execPrice);
    } else {
      _transferNFTsAndFees(msg.sender, makerOrder.signer, makerOrder.nfts, execPrice, makerOrder.execParams[1]);
      _emitTakerEvent(makerOrderHash, msg.sender, makerOrder.signer, makerOrder, execPrice);
    }
  }

  function _emitTakerEvent(
    bytes32 orderHash,
    address seller,
    address buyer,
    OrderTypes.MakerOrder calldata order,
    uint256 amount
  ) internal {
    emit TakeOrderFulfilled(orderHash, seller, buyer, order.execParams[0], order.execParams[1], amount);
  }

  /**
   * @notice Transfers NFTs and fees
   * @param seller the seller
   * @param buyer the buyer
   * @param nfts nfts to transfer
   * @param amount amount to transfer
   * @param currency currency of the transfer
   */
  function _transferNFTsAndFees(
    address seller,
    address buyer,
    OrderTypes.OrderItem[] calldata nfts,
    uint256 amount,
    address currency
  ) internal {
    // transfer NFTs
    _transferMultipleNFTs(seller, buyer, nfts);
    // transfer fees
    _transferFees(seller, buyer, amount, currency);
  }

  /**
   * @notice Transfers multiple NFTs in a loop and ERC1155s in a batch
   * @param from the from address
   * @param to the to address
   * @param nfts nfts to transfer
   */
  function _transferMultipleNFTs(
    address from,
    address to,
    OrderTypes.OrderItem[] calldata nfts
  ) internal {
    uint256 numNfts = nfts.length;
    for (uint256 i = 0; i < numNfts; ) {
      _transferNFTs(from, to, nfts[i]);
      unchecked {
        ++i;
      }
    }
  }

  /**
   * @notice Transfer NFTs
   * @param from address of the sender
   * @param to address of the recipient
   * @param item item to transfer
   */
  function _transferNFTs(
    address from,
    address to,
    OrderTypes.OrderItem calldata item
  ) internal {
    if (IERC165(item.collection).supportsInterface(0x80ac58cd)) {
      _transferERC721s(from, to, item);
    } else if (IERC165(item.collection).supportsInterface(0xd9b67a26)) {
      _transferERC1155s(from, to, item);
    }
  }

  /**
   * @notice Transfer ERC721s
   * @param from address of the sender
   * @param to address of the recipient
   * @param item item to transfer
   */
  function _transferERC721s(
    address from,
    address to,
    OrderTypes.OrderItem calldata item
  ) internal {
    uint256 numTokens = item.tokens.length;
    for (uint256 i = 0; i < numTokens; ) {
      IERC721(item.collection).safeTransferFrom(from, to, item.tokens[i].tokenId);
      unchecked {
        ++i;
      }
    }
  }

  /**
   * @notice Transfer ERC1155s
   * @dev uses the ERC1155 batchTransfer function for efficient transfers
   * @param from address of the sender
   * @param to address of the recipient
   * @param item item to transfer
   */
  function _transferERC1155s(
    address from,
    address to,
    OrderTypes.OrderItem calldata item
  ) internal {
    uint256 numNfts = item.tokens.length;
    uint256[] memory tokenIdsArr = new uint256[](numNfts);
    uint256[] memory numTokensPerTokenIdArr = new uint256[](numNfts);
    for (uint256 i = 0; i < numNfts; ) {
      tokenIdsArr[i] = item.tokens[i].tokenId;
      numTokensPerTokenIdArr[i] = item.tokens[i].numTokens;
      unchecked {
        ++i;
      }
    }
    IERC1155(item.collection).safeBatchTransferFrom(from, to, tokenIdsArr, numTokensPerTokenIdArr, '0x0');
  }

  /**
   * @notice Transfer fees. Fees are always transferred from buyer to the seller and the exchange although seller is 
            the one that actually 'pays' the fees
   * @dev if the currency ETH, no additional transfer is needed to pay exchange fees since the contract is 'payable'
   * @param seller the seller
   * @param buyer the buyer
   * @param amount amount to transfer
   * @param currency currency of the transfer
   */
  function _transferFees(
    address seller,
    address buyer,
    uint256 amount,
    address currency
  ) internal {
    // protocol fee
    uint256 protocolFee = (PROTOCOL_FEE_BPS * amount) / 10000;
    uint256 remainingAmount = amount - protocolFee;
    // ETH
    if (currency == address(0)) {
      // transfer amount to seller
      (bool sent, ) = seller.call{value: remainingAmount}('');
      require(sent, 'failed to send ether to seller');
    } else {
      // transfer final amount (post-fees) to seller
      IERC20(currency).safeTransferFrom(buyer, seller, remainingAmount);
      // send fee to protocol
      IERC20(currency).safeTransferFrom(buyer, address(this), protocolFee);
    }
  }

  // =================================================== UTILS ==================================================================

  /// @dev Gets current order price for orders that vary in price over time (dutch and reverse dutch auctions)
  function _getCurrentPrice(OrderTypes.MakerOrder calldata order) internal view returns (uint256) {
    (uint256 startPrice, uint256 endPrice) = (order.constraints[1], order.constraints[2]);
    uint256 duration = order.constraints[4] - order.constraints[3];
    uint256 priceDiff = startPrice > endPrice ? startPrice - endPrice : endPrice - startPrice;
    if (priceDiff == 0 || duration == 0) {
      return startPrice;
    }
    uint256 elapsedTime = block.timestamp - order.constraints[3];
    uint256 PRECISION = 10**4; // precision for division; similar to bps
    uint256 portionBps = elapsedTime > duration ? PRECISION : ((elapsedTime * PRECISION) / duration);
    priceDiff = (priceDiff * portionBps) / PRECISION;
    return startPrice > endPrice ? startPrice - priceDiff : startPrice + priceDiff;
  }

  /// @dev hashes the given order with the help of _nftsHash and _tokensHash
  function _hash(OrderTypes.MakerOrder calldata order) internal pure returns (bytes32) {
    // keccak256('Order(bool isSellOrder,address signer,uint256[] constraints,OrderItem[] nfts,address[] execParams,bytes extraParams)OrderItem(address collection,TokenInfo[] tokens)TokenInfo(uint256 tokenId,uint256 numTokens)')
    bytes32 ORDER_HASH = 0x7bcfb5a29031e6b8d34ca1a14dd0a1f5cb11b20f755bb2a31ee3c4b143477e4a;
    return
      keccak256(
        abi.encode(
          ORDER_HASH,
          order.isSellOrder,
          order.signer,
          keccak256(abi.encodePacked(order.constraints)),
          _nftsHash(order.nfts),
          keccak256(abi.encodePacked(order.execParams)),
          keccak256(order.extraParams)
        )
      );
  }

  function _nftsHash(OrderTypes.OrderItem[] calldata nfts) internal pure returns (bytes32) {
    // keccak256('OrderItem(address collection,TokenInfo[] tokens)TokenInfo(uint256 tokenId,uint256 numTokens)')
    bytes32 ORDER_ITEM_HASH = 0xf73f37e9f570369ceaab59cef16249ae1c0ad1afd592d656afac0be6f63b87e0;
    uint256 numNfts = nfts.length;
    bytes32[] memory hashes = new bytes32[](numNfts);
    for (uint256 i = 0; i < numNfts; ) {
      bytes32 hash = keccak256(abi.encode(ORDER_ITEM_HASH, nfts[i].collection, _tokensHash(nfts[i].tokens)));
      hashes[i] = hash;
      unchecked {
        ++i;
      }
    }
    bytes32 nftsHash = keccak256(abi.encodePacked(hashes));
    return nftsHash;
  }

  function _tokensHash(OrderTypes.TokenInfo[] calldata tokens) internal pure returns (bytes32) {
    // keccak256('TokenInfo(uint256 tokenId,uint256 numTokens)')
    bytes32 TOKEN_INFO_HASH = 0x88f0bd19d14f8b5d22c0605a15d9fffc285ebc8c86fb21139456d305982906f1;
    uint256 numTokens = tokens.length;
    bytes32[] memory hashes = new bytes32[](numTokens);
    for (uint256 i = 0; i < numTokens; ) {
      bytes32 hash = keccak256(abi.encode(TOKEN_INFO_HASH, tokens[i].tokenId, tokens[i].numTokens));
      hashes[i] = hash;
      unchecked {
        ++i;
      }
    }
    bytes32 tokensHash = keccak256(abi.encodePacked(hashes));
    return tokensHash;
  }

  // ====================================================== ADMIN FUNCTIONS ======================================================

  /// @dev used for rescuing exchange fees paid to the contract in tokens
  function rescueTokens(
    address destination,
    address currency,
    uint256 amount
  ) external onlyOwner {
    IERC20(currency).safeTransfer(destination, amount);
  }

  /// @dev used for rescuing exchange fees paid to the contract in ETH
  function rescueETH(address destination) external payable onlyOwner {
    (bool sent, ) = destination.call{value: msg.value}('');
    require(sent, 'failed');
  }

  /// @dev adds a new transaction currency to the exchange
  function addCurrency(address _currency) external onlyOwner {
    _currencies.add(_currency);
  }

  /// @dev adds a new complication to the exchange
  function addComplication(address _complication) external onlyOwner {
    _complications.add(_complication);
  }

  /// @dev removes a transaction currency from the exchange
  function removeCurrency(address _currency) external onlyOwner {
    _currencies.remove(_currency);
  }

  /// @dev removes a complication from the exchange
  function removeComplication(address _complication) external onlyOwner {
    _complications.remove(_complication);
  }

  /// @dev updates auto snipe executor
  function updateMatchExecutor(address _matchExecutor) external onlyOwner {
    MATCH_EXECUTOR = _matchExecutor;
  }

  /// @dev updates the gas units required for WETH transfers
  function updateWethTranferGas(uint32 _wethTransferGasUnits) external onlyOwner {
    WETH_TRANSFER_GAS_UNITS = _wethTransferGasUnits;
    emit NewWethTransferGasUnits(_wethTransferGasUnits);
  }

  /// @dev updates exchange fees
  function setProtocolFee(uint16 _protocolFeeBps) external onlyOwner {
    PROTOCOL_FEE_BPS = _protocolFeeBps;
    emit NewProtocolFee(_protocolFeeBps);
  }
}
