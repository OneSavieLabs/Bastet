// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {Ownable} from '@solady/auth/Ownable.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {TokenEscrow} from '@flayer/TokenEscrow.sol';

import {Enums} from '@flayer-interfaces/Enums.sol';
import {IBaseImplementation} from '@flayer-interfaces/IBaseImplementation.sol';
import {ICollectionToken} from '@flayer-interfaces/ICollectionToken.sol';
import {IListings} from '@flayer-interfaces/IListings.sol';
import {ILocker} from '@flayer-interfaces/ILocker.sol';
import {IProtectedListings} from '@flayer-interfaces/IProtectedListings.sol';


/**
 * Handles the core underlying listing support.
 */
contract Listings is IListings, Ownable, ReentrancyGuard, TokenEscrow {

    /// Emitted when a new listing is created
    event ListingsCreated(address indexed _collection, uint[] _tokenIds, Listing _listing, Enums.ListingType _listingType, uint _tokensRequired, uint _taxRequired, address _sender);

    /// Emitted when a listing is relisted
    event ListingRelisted(address indexed _collection, uint _tokenId, Listing _listing);

    /// Emitted when a 1 - n listings are filled
    event ListingsFilled(address indexed _collection, uint[][] _tokenIds, address _recipient);

    /// Emitted when a listing is transferred to another owner
    event ListingTransferred(address indexed _collection, uint _tokenId, address _owner, address _newOwner);

    /// Emitted when a listing is cancelled by the owner
    event ListingsCancelled(address indexed _collection, uint[] _tokenIds);

    /// Emitted when a listing duration is extended
    event ListingExtended(address indexed _collection, uint _tokenId, uint32 _oldDuration, uint32 _newDuration);

    /// Emitted when a listing floor multiple is updated
    event ListingFloorMultipleUpdated(address indexed _collection, uint _tokenId, uint32 _oldFloorMultiple, uint32 _newFloorMultiple);

    /// Emitted when listing fees have been captured
    event ListingFeeCaptured(address indexed _collection, uint _tokenId, uint _amount);

    /// Emitted when the {ProtectedListings} contract is updated
    event ProtectedListingsContractUpdated(address _protectedListings);

    /// Define our tstore variable names
    bytes32 private constant FILL_FEE = 0xa40c0092c38dd399f81cbdededd4c56dc816ce700d2ef20bf50ba8480186c5bf;
    bytes32 private constant FILL_PRICE = 0x9547ee3353571b86e0e79a9ff81447cc69303c44482a02ebfc5d7cca4dd94998;
    bytes32 private constant FILL_REFUND = 0x82cd2f49fb2388af88155c0aea5209e274b39b84940eddd1580d670af04dc096;

    /// Define parameters for liquidation listing
    uint16 private constant LIQUIDATION_LISTING_FLOOR_MULTIPLE = 4_00;
    uint private constant LIQUIDATION_LISTING_DURATION = 4 days;

    /// Define our minimum floor multiple
    uint internal constant MIN_FLOOR_MULTIPLE = 100;

    /// Add our {Locker} that will store all ERC721 tokens
    ILocker public immutable locker;

    /// Add our {ProtectedListings} that will be able to created liqiudation listings
    IProtectedListings public protectedListings;

    /// Map our token listings
    mapping (address _collection => mapping (uint _tokenId => Listing _listing)) private _listings;

    /// Stores a count of all open listing types
    mapping (address _collection => uint _count) public listingCount;

    /// Stores if the created listings has been internally mapped as a liquidation
    mapping (address _collection => mapping (uint _tokenId => bool _isLiquidation)) private _isLiquidation;

    /// The maximum duration that can be set
    uint16 public constant MAX_FLOOR_MULTIPLE = 10_00;

    /// Minimum and maximum liquid listing durations
    uint32 public constant MIN_LIQUID_DURATION = 7 days;
    uint32 public constant MAX_LIQUID_DURATION = 180 days;

    /// Minimum and maximum dutch listing durations
    uint32 public constant MIN_DUTCH_DURATION = 1 days;
    uint32 public constant MAX_DUTCH_DURATION = 7 days - 1;

    /// The dutch duration for an expired liquid listing
    uint32 public constant LIQUID_DUTCH_DURATION = 4 days;

    /**
     * Instantiates our contract with required parameters.
     *
     * @param _locker The {Locker} contract
     */
    constructor (ILocker _locker) {
        // Ensure that we don't provide zero addresses
        if(address(_locker) == address(0)) revert LockerIsZeroAddress();
        locker = _locker;

        // Assign our contract owner
        _initializeOwner(msg.sender);
    }

    /**
     * Getter for _listings mapping.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     */
    function listings(address _collection, uint _tokenId) public view returns (Listing memory) {
        return _listings[_collection][_tokenId];
    }

    /**
     * Each listing object should be grouped and validated. This means that we can
     * just directly store the Listing without having to create it ourselves.
     *
     * We can create the listing against multiple token IDs, reducing the amount
     * of information being passed up in the call.
     *
     * This also means that we will just need to calculate tax once per listing type
     * and multiply it by the number of token IDs attached to the listing. This should
     * save substantial gas when creating > 1 listings.
     *
     * Unfortunately, we will still need to pay with escrow per tokenId to allow for
     * listings to be cancelled.
     */
    function createListings(CreateListing[] calldata _createListings) public nonReentrant lockerNotPaused {
        // Loop variables
        uint taxRequired;
        uint tokensIdsLength;
        uint tokensReceived;

        // Loop over the unique listing structures
        for (uint i; i < _createListings.length; ++i) {
            // Store our listing for cheaper access
            CreateListing calldata listing = _createListings[i];

            // Ensure our listing will be valid
            _validateCreateListing(listing);

            // Map our listings
            tokensIdsLength = listing.tokenIds.length;
            tokensReceived = _mapListings(listing, tokensIdsLength) * 10 ** locker.collectionToken(listing.collection).denomination();

            // Get the amount of tax required for the newly created listing
            taxRequired = getListingTaxRequired(listing.listing, listing.collection) * tokensIdsLength;
            if (taxRequired > tokensReceived) revert InsufficientTax(tokensReceived, taxRequired);
            unchecked { tokensReceived -= taxRequired; }

            // Increment our listings count
            unchecked {
                listingCount[listing.collection] += tokensIdsLength;
            }

            // Deposit the tokens into the locker and distribute ERC20 to user
            _depositNftsAndReceiveTokens(listing, tokensReceived);

            // Create our checkpoint as utilisation rates will change
            protectedListings.createCheckpoint(listing.collection);

            emit ListingsCreated(listing.collection, listing.tokenIds, listing.listing, getListingType(listing.listing), tokensReceived, taxRequired, msg.sender);
        }
    }

    /**
     * Creates a listing that doesn't require any tax to be paid. This is called when
     * a listing is liquidated and bypasses the ERC721 deposit and ERC20 distributions.
     *
     * The `_isLiquidation` flag is set so that tax is correctly calculated when filling.
     *
     * @dev Can only be called by our {ProtectedListings} contract
     *
     * @dev We create a checkpoint for this in the parent call
     */
    function createLiquidationListing(CreateListing calldata _createListing) public nonReentrant lockerNotPaused {
        // We can only call this from our {ProtectedListings} contract
        if (msg.sender != address(protectedListings)) revert CallerIsNotProtectedListings();

        // Map our Listing struct as it is referenced a few times moving forward
        Listing calldata listing = _createListing.listing;

        /// Ensure our listing will be valid
        if (listing.floorMultiple != LIQUIDATION_LISTING_FLOOR_MULTIPLE) {
            revert InvalidFloorMultiple(listing.floorMultiple, LIQUIDATION_LISTING_FLOOR_MULTIPLE);
        }

        if (listing.duration != LIQUIDATION_LISTING_DURATION) {
            revert InvalidLiquidationListingDuration(listing.duration, LIQUIDATION_LISTING_DURATION);
        }

        // Flag our listing as a liquidation
        _isLiquidation[_createListing.collection][_createListing.tokenIds[0]] = true;

        // Our token will already be in the {Locker}, so we can just confirm ownership. This
        // saves us 2 transfer calls.
        if (IERC721(_createListing.collection).ownerOf(_createListing.tokenIds[0]) != address(locker)) revert LockerIsNotTokenHolder();

        // Map our listing
        _mapListings(_createListing, 1);

        // Increment our listings count
        unchecked { listingCount[_createListing.collection] += 1; }

        emit ListingsCreated(_createListing.collection, _createListing.tokenIds, listing, Enums.ListingType.DUTCH, 0, 0, msg.sender);
    }

    /**
     * Handles the internal logic of depositing NFTs and then distributing the ERC20 to
     * the user.
     */
    function _depositNftsAndReceiveTokens(CreateListing calldata _listing, uint _tokensReceived) private {
        // Reference our collection token so we don't instantiate multiple times
        IERC721 token = IERC721(_listing.collection);

        // We need to move the tokens used by the listings into this contract
        for (uint i; i < _listing.tokenIds.length; ++i) {
            // Transfer the collection token from the caller to the locker
            token.transferFrom(msg.sender, address(this), _listing.tokenIds[i]);
        }

        // Check if we already have approval for the tokens, otherwise set mass approval
        if (!token.isApprovedForAll(address(this), address(locker))) {
            token.setApprovalForAll(address(locker), true);
        }

        // We will leave a subset of the tokens inside this {Listings} contract as collateral or
        // listing fees. So rather than sending the tokens directly to the user, we need to first
        // receive them into this contract and then send some on.
        locker.deposit(_listing.collection, _listing.tokenIds, address(this));

        // Send `_tokensReceived` to the user
        locker.collectionToken(_listing.collection).transfer(_listing.listing.owner, _tokensReceived);
    }

    /**
     * Handles the internal logic of mapping the newly created listings and then determines
     * the amount of the underlying ERC20 token that the user will receive for these listings.
     */
    function _mapListings(CreateListing calldata _createListing, uint _tokenIds) private returns (uint tokensReceived_) {
        // Loop through our tokens
        for (uint i; i < _tokenIds; ++i) {
            // Create our initial listing and update the timestamp of the listing creation to now
            _listings[_createListing.collection][_createListing.tokenIds[i]] = Listing({
                owner: _createListing.listing.owner,
                created: uint40(block.timestamp),
                duration: _createListing.listing.duration,
                floorMultiple: _createListing.listing.floorMultiple
            });
        }

        // Our user will always receive one ERC20 per ERC721
        tokensReceived_ = _tokenIds * 1 ether;
    }

    /**
     * A series of validation checks for different listing types. If any of these relevant conditions
     * are not met then the call will revert.
     */
    function _validateCreateListing(CreateListing calldata _listing) private view {
        // Ensure that our collection exists and is initialised
        if (!locker.collectionInitialized(_listing.collection)) revert CollectionNotInitialized();

        // Extract our listing
        Listing calldata listing = _listing.listing;

        // Ensure that we don't put a zero address owner in charge of listing
        if (listing.owner == address(0)) revert ListingOwnerIsZero();

        // If we are creating a listing, and not performing an instant liquidation (which
        // would be done via `deposit`), then we need to ensure that the `floorMultiple` is
        // greater than 1.
        if (listing.floorMultiple <= MIN_FLOOR_MULTIPLE) revert FloorMultipleMustBeAbove100(listing.floorMultiple);
        if (listing.floorMultiple > MAX_FLOOR_MULTIPLE) revert FloorMultipleExceedsMax(listing.floorMultiple, MAX_FLOOR_MULTIPLE);

        // Create our listing contract and map it
        Enums.ListingType listingType = getListingType(_listing.listing);
        if (listingType == Enums.ListingType.DUTCH) {
            // Ensure that the requested duration falls within our listing range
            if (listing.duration < MIN_DUTCH_DURATION) revert ListingDurationBelowMin(listing.duration, MIN_DUTCH_DURATION);
            if (listing.duration > MAX_DUTCH_DURATION) revert ListingDurationExceedsMax(listing.duration, MAX_DUTCH_DURATION);

        } else if (listingType == Enums.ListingType.LIQUID) {
            // Ensure that the requested duration falls within our listing range
            if (listing.duration < MIN_LIQUID_DURATION) revert ListingDurationBelowMin(listing.duration, MIN_LIQUID_DURATION);
            if (listing.duration > MAX_LIQUID_DURATION) revert ListingDurationExceedsMax(listing.duration, MAX_LIQUID_DURATION);

        } else {
            revert InvalidListingType();
        }
    }

    /**
     * Allows multiple listings to have their duration changed or have the price updated. This will
     * validate to either require more tax, or refund tax. Before sending tokens either way, we will
     * use tax refunded to pay the new tax for gas savings.
     *
     * @return taxRequired_ The amount of underlying ERC20 required to modify the listings
     * @return refund_ The amount of underlying ERC20 refunded to the owner from modifying listings
     */
    function modifyListings(address _collection, ModifyListing[] calldata _modifyListings, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused returns (uint taxRequired_, uint refund_) {
        uint fees;

        for (uint i; i < _modifyListings.length; ++i) {
            // Store the listing
            ModifyListing memory params = _modifyListings[i];
            Listing storage listing = _listings[_collection][params.tokenId];

            // We can only modify liquid listings
            if (getListingType(listing) != Enums.ListingType.LIQUID) revert InvalidListingType();

            // Ensure the caller is the owner of the listing
            if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

            // Check if we have no changes, as we can continue our loop early
            if (params.duration == 0 && params.floorMultiple == listing.floorMultiple) {
                continue;
            }

            // Collect tax on the existing listing
            (uint _fees, uint _refund) = _resolveListingTax(listing, _collection, false);
            emit ListingFeeCaptured(_collection, params.tokenId, _fees);

            fees += _fees;
            refund_ += _refund;

            // Check if we are altering the duration of the listing
            if (params.duration != 0) {
                // Ensure that the requested duration falls within our listing range
                if (params.duration < MIN_LIQUID_DURATION) revert ListingDurationBelowMin(params.duration, MIN_LIQUID_DURATION);
                if (params.duration > MAX_LIQUID_DURATION) revert ListingDurationExceedsMax(params.duration, MAX_LIQUID_DURATION);

                emit ListingExtended(_collection, params.tokenId, listing.duration, params.duration);

                listing.created = uint40(block.timestamp);
                listing.duration = params.duration;
            }

            // Check if the floor multiple price has been updated
            if (params.floorMultiple != listing.floorMultiple) {
                // If we are creating a listing, and not performing an instant liquidation (which
                // would be done via `deposit`), then we need to ensure that the `floorMultiple` is
                // greater than 1.
                if (params.floorMultiple <= MIN_FLOOR_MULTIPLE) revert FloorMultipleMustBeAbove100(params.floorMultiple);
                if (params.floorMultiple > MAX_FLOOR_MULTIPLE) revert FloorMultipleExceedsMax(params.floorMultiple, MAX_FLOOR_MULTIPLE);

                emit ListingFloorMultipleUpdated(_collection, params.tokenId, listing.floorMultiple, params.floorMultiple);

                listing.floorMultiple = params.floorMultiple;
            }

            // Get the amount of tax required for the newly extended listing
            taxRequired_ += getListingTaxRequired(listing, _collection);
        }

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // If our tax refund does not cover the full amount of tax required, then we will need to make an
        // additional tax payment.
        if (taxRequired_ > refund_) {
            unchecked {
                payTaxWithEscrow(address(collectionToken), taxRequired_ - refund_, _payTaxWithEscrow);
            }
            refund_ = 0;
        } else {
            unchecked {
                refund_ -= taxRequired_;
            }
        }

        // Check if we have fees to be paid from the listings
        if (fees != 0) {
            collectionToken.approve(address(locker.implementation()), fees);
            locker.implementation().depositFees(_collection, 0, fees);
        }

        // If there is tax to refund after paying the new tax, then allocate it to the user via escrow
        if (refund_ != 0) {
            _deposit(msg.sender, address(collectionToken), refund_);
        }
    }

    /**
     * Allows the owner of a listing to transfer ownership to another address.
     *
     * @param _collection The collection address of the listing
     * @param _tokenId The tokenId of the listing
     * @param _newOwner The new owner of the listing
     */
    function transferOwnership(address _collection, uint _tokenId, address payable _newOwner) public lockerNotPaused {
        // Prevent the listing from being transferred to a zero address owner
        if (_newOwner == address(0)) revert NewOwnerIsZero();

        // Ensure that the caller has permission to transfer the listing
        Listing storage listing = _listings[_collection][_tokenId];
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Update the owner of the listing
        listing.owner = _newOwner;
        emit ListingTransferred(_collection, _tokenId, msg.sender, _newOwner);
    }

    /**
     * Allows multiple listings to be cancelled for 1 equivalent token and will refund any
     * remaining taxes that are present in the contract for that token ID listing.
     *
     * @param _collection The collection address of the listing
     * @param _tokenIds An array of tokenIds to cancel
     * @param _payTaxWithEscrow If taxes should be paid from escrow account
     */
    function cancelListings(address _collection, uint[] memory _tokenIds, bool _payTaxWithEscrow) public lockerNotPaused {
        uint fees;
        uint refund;

        for (uint i; i < _tokenIds.length; ++i) {
            uint _tokenId = _tokenIds[i];

            // Read the listing in a single read
            Listing memory listing = _listings[_collection][_tokenId];

            // Ensure the caller is the owner of the listing
            if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

            // We cannot allow a dutch listing to be cancelled. This will also check that a liquid listing has not
            // expired, as it will instantly change to a dutch listing type.
            Enums.ListingType listingType = getListingType(listing);
            if (listingType != Enums.ListingType.LIQUID) revert CannotCancelListingType();

            // Find the amount of prepaid tax from current timestamp to prepaid timestamp
            // and refund unused gas to the user.
            (uint _fees, uint _refund) = _resolveListingTax(listing, _collection, false);
            emit ListingFeeCaptured(_collection, _tokenId, _fees);

            fees += _fees;
            refund += _refund;

            // Delete the listing objects
            delete _listings[_collection][_tokenId];

            // Transfer the listing ERC721 back to the user
            locker.withdrawToken(_collection, _tokenId, msg.sender);
        }

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // Burn the ERC20 token that would have been given to the user when it was initially created
        uint requiredAmount = ((1 ether * _tokenIds.length) * 10 ** collectionToken.denomination()) - refund;
        payTaxWithEscrow(address(collectionToken), requiredAmount, _payTaxWithEscrow);
        collectionToken.burn(requiredAmount + refund);

        // Give some partial fees to the LP
        if (fees != 0) {
            collectionToken.approve(address(locker.implementation()), fees);
            locker.implementation().depositFees(_collection, 0, fees);
        }

        // Remove our listing type
        unchecked {
            listingCount[_collection] -= _tokenIds.length;
        }

        // Create our checkpoint as utilisation rates will change
        protectedListings.createCheckpoint(_collection);

        emit ListingsCancelled(_collection, _tokenIds);
    }

    /**
     * Internal logic for filling a listing. This will calculate the amount required to fill,
     * the amount of fees that have been generated from the listing and also the amount of
     * tax that will be refunded to the listing owner that was unused.
     *
     * @dev This optimises for gas by using transient storage to accumulate values for it's
     * parent calling function. This removes the requirement to return the attrubutes. These
     * tstore and tload values cannot be manipulated from outside of this contract.
     *
     * @param _collection The collection address of the listing
     * @param _collectionToken The underlying ERC20 token for the collection
     * @param _tokenId The tokenId to fill
     */
    function _fillListing(address _collection, address _collectionToken, uint _tokenId) private {
        // Get our listing information
        (bool isAvailable, uint price) = getListingPrice(_collection, _tokenId);

        // Increase our fill price
        assembly {
            tstore(FILL_PRICE, add(tload(FILL_PRICE), price))
        }

        // If the listing is invalid, then we prevent the buy
        if (!isAvailable) revert ListingNotAvailable();

        // If the `owner` is still a zero-address, then it is a Floor item and should
        // not process any additional listing related functions.
        if (_listings[_collection][_tokenId].owner != address(0)) {
            // Check if there is collateral on the listing, as this we bypass fees and refunds
            if (!_isLiquidation[_collection][_tokenId]) {
                // Find the amount of prepaid tax from current timestamp to prepaid timestamp
                // and refund unused gas to the user.
                (uint fee, uint refund) = _resolveListingTax(_listings[_collection][_tokenId], _collection, false);
                emit ListingFeeCaptured(_collection, _tokenId, fee);

                assembly {
                    tstore(FILL_FEE, add(tload(FILL_FEE), fee))
                    tstore(FILL_REFUND, add(tload(FILL_REFUND), refund))
                }
            } else {
                delete _isLiquidation[_collection][_tokenId];
            }

            unchecked { listingCount[_collection] -= 1; }

            // Delete the token listing
            delete _listings[_collection][_tokenId];
        }

        // Transfer the listing ERC721 to the user
        locker.withdrawToken(_collection, _tokenId, msg.sender);
    }

    /**
     * Fills multiple listings using underlying ERC20 tokens to fill them.
     */
    function fillListings(FillListingsParams calldata params) public nonReentrant lockerNotPaused {
        // Load our IERC20 interface for the `params.collection` outside of the loop
        address collection = params.collection;
        ICollectionToken _collectionToken = locker.collectionToken(collection);
        if (address(_collectionToken) == address(0)) revert InvalidCollection();

        // Loop variables
        address owner;
        uint ownerReceives;
        uint refundAmount;
        uint totalBurn;
        uint totalPrice;

        // Iterate over owners
        for (uint ownerIndex; ownerIndex < params.tokenIdsOut.length; ++ownerIndex) {
            // Iterate over the owner tokens. If the owner has no tokens, just skip
            // to the next owner in the loop.
            uint ownerIndexTokens = params.tokenIdsOut[ownerIndex].length;
            if (ownerIndexTokens == 0) {
                continue;
            }

            // Reset our owner for the group as the first owner in the iteration
            owner = _listings[collection][params.tokenIdsOut[ownerIndex][0]].owner;

            for (uint i; i < ownerIndexTokens; ++i) {
                uint tokenId = params.tokenIdsOut[ownerIndex][i];

                // If this is not the first listing, then we want to validate that the owner
                // matches the first of the group.
                if (i != 0 && _listings[collection][tokenId].owner != owner) {
                    revert InvalidOwner();
                }

                // Action our listing fill
                _fillListing(collection, address(_collectionToken), tokenId);
            }

            // If there is ERC20 left to be claimed, then deposit this into the escrow
            ownerReceives = _tload(FILL_PRICE) - (ownerIndexTokens * 1 ether * 10 ** _collectionToken.denomination());
            if (ownerReceives != 0) {
                _deposit(owner, address(_collectionToken), ownerReceives);
                totalPrice += ownerReceives;
            }

            refundAmount = _tload(FILL_REFUND);
            if (refundAmount != 0) {
                _deposit(owner, address(_collectionToken), refundAmount);
                assembly { tstore(FILL_REFUND, 0) }
            }

            // Reset the price back to zero
            assembly { tstore(FILL_PRICE, 0) }

            totalBurn += ownerIndexTokens;
        }

        // Transfer enough tokens from the user to cover the `_deposit` calls made during
        // our fill loop.
        _collectionToken.transferFrom(msg.sender, address(this), totalPrice);

        // Burn the ERC20 tokens from the user's wallet to cover the base amount required.
        // As we have not yet transferred tokens in, we don't need to process a return
        // of any overpaid tokens.
        _collectionToken.burnFrom(msg.sender, totalBurn * 1 ether * 10 ** _collectionToken.denomination());

        // If we have fees to send to our {FeeCollector}, then trigger the deposit
        uint fillFee = _tload(FILL_FEE);
        if (fillFee != 0) {
            _collectionToken.approve(address(locker.implementation()), fillFee);
            locker.implementation().depositFees(collection, 0, fillFee);
            assembly { tstore(FILL_FEE, 0) }
        }

        // Create our checkpoint as utilisation rates will change
        protectedListings.createCheckpoint(collection);

        // Emit an event to show which listings have been filled
        emit ListingsFilled(collection, params.tokenIdsOut, msg.sender);
    }

    /**
     * We can relist any token that is DUTCH or LIQUID. The user should be able to fill
     * the listing and recreate it with their own parameters.
     *
     * The user won't receive any base amount but will need to pay the amount required
     * to fill the difference of the existing listing.
     *
     * For example, if we have a listing with a price of 1.2 and we want to relist for
     * 1.4:
     *
     *  - We pay 0.2 (1.2 - 1.0) to the original listing user
     *  - We resolve the tax of the existing listing
     *  - We pay taxes based on a 1.4 listing
     *
     * The newly created listing can be of any type and will have to pay taxes as such.
     */
    function relist(CreateListing calldata _listing, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused {
        // Load our tokenId
        address _collection = _listing.collection;
        uint _tokenId = _listing.tokenIds[0];

        // Read the existing listing in a single read
        Listing memory oldListing = _listings[_collection][_tokenId];

        // Ensure the caller is not the owner of the listing
        if (oldListing.owner == msg.sender) revert CallerIsAlreadyOwner();

        // Load our new Listing into memory
        Listing memory listing = _listing.listing;

        // Ensure that the existing listing is available
        (bool isAvailable, uint listingPrice) = getListingPrice(_collection, _tokenId);
        if (!isAvailable) revert ListingNotAvailable();

        // We can process a tax refund for the existing listing
        (uint _fees,) = _resolveListingTax(oldListing, _collection, true);
        if (_fees != 0) {
            emit ListingFeeCaptured(_collection, _tokenId, _fees);
        }

        // Find the underlying {CollectionToken} attached to our collection
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // If the floor multiple of the original listings is different, then this needs
        // to be paid to the original owner of the listing.
        uint listingFloorPrice = 1 ether * 10 ** collectionToken.denomination();
        if (listingPrice > listingFloorPrice) {
            unchecked {
                collectionToken.transferFrom(msg.sender, oldListing.owner, listingPrice - listingFloorPrice);
            }
        }

        // Validate our new listing
        _validateCreateListing(_listing);

        // Store our listing into our Listing mappings
        _listings[_collection][_tokenId] = listing;

        // Pay our required taxes
        payTaxWithEscrow(address(collectionToken), getListingTaxRequired(listing, _collection), _payTaxWithEscrow);

        // Emit events
        emit ListingRelisted(_collection, _tokenId, listing);
    }

    /**
     * We can relist any token that is DUTCH or LIQUID. The user should be able to fill
     * the listing and recreate it with their own parameters.
     *
     * The user won't receive any base amount but will need to pay the amount required
     * to fill the difference of the existing listing.
     *
     * For example, if we have a listing with a price of 1.2 and we want to relist for
     * 1.4:
     *
     *  - We pay 0.2 (1.2 - 1.0) to the original listing user
     *  - We resolve the tax of the existing listing
     *  - We pay taxes based on a 1.4 listing
     *
     * The newly created listing can be of any type and will have to pay taxes as such.
     */
    function reserve(address _collection, uint _tokenId, uint _collateral) public nonReentrant lockerNotPaused {
        // Read the existing listing in a single read
        Listing memory oldListing = _listings[_collection][_tokenId];

        // Ensure the caller is not the owner of the listing
        if (oldListing.owner == msg.sender) revert CallerIsAlreadyOwner();

        // Ensure that the existing listing is available
        (bool isAvailable, uint listingPrice) = getListingPrice(_collection, _tokenId);
        if (!isAvailable) revert ListingNotAvailable();

        // Find the underlying {CollectionToken} attached to our collection
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // Check if the listing is a floor item and process additional logic if there
        // was an owner (meaning it was not floor, so liquid or dutch).
        if (oldListing.owner != address(0)) {
            // We can process a tax refund for the existing listing if it isn't a liquidation
            if (!_isLiquidation[_collection][_tokenId]) {
                (uint _fees,) = _resolveListingTax(oldListing, _collection, true);
                if (_fees != 0) {
                    emit ListingFeeCaptured(_collection, _tokenId, _fees);
                }
            }

            // If the floor multiple of the original listings is different, then this needs
            // to be paid to the original owner of the listing.
            uint listingFloorPrice = 1 ether * 10 ** collectionToken.denomination();
            if (listingPrice > listingFloorPrice) {
                unchecked {
                    collectionToken.transferFrom(msg.sender, oldListing.owner, listingPrice - listingFloorPrice);
                }
            }

            // Reduce the amount of listings
            unchecked { listingCount[_collection] -= 1; }
        }

        // Burn the tokens that the user provided as collateral, as we will have it minted
        // from {ProtectedListings}.
        collectionToken.burnFrom(msg.sender, _collateral * 10 ** collectionToken.denomination());

        // We can now pull in the tokens from the Locker
        locker.withdrawToken(_collection, _tokenId, address(this));
        IERC721(_collection).approve(address(protectedListings), _tokenId);

        // Create a protected listing, taking only the tokens
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = _tokenId;
        IProtectedListings.CreateListing[] memory createProtectedListing = new IProtectedListings.CreateListing[](1);
        createProtectedListing[0] = IProtectedListings.CreateListing({
            collection: _collection,
            tokenIds: tokenIds,
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: uint96(1 ether - _collateral),
                checkpoint: 0 // Set in the `createListings` call
            })
        });

        // Create our listing, receiving the ERC20 into this contract
        protectedListings.createListings(createProtectedListing);

        // We should now have received the non-collateral assets, which we will burn in
        // addition to the amount that the user sent us.
        collectionToken.burn((1 ether - _collateral) * 10 ** collectionToken.denomination());

        // We can now transfer ownership of the listing to the user reserving it
        protectedListings.transferOwnership(_collection, _tokenId, payable(msg.sender));
    }

    /**
     * Calculates the amount of listing tax required to create a listing for a collection. This
     * can be used by internal calls to validate against a complete `Listing` struct, rather than
     * individual parameters.
     */
    function getListingTaxRequired(Listing memory _listing, address _collection) public view returns (uint taxRequired_) {
        // Send our listing information to our {TaxCalculator} to calculate
        taxRequired_ = locker.taxCalculator().calculateTax(_collection, _listing.floorMultiple, _listing.duration);

        // Add our token denomination to support meme tokens
        taxRequired_ *= 10 ** locker.collectionToken(_collection).denomination();
    }

    /**
     * Handles the payment of tax from the calling using, optionally including the user's escrow
     * balance in the calculation. If `_payTaxWithEscrow` is `true`, then the escrow balance will
     * be prioritised to be used before transferring external tokens from the caller.
     *
     * @param _token The token used as payment
     * @param _taxRequired The amount of tax required to be paid
     * @param _payTaxWithEscrow If the user's escrow balance should be used
     */
    function payTaxWithEscrow(address _token, uint _taxRequired, bool _payTaxWithEscrow) private {
        // If we don't owe any tax, then we don't need to process anything
        if (_taxRequired == 0) {
            return;
        }

        // If the user has opted to pay with escrow, then we can remove some funds from
        // their balance to either partially or fully pay the required tax.
        if (_payTaxWithEscrow) {
            // Get the min value of NATIVE_TOKEN `balance` and `taxRequired`
            uint currentBalance = balances[msg.sender][_token];
            uint256 amountPayingFromEscrow = (currentBalance > _taxRequired) ? _taxRequired : currentBalance;

            // If we have an escrow balance available, then we can reduce the tax
            // required to be paid by the `msg.value` by that amount.
            if (amountPayingFromEscrow > 0) {
                unchecked {
                    _taxRequired -= amountPayingFromEscrow;

                    // The value will be attributed to the taxes paid and will then
                    // be handled later when taxes are resolved.
                    balances[msg.sender][_token] = currentBalance - amountPayingFromEscrow;
                }
            }
        }

        // If we still have an amount to repay, then send the tokens
        if (_taxRequired != 0) {
            ICollectionToken(_token).transferFrom(msg.sender, address(this), _taxRequired);
        }
    }

    /**
     * Determines the price and availability of a listing.
     *
     * @param _collection The collection of the listing
     * @param _tokenId The token ID of the listing
     *
     * @return isAvailable_ If the token is available to be purchased from Flayer
     * @return price_ The price in token terms
     *
     * TODO: Add tests for denominations
     */
    function getListingPrice(address _collection, uint _tokenId) public view returns (bool isAvailable_, uint price_) {
        // If the token is not currently held in our {Locker}, then the asset is not
        // currently available to be purchased.
        if (IERC721(_collection).ownerOf(_tokenId) != address(locker)) {
            return (isAvailable_, price_);
        }

        // Check if we have a protected listing attributed to this listing
        IProtectedListings.ProtectedListing memory protectedListing = protectedListings.listings(_collection, _tokenId);
        if (protectedListing.owner != address(0)) {
            return (false, price_);
        }

        // Load our collection into memory using a single read
        Listing memory listing = _listings[_collection][_tokenId];

        // Get our collection token's base price, accurate to the token's denomination
        price_ = 1 ether * 10 ** locker.collectionToken(_collection).denomination();

        // If we don't have a listing object against the token ID, then we just consider
        // it to be a Floor level asset.
        if (listing.owner == address(0)) {
            return (true, price_);
        }

        // Determine the listing price based on the floor multiple. If this is a dutch
        // listing then further calculations will be applied later.
        uint totalPrice = (price_ * uint(listing.floorMultiple)) / MIN_FLOOR_MULTIPLE;

        // This is an edge case, but protects against potential future logic. If the
        // listing starts in the future, then we can't sell the listing.
        if (listing.created > block.timestamp) {
            return (isAvailable_, totalPrice);
        }

        // Check if we have a dutch listing
        if (listing.duration >= MIN_DUTCH_DURATION && listing.duration <= MAX_DUTCH_DURATION) {
            // Check if we are beyond the dutching window, in which case it has hit floor
            if (block.timestamp > listing.created + listing.duration) {
                return (true, price_);
            }

            // Determine the additional amount above the 1.00
            uint multiple = totalPrice - price_;

            // Find the discount amount based on the amount of time passed. Determine the
            // discount rate by dividing the total amount by the duration.
            uint discount = (multiple * (block.timestamp - listing.created)) / listing.duration;

            // If the discount is greater than the multiple, then we just default to 1.00
            if (discount > multiple) {
                return (true, price_);
            }

            // If we are still within the dutch auction period, then we can calculate the
            // price against the discount.
            unchecked {
                return (true, totalPrice - discount);
            }
        }

        // Check if the liquid listing has expired and is in dutch
        uint dutchesAt = listing.created + listing.duration;
        if (dutchesAt < block.timestamp) {
            // Determine the additional amount above the 1.00
            uint multiple = totalPrice - price_;

            // Find the discount amount based on the amount of time passed. Determine the
            // discount rate by dividing the total amount by the duration.
            uint discount = (multiple * (block.timestamp - dutchesAt)) / LIQUID_DUTCH_DURATION;

            // If the discount is greater than the multiple, then we just default to 1.00
            if (discount > multiple) {
                return (true, price_);
            }

            // If we are still within the dutch auction period, then we can calculate the
            // price against the discount.
            unchecked {
                return (true, totalPrice - discount);
            }
        }

        // By this point, we just show the listing value as it should be for sale
        return (true, totalPrice);
    }

    /**
     * When a listing is filled or cancelled, then we need to do two things:
     *  - Refund any tax that was paid but will no longer be needed
     *  - Allocate paid fees to the {FeeCollector}
     */
    function _resolveListingTax(Listing memory _listing, address _collection, bool _action) private returns (uint fees_, uint refund_) {
        // If we have been passed a Floor item as the listing, then no tax should be handled
        if (_listing.owner == address(0)) {
            return (fees_, refund_);
        }

        // Get the amount of tax in total that will have been paid for this listing
        uint taxPaid = getListingTaxRequired(_listing, _collection);
        if (taxPaid == 0) {
            return (fees_, refund_);
        }

        // Get the amount of tax to be refunded. If the listing has already ended
        // then no refund will be offered.
        if (block.timestamp < _listing.created + _listing.duration) {
            refund_ = (_listing.duration - (block.timestamp - _listing.created)) * taxPaid / _listing.duration;
        }

        // Send paid tax fees to the {FeeCollector}
        unchecked {
            fees_ = (taxPaid > refund_) ? taxPaid - refund_ : 0;
        }

        if (_action) {
            ICollectionToken collectionToken = locker.collectionToken(_collection);

            if (fees_ != 0) {
                IBaseImplementation implementation = locker.implementation();

                collectionToken.approve(address(implementation), fees_);
                implementation.depositFees(_collection, 0, fees_);
            }

            // If there is tax to refund, then allocate it to the user via escrow
            if (refund_ != 0) {
                _deposit(_listing.owner, address(collectionToken), refund_);
            }
        }
    }

    /**
     * Determines the `ListingType` of a {Listing} data structure based on the values
     * of it's various parameters.
     */
    function getListingType(Listing memory _listing) public view returns (Enums.ListingType) {
        // If we cannot find a valid listing and get a null parameter value, then we know
        // that the listing does not exist and it is therefore just a base token.
        if (_listing.owner == address(0)) {
            return Enums.ListingType.NONE;
        }

        // If the listing was created as a dutch listing, or if the liquid listing has
        // expired, then this is a dutch listing.
        if (
            (_listing.duration >= MIN_DUTCH_DURATION && _listing.duration <= MAX_DUTCH_DURATION) ||
            _listing.created + _listing.duration < block.timestamp
        ) {
            return Enums.ListingType.DUTCH;
        }

        // For all other eventualities, we have a default liquid listing
        return Enums.ListingType.LIQUID;
    }

    /**
     * Allows the {ProtectedListings} contract to be updated.
     *
     * @dev This address has access to create liquidation listings.
     *
     * @param _protectedListings The {ProtectedListings} contract address
     */
    function setProtectedListings(address _protectedListings) public onlyOwner {
        protectedListings = IProtectedListings(_protectedListings);
        emit ProtectedListingsContractUpdated(_protectedListings);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /**
     * Uses inline assembly to access the Transient Storage's tload operation.
     *
     * @return value The value stored at the given location.
     */
    function _tload(bytes32 location) private view returns (uint value) {
        assembly {
            value := tload(location)
        }
    }

    /**
     * Helper modifier to prevent the attached function from being called if the {Locker} is paused.
     */
    modifier lockerNotPaused {
        // Ensure that the protocol is not paused
        if (locker.paused()) revert Paused();
        _;
    }

}
