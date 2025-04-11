// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { EnumerableMap } from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { LibString } from "solady/utils/LibString.sol";

import { ICred } from "./interfaces/ICred.sol";
import { IBondingCurve } from "./interfaces/IBondingCurve.sol";
import { IPhiRewards } from "./interfaces/IPhiRewards.sol";

/// @title Cred
contract Cred is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ICred {
    /*//////////////////////////////////////////////////////////////
                                 USING
    //////////////////////////////////////////////////////////////*/
    using SafeTransferLib for address;
    using LibString for string;
    using LibString for uint256;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    uint16 private constant MAX_SUPPLY = 999;

    uint256 public constant SHARE_LOCK_PERIOD = 10 minutes;
    uint256 private immutable RATIO_BASE = 10_000;
    uint256 private immutable MAX_ROYALTY_RANGE = 5000;
    uint256 public credIdCounter;
    uint256 public protocolFeePercent;
    uint256 private locked;

    address public phiSignerAddress;
    address public protocolFeeDestination;
    address public phiRewardsAddress;

    mapping(uint256 credId => PhiCred creds) private creds;
    mapping(uint256 credId => bytes32 rood) public credsMerkeRoot;
    mapping(uint256 credId => EnumerableMap.AddressToUintMap balance) private shareBalance;
    mapping(uint256 credId => mapping(address curator => uint256 timestamp)) public lastTradeTimestamp;

    mapping(address priceCurve => bool enable) public curatePriceWhitelist;
    mapping(address curator => uint256[] credIds) private _credIdsPerAddress;
    mapping(address curator => mapping(uint256 credId => bool exist)) private _credIdExistsPerAddress;
    mapping(address curator => uint256 arrayLength) private _credIdsPerAddressArrLength;
    mapping(address curator => mapping(uint256 credId => uint256 index)) private _credIdsPerAddressCredIdIndex;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    // solhint-disable-next-line func-visibility
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    /// @param ownerAddress_ The address of the contract owner.
    /// @param protocolFeeDestination_ The address to receive protocol fees.
    /// @param protocolFeePercent_ The percentage of protocol fees. (100 = 1%)
    /// @param bondingCurveAddress_ The address of the CuratePrice contract.
    function initialize(
        address phiSignerAddress_,
        address ownerAddress_,
        address protocolFeeDestination_,
        uint256 protocolFeePercent_,
        address bondingCurveAddress_,
        address phiRewardsAddress_
    )
        external
        initializer
    {
        __Ownable_init(ownerAddress_);
        __Pausable_init();
        __UUPSUpgradeable_init();
        if (protocolFeeDestination_ == address(0)) {
            revert InvalidAddressZero();
        }
        locked = 1;
        credIdCounter = 1;
        phiSignerAddress = phiSignerAddress_;
        protocolFeeDestination = protocolFeeDestination_;
        phiRewardsAddress = phiRewardsAddress_;
        protocolFeePercent = protocolFeePercent_;
        curatePriceWhitelist[bondingCurveAddress_] = true;
    }

    function version() public pure returns (uint256) {
        return 1;
    }

    /// @notice Pauses the contract.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unPause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier nonReentrant() virtual {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    modifier nonZeroAddress(address address_) {
        if (address_ == address(0)) revert InvalidAddressZero();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  SET
    //////////////////////////////////////////////////////////////*/
    /// @notice Sets the claim signer address.
    /// @param phiSignerAddress_ The new claim signer address.
    function setPhiSignerAddress(address phiSignerAddress_) external nonZeroAddress(phiSignerAddress_) onlyOwner {
        phiSignerAddress = phiSignerAddress_;
        emit PhiSignerAddressSet(phiSignerAddress_);
    }

    /// @notice Sets the protocol fee destination.
    /// @param protocolFeeDestination_ The new protocol fee destination.
    function setProtocolFeeDestination(address protocolFeeDestination_)
        external
        nonZeroAddress(protocolFeeDestination_)
        onlyOwner
    {
        protocolFeeDestination = protocolFeeDestination_;
        emit ProtocolFeeDestinationChanged(_msgSender(), protocolFeeDestination_);
    }

    /// @notice Sets the protocol fee percentage.
    /// @param protocolFeePercent_ The new protocol fee percentage.
    function setProtocolFeePercent(uint256 protocolFeePercent_) external onlyOwner {
        protocolFeePercent = protocolFeePercent_;
        emit ProtocolFeePercentChanged(_msgSender(), protocolFeePercent_);
    }

    /// @notice Sets the PhiRewards contract address.
    /// @param phiRewardsAddress_ The new PhiRewards contract address.
    function setPhiRewardsAddress(address phiRewardsAddress_) external nonZeroAddress(phiRewardsAddress_) onlyOwner {
        phiRewardsAddress = phiRewardsAddress_;
        emit PhiRewardsAddressSet(phiRewardsAddress_);
    }

    /*//////////////////////////////////////////////////////////////
                             Whitelist
    //////////////////////////////////////////////////////////////*/
    /// @notice Adds an address to the whitelist.
    function addToWhitelist(address address_) external onlyOwner {
        curatePriceWhitelist[address_] = true;
        emit AddedToWhitelist(_msgSender(), address_);
    }

    /// @notice Removes an address from the whitelist.
    /// @param address_ The address to remove from the whitelist.
    function removeFromWhitelist(address address_) external onlyOwner {
        curatePriceWhitelist[address_] = false;
        emit RemovedFromWhitelist(_msgSender(), address_);
    }

    /*//////////////////////////////////////////////////////////////
                           Buy and Sell
    //////////////////////////////////////////////////////////////*/
    function buyShareCred(uint256 credId_, uint256 amount_, uint256 maxPrice_) public payable {
        _handleTrade(credId_, amount_, true, _msgSender(), maxPrice_);
    }

    function sellShareCred(uint256 credId_, uint256 amount_, uint256 minPrice_) public {
        _handleTrade(credId_, amount_, false, _msgSender(), minPrice_);
    }

    function buyShareCredFor(uint256 credId_, uint256 amount_, address curator_, uint256 maxPrice_) public payable {
        if (curator_ == address(0)) revert InvalidAddressZero();
        _handleTrade(credId_, amount_, true, curator_, maxPrice_);
    }

    function batchBuyShareCred(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        uint256[] calldata maxPrices_,
        address curator_
    )
        public
        payable
    {
        (uint256 totalCost, uint256[] memory prices, uint256[] memory protocolFees, uint256[] memory creatorFees) =
            _validateAndCalculateBatch(credIds_, amounts_, maxPrices_, true);

        if (totalCost > msg.value) revert InsufficientBatchPayment();

        _executeBatchBuy(credIds_, amounts_, curator_, prices, protocolFees, creatorFees);

        uint256 refund = msg.value - totalCost;
        if (refund > 0) {
            _msgSender().safeTransferETH(refund);
        }
    }

    function batchSellShareCred(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        uint256[] calldata minPrices_
    )
        public
    {
        (uint256 totalPayout, uint256[] memory prices, uint256[] memory protocolFees, uint256[] memory creatorFees) =
            _validateAndCalculateBatch(credIds_, amounts_, minPrices_, false);

        _executeBatchSell(credIds_, amounts_, prices, protocolFees, creatorFees);

        _msgSender().safeTransferETH(totalPayout);
    }

    /*//////////////////////////////////////////////////////////////
                                  CRED 
    //////////////////////////////////////////////////////////////*/
    /// @notice Creates a new cred.
    function createCred(
        address creator_,
        bytes calldata signedData_,
        bytes calldata signature_,
        uint16 buyShareRoyalty_,
        uint16 sellShareRoyalty_
    )
        public
        payable
        whenNotPaused
    {
        if (_recoverSigner(keccak256(signedData_), signature_) != phiSignerAddress) revert AddressNotSigned();
        (
            uint256 expiresIn,
            address sender,
            ,
            address bondingCurve,
            string memory credURL,
            string memory credType,
            string memory verificationType,
            bytes32 merkleRoot_
        ) = abi.decode(signedData_, (uint256, address, uint256, address, string, string, string, bytes32));
        if (expiresIn <= block.timestamp) revert SignatureExpired();

        if (sender != _msgSender()) revert Unauthorized();

        if (!curatePriceWhitelist[bondingCurve]) revert Unauthorized();

        if (!credType.eq("BASIC") && !credType.eq("ADVANCED")) {
            revert InvalidCredType();
        }
        if (verificationType.eq("MERKLE") && merkleRoot_ == bytes32(0)) {
            revert InvalidMerkleRoot();
        }
        if (!verificationType.eq("MERKLE") && !verificationType.eq("SIGNATURE")) {
            revert InvalidVerificationType();
        }
        if (buyShareRoyalty_ > MAX_ROYALTY_RANGE || sellShareRoyalty_ > MAX_ROYALTY_RANGE) {
            revert InvalidRoyaltyRange();
        }

        uint256 credId = _createCredInternal(
            creator_, credURL, credType, verificationType, bondingCurve, buyShareRoyalty_, sellShareRoyalty_
        );
        if (verificationType.eq("MERKLE")) {
            credsMerkeRoot[credId] = merkleRoot_;
            emit MerkleTreeSetUp(_msgSender(), credId, merkleRoot_);
        }
    }

    /// @notice Updates the URL of a cred.
    function updateCred(
        bytes calldata signedData_,
        bytes calldata signature_,
        uint16 buyShareRoyalty_,
        uint16 sellShareRoyalty_
    )
        external
        whenNotPaused
    {
        if (_recoverSigner(keccak256(signedData_), signature_) != phiSignerAddress) revert AddressNotSigned();
        (uint256 expiresIn_, address sender,, uint256 credId, string memory credURL) =
            abi.decode(signedData_, (uint256, address, uint256, uint256, string));
        if (expiresIn_ <= block.timestamp) revert SignatureExpired();

        if (sender != _msgSender()) revert Unauthorized();

        if (creds[credId].creator != _msgSender()) revert Unauthorized();
        if (buyShareRoyalty_ > MAX_ROYALTY_RANGE || sellShareRoyalty_ > MAX_ROYALTY_RANGE) {
            revert InvalidRoyaltyRange();
        }

        creds[credId].credURL = credURL;
        creds[credId].updatedAt = uint40(block.timestamp);
        creds[credId].buyShareRoyalty = buyShareRoyalty_;
        creds[credId].sellShareRoyalty = sellShareRoyalty_;

        emit CredUpdated(_msgSender(), credId, credURL, buyShareRoyalty_, sellShareRoyalty_);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Gets the price of a cred for a given amount.
    /// @param credId_ The ID of the cred.
    /// @param amount_ The amount to get the price for.
    /// @return The price of the cred for the given amount.
    function getCredBuyPrice(uint256 credId_, uint256 amount_) external view returns (uint256) {
        return IBondingCurve(creds[credId_].bondingCurve).getPrice(creds[credId_].currentSupply, amount_);
    }

    function getCredSellPrice(uint256 credId_, uint256 amount_) external view returns (uint256) {
        return IBondingCurve(creds[credId_].bondingCurve).getPrice(creds[credId_].currentSupply - amount_, amount_);
    }

    function getCredBuyPriceWithFee(uint256 credId_, uint256 amount_) external view returns (uint256) {
        return IBondingCurve(creds[credId_].bondingCurve).getBuyPriceAfterFee(
            credId_, creds[credId_].currentSupply, amount_
        );
    }

    function getCredSellPriceWithFee(uint256 credId_, uint256 amount_) external view returns (uint256) {
        return IBondingCurve(creds[credId_].bondingCurve).getSellPriceAfterFee(
            credId_, creds[credId_].currentSupply, amount_
        );
    }

    /// @notice Gets the total buy price for a batch of creds and amounts.
    /// @param credIds_ The IDs of the creds.
    /// @param amounts_ The amounts corresponding to each cred.
    /// @return The total buy price for the batch.
    function getBatchBuyPrice(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_
    )
        external
        view
        returns (uint256)
    {
        uint256 total;
        for (uint256 i = 0; i < credIds_.length; ++i) {
            total += IBondingCurve(creds[credIds_[i]].bondingCurve).getBuyPriceAfterFee(
                credIds_[i], creds[credIds_[i]].currentSupply, amounts_[i]
            );
        }
        return total;
    }

    /// @notice Gets the total sell price for a batch of creds and amounts.
    /// @param credIds_ The IDs of the creds.
    /// @param amounts_ The amounts corresponding to each cred.
    /// @return The total sell price for the batch.
    function getBatchSellPrice(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_
    )
        external
        view
        returns (uint256)
    {
        uint256 total;
        for (uint256 i = 0; i < credIds_.length; ++i) {
            total += IBondingCurve(creds[credIds_[i]].bondingCurve).getSellPriceAfterFee(
                credIds_[i], creds[credIds_[i]].currentSupply, amounts_[i]
            );
        }
        return total;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW CRED FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Checks if a cred exists.
    /// @param credId_ The ID of the cred to check.
    /// @return Whether the cred exists.
    function isExist(uint256 credId_) public view returns (bool) {
        return creds[credId_].creator != address(0);
    }

    function getCredCreator(uint256 credId_) external view returns (address) {
        return creds[credId_].creator;
    }

    function getCurrentSupply(uint256 credId_) external view returns (uint256) {
        return creds[credId_].currentSupply;
    }

    function getCreatorRoyalty(uint256 credId_) public view returns (uint16 buyShareRoyalty, uint16 sellShareRoyalty) {
        buyShareRoyalty = creds[credId_].buyShareRoyalty;
        sellShareRoyalty = creds[credId_].sellShareRoyalty;
    }

    /// @notice Gets the information of a cred.
    /// @param credId_ The ID of the cred.
    /// @return The cred information.
    function credInfo(uint256 credId_) external view returns (PhiCred memory) {
        return creds[credId_];
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW CURATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Checks if an address has th cred.
    /// @param credId_ The ID of the cred.
    /// @param curator_ The address to check.
    /// @return Whether the address has the cred.
    function isShareHolder(uint256 credId_, address curator_) public view returns (bool) {
        (, uint256 amounts) = shareBalance[credId_].tryGet(curator_);
        return amounts > 0;
    }

    /// @notice Gets the number of share an address has for a cred.
    /// @param credId_ The ID of the cred.
    /// @param curator_ The address to check.
    /// @return The number of shares the address has for the cred.
    function getShareNumber(uint256 credId_, address curator_) external view returns (uint256) {
        return shareBalance[credId_].get(curator_);
    }

    function getCuratorAddressLength(uint256 credId_) external view returns (uint256) {
        return shareBalance[credId_].length();
    }

    /// @notice Gets the addresses that have a cred.
    /// @param credId_ The ID of the cred.
    /// @param start_ The starting index for pagination.
    /// @param stop_ The stopping index for pagination.
    /// @return The addresses that have the cred.
    function getCuratorAddresses(
        uint256 credId_,
        uint256 start_,
        uint256 stop_
    )
        public
        view
        returns (address[] memory)
    {
        CuratorData[] memory curatorData = _getCuratorData(credId_, start_, stop_);
        address[] memory result = new address[](curatorData.length);

        for (uint256 i = 0; i < curatorData.length; i++) {
            result[i] = curatorData[i].curator;
        }

        return result;
    }

    /// @notice Gets the addresses and their share amounts.
    /// @param credId_ The ID of the cred.
    /// @param start_ The starting index for pagination.
    /// @param stop_ The stopping index for pagination.
    /// @return The addresses and their share amounts of the cred.
    function getCuratorAddressesWithAmount(
        uint256 credId_,
        uint256 start_,
        uint256 stop_
    )
        public
        view
        returns (CuratorData[] memory)
    {
        return _getCuratorData(credId_, start_, stop_);
    }

    /// @notice Gets the cred IDs and amounts for creds where the given address has a position
    /// @param  curator_ The address to check.
    /// @return credIds The IDs of the creds where the address has a position.
    /// @return amounts The corresponding amounts for each cred.
    function getPositionsForCurator(
        address curator_,
        uint256 start_,
        uint256 stop_
    )
        external
        view
        returns (uint256[] memory credIds, uint256[] memory amounts)
    {
        uint256[] storage userCredIds = _credIdsPerAddress[curator_];

        uint256 stopIndex;
        if (userCredIds.length == 0) {
            return (credIds, amounts);
        }
        if (stop_ == 0 || stop_ > userCredIds.length) {
            stopIndex = userCredIds.length;
        } else {
            stopIndex = stop_;
        }

        if (start_ >= stopIndex) {
            revert InvalidPaginationParameters();
        }

        credIds = new uint256[](stopIndex - start_);
        amounts = new uint256[](stopIndex - start_);

        uint256 index = 0;
        for (uint256 i = start_; i < stopIndex; i++) {
            uint256 credId = userCredIds[i];
            if (_credIdExistsPerAddress[curator_][credId]) {
                uint256 amount = shareBalance[credId].get(curator_);
                credIds[i] = credId;
                amounts[i] = amount;
                index++;
            }
        }
        // Resize the result array to remove unused slots
        assembly {
            mstore(credIds, index)
            mstore(amounts, index)
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Merkle Tree
    //////////////////////////////////////////////////////////////*/
    /// @notice Gets the root of a cred's Merkle tree.
    /// @param credId_ The ID of the cred.
    /// @return The root of the cred's Merkle tree.
    function getRoot(uint256 credId_) public view returns (bytes32) {
        return credsMerkeRoot[credId_];
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL UPDATE CREATE
    //////////////////////////////////////////////////////////////*/
    /// @dev Internal function to create a new cred.
    /// @param credURL_ The URL of the cred data.
    /// @param credType_ The type of the cred.
    /// @param verificationType_ The verification type of the cred.
    /// @param bondingCurve_ The address of the CuratePrice contract for the cred.
    /// @return The ID of the newly created cred.
    function _createCredInternal(
        address creator_,
        string memory credURL_,
        string memory credType_,
        string memory verificationType_,
        address bondingCurve_,
        uint16 buyShareRoyalty_,
        uint16 sellShareRoyalty_
    )
        internal
        whenNotPaused
        returns (uint256)
    {
        if (creator_ == address(0)) {
            revert InvalidAddressZero();
        }

        creds[credIdCounter].creator = creator_;
        creds[credIdCounter].credURL = credURL_;
        creds[credIdCounter].credType = credType_;
        creds[credIdCounter].verificationType = verificationType_;
        creds[credIdCounter].bondingCurve = bondingCurve_;
        creds[credIdCounter].createdAt = uint40(block.timestamp);
        creds[credIdCounter].buyShareRoyalty = buyShareRoyalty_;
        creds[credIdCounter].sellShareRoyalty = sellShareRoyalty_;

        buyShareCred(credIdCounter, 1, 0);

        emit CredCreated(creator_, credIdCounter, credURL_, credType_, verificationType_);

        credIdCounter += 1;

        return credIdCounter - 1;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL UPDATE SHARE
    //////////////////////////////////////////////////////////////*/
    /// @dev Internal function to handle trade logic
    /// @param credId_ The ID of the cred
    /// @param amount_ The amount to buy or se;;
    /// @param isBuy True if buy, false if sell
    /// @param curator_ The address performing the action
    /// @param priceLimit The maximum price for the trade or minimum price for sell
    function _handleTrade(
        uint256 credId_,
        uint256 amount_,
        bool isBuy,
        address curator_,
        uint256 priceLimit
    )
        internal
        whenNotPaused
    {
        if (amount_ == 0) {
            revert InvalidAmount();
        }

        if (!isExist(credId_)) {
            revert InvalidCredId();
        }

        PhiCred storage cred = creds[credId_];

        uint256 supply = cred.currentSupply;
        address creator = cred.creator;

        (uint256 price, uint256 protocolFee, uint256 creatorFee) =
            IBondingCurve(cred.bondingCurve).getPriceData(credId_, supply, amount_, isBuy);

        if (isBuy) {
            if (priceLimit != 0 && price + protocolFee + creatorFee > priceLimit) revert PriceExceedsLimit();
            if (supply + amount_ > MAX_SUPPLY) {
                revert MaxSupplyReached();
            }

            if (msg.value < price + protocolFee + creatorFee) {
                revert InsufficientPayment();
            }
        } else {
            if (priceLimit != 0 && price - protocolFee - creatorFee < priceLimit) revert PriceBelowLimit();
            if (block.timestamp <= lastTradeTimestamp[credId_][curator_] + SHARE_LOCK_PERIOD) {
                revert ShareLockPeriodNotPassed(
                    block.timestamp, lastTradeTimestamp[credId_][curator_] + SHARE_LOCK_PERIOD
                );
            }
            (, uint256 nums) = shareBalance[credId_].tryGet(curator_);
            if (nums < amount_) {
                revert InsufficientShares();
            }
        }

        _updateCuratorShareBalance(credId_, curator_, amount_, isBuy);

        if (isBuy) {
            cred.currentSupply += amount_;
            uint256 excessPayment = msg.value - price - protocolFee - creatorFee;
            if (excessPayment > 0) {
                _msgSender().safeTransferETH(excessPayment);
            }
            lastTradeTimestamp[credId_][curator_] = block.timestamp;
        } else {
            cred.currentSupply -= amount_;
            curator_.safeTransferETH(price - protocolFee - creatorFee);
        }

        protocolFeeDestination.safeTransferETH(protocolFee);
        IPhiRewards(phiRewardsAddress).deposit{ value: creatorFee }(
            creator, bytes4(keccak256("CREATOR_ROYALTY_FEE")), ""
        );
        emit Royalty(creator, credId_, creatorFee);

        cred.latestActiveTimestamp = block.timestamp;

        emit Trade(curator_, credId_, isBuy, amount_, price, protocolFee, cred.currentSupply);
    }

    /// @dev Updates the balance for a user
    /// @param credId_ The ID of the cred
    /// @param sender_ The address of the user
    /// @param amount_ The amount to update
    /// @param isBuy True if Buy, false if Sell
    function _updateCuratorShareBalance(uint256 credId_, address sender_, uint256 amount_, bool isBuy) internal {
        (, uint256 currentNum) = shareBalance[credId_].tryGet(sender_);

        if (isBuy) {
            if (currentNum == 0 && !_credIdExistsPerAddress[sender_][credId_]) {
                _addCredIdPerAddress(credId_, sender_);
                _credIdExistsPerAddress[sender_][credId_] = true;
            }
            shareBalance[credId_].set(sender_, currentNum + amount_);
        } else {
            if ((currentNum - amount_) == 0) {
                _removeCredIdPerAddress(credId_, sender_);
                _credIdExistsPerAddress[sender_][credId_] = false;
            }
            shareBalance[credId_].set(sender_, currentNum - amount_);
        }
    }

    // Function to add a new credId to the address's list
    function _addCredIdPerAddress(uint256 credId_, address sender_) public {
        // Add the new credId to the array
        _credIdsPerAddress[sender_].push(credId_);
        // Store the index of the new credId
        _credIdsPerAddressCredIdIndex[sender_][credId_] = _credIdsPerAddressArrLength[sender_];
        // Increment the array length counter
        _credIdsPerAddressArrLength[sender_]++;
    }

    // Function to remove a credId from the address's list
    function _removeCredIdPerAddress(uint256 credId_, address sender_) public {
        // Check if the array is empty
        if (_credIdsPerAddress[sender_].length == 0) revert EmptyArray();

        // Get the index of the credId to remove
        uint256 indexToRemove = _credIdsPerAddressCredIdIndex[sender_][credId_];
        // Check if the index is valid
        if (indexToRemove >= _credIdsPerAddress[sender_].length) revert IndexOutofBounds();

        // Verify that the credId at the index matches the one we want to remove
        uint256 credIdToRemove = _credIdsPerAddress[sender_][indexToRemove];
        if (credId_ != credIdToRemove) revert WrongCredId();

        // Get the last element in the array
        uint256 lastIndex = _credIdsPerAddress[sender_].length - 1;
        uint256 lastCredId = _credIdsPerAddress[sender_][lastIndex];
        // Move the last element to the position of the element we're removing
        _credIdsPerAddress[sender_][indexToRemove] = lastCredId;

        // Update the index of the moved element, if it's not the one we're removing
        if (indexToRemove < lastIndex) {
            _credIdsPerAddressCredIdIndex[sender_][lastCredId] = indexToRemove;
        }

        // Remove the last element (which is now a duplicate)
        _credIdsPerAddress[sender_].pop();

        // Remove the index mapping for the removed credId
        delete _credIdsPerAddressCredIdIndex[sender_][credIdToRemove];

        // Decrement the array length counter, if it's greater than 0
        if (_credIdsPerAddressArrLength[sender_] > 0) {
            _credIdsPerAddressArrLength[sender_]--;
        }
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL UPDATE BATCH TRADE
    //////////////////////////////////////////////////////////////*/
    function _executeBatchTrade(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        address curator,
        uint256[] memory prices,
        uint256[] memory protocolFees,
        uint256[] memory creatorFees,
        bool isBuy
    )
        internal
        whenNotPaused
        nonReentrant
    {
        if (curator == address(0)) {
            revert InvalidAddressZero();
        }

        for (uint256 i = 0; i < credIds_.length; ++i) {
            uint256 credId = credIds_[i];
            uint256 amount = amounts_[i];

            _updateCuratorShareBalance(credId, curator, amount, isBuy);

            if (isBuy) {
                creds[credId].currentSupply += amount;
                lastTradeTimestamp[credId][curator] = block.timestamp;
            } else {
                if (block.timestamp <= lastTradeTimestamp[credId][curator] + SHARE_LOCK_PERIOD) {
                    revert ShareLockPeriodNotPassed(
                        block.timestamp, lastTradeTimestamp[credId][curator] + SHARE_LOCK_PERIOD
                    );
                }
                creds[credId].currentSupply -= amount;
            }

            creds[credId].latestActiveTimestamp = block.timestamp;
        }

        for (uint256 i = 0; i < credIds_.length; ++i) {
            uint256 credId = credIds_[i];

            protocolFeeDestination.safeTransferETH(protocolFees[i]);
            IPhiRewards(phiRewardsAddress).deposit{ value: creatorFees[i] }(
                creds[credId].creator, bytes4(keccak256("CREATOR_ROYALTY_FEE")), ""
            );
            emit Royalty(creds[credId].creator, credId, creatorFees[i]);

            emit Trade(curator, credId, isBuy, amounts_[i], prices[i], protocolFees[i], creds[credId].currentSupply);
        }
    }

    function _executeBatchBuy(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        address curator_,
        uint256[] memory prices,
        uint256[] memory protocolFees,
        uint256[] memory creatorFees
    )
        internal
    {
        _executeBatchTrade(credIds_, amounts_, curator_, prices, protocolFees, creatorFees, true);
    }

    function _executeBatchSell(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        uint256[] memory prices,
        uint256[] memory protocolFees,
        uint256[] memory creatorFees
    )
        internal
    {
        _executeBatchTrade(credIds_, amounts_, _msgSender(), prices, protocolFees, creatorFees, false);
    }

    function _validateAndCalculateBatch(
        uint256[] calldata credIds_,
        uint256[] calldata amounts_,
        uint256[] calldata priceLimits_,
        bool isBuy
    )
        internal
        view
        returns (
            uint256 totalAmount,
            uint256[] memory prices,
            uint256[] memory protocolFees,
            uint256[] memory creatorFees
        )
    {
        uint256 length = credIds_.length;
        if (length != amounts_.length) {
            revert InvalidArrayLength();
        }
        if (length == 0) {
            revert EmptyBatchOperation();
        }

        prices = new uint256[](length);
        protocolFees = new uint256[](length);
        creatorFees = new uint256[](length);

        uint256[] memory processedCredIds = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            uint256 credId = credIds_[i];
            uint256 amount = amounts_[i];
            if (amount == 0) {
                revert InvalidAmount();
            }
            if (!isExist(credId)) {
                revert InvalidCredId();
            }

            for (uint256 j = 0; j < i; ++j) {
                if (processedCredIds[j] == credId) {
                    revert DuplicateCredId();
                }
            }
            processedCredIds[i] = credId;

            PhiCred storage cred = creds[credId];

            (prices[i], protocolFees[i], creatorFees[i]) =
                IBondingCurve(cred.bondingCurve).getPriceData(credId, cred.currentSupply, amount, isBuy);

            if (isBuy) {
                if (priceLimits_[i] != 0 && prices[i] + protocolFees[i] + creatorFees[i] > priceLimits_[i]) {
                    revert PriceExceedsLimit();
                }
                if (cred.currentSupply + amount > MAX_SUPPLY) {
                    revert MaxSupplyReached();
                }
            } else {
                if (priceLimits_[i] != 0 && prices[i] - protocolFees[i] - creatorFees[i] < priceLimits_[i]) {
                    revert PriceBelowLimit();
                }
                (, uint256 num) = shareBalance[credId].tryGet(_msgSender());
                if (num < amount) {
                    revert InsufficientShares();
                }
            }

            if (isBuy) {
                totalAmount += prices[i] + protocolFees[i] + creatorFees[i];
            } else {
                totalAmount += prices[i] - protocolFees[i] - creatorFees[i];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/
    function _recoverSigner(bytes32 hash_, bytes memory signature_) private view returns (address) {
        return ECDSA.recover(ECDSA.toEthSignedMessageHash(hash_), signature_);
    }

    /// @notice Helper function to get the addresses and their share amounts that have a cred.
    /// @param credId_ The ID of the cred.
    /// @param start_ The starting index for pagination.
    /// @param stop_ The stopping index for pagination.
    /// @return The addresses and their amounts of the cred
    function _getCuratorData(
        uint256 credId_,
        uint256 start_,
        uint256 stop_
    )
        internal
        view
        returns (CuratorData[] memory)
    {
        uint256 stopIndex;
        if (stop_ == 0 || stop_ > shareBalance[credId_].length()) {
            stopIndex = shareBalance[credId_].length();
        } else {
            stopIndex = stop_;
        }

        if (start_ >= stopIndex) {
            revert InvalidPaginationParameters();
        }

        CuratorData[] memory result = new CuratorData[](stopIndex - start_);
        uint256 index = 0;

        for (uint256 i = start_; i < stopIndex; ++i) {
            (address key, uint256 shareAmount) = shareBalance[credId_].at(i);

            if (isShareHolder(credId_, key)) {
                result[index] = CuratorData(key, shareAmount);
                index++;
            }
        }

        // Resize the result array to remove unused slots
        assembly {
            mstore(result, index)
        }

        return result;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // This function is intentionally left empty to allow for upgrades
    }
}
