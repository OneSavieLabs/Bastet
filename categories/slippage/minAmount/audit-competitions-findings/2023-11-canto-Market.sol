// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.19;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IBondingCurve} from "../interface/IBondingCurve.sol";
import {Turnstile} from "../interface/Turnstile.sol";

contract Market is ERC1155, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant NFT_FEE_BPS = 1_000; // 10%
    uint256 public constant HOLDER_CUT_BPS = 3_300; // 33%
    uint256 public constant CREATOR_CUT_BPS = 3_300; // 33%
    // Platform cut: 100% - HOLDER_CUT_BPS - CREATOR_CUT_BPS

    /// @notice Payment token
    IERC20 public immutable token;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of shares created
    uint256 public shareCount;

    /// @notice Stores the share ID of a given share name
    mapping(string => uint256) public shareIDs;

    struct ShareData {
        uint256 tokenCount; // Number of outstanding tokens
        uint256 tokensInCirculation; // Number of outstanding tokens - tokens that are minted as NFT, i.e. the number of tokens that receive fees
        uint256 shareHolderRewardsPerTokenScaled; // Accrued funds for the share holder per token, multiplied by 1e18 to avoid precision loss
        uint256 shareCreatorPool; // Unclaimed funds for the share creators
        address bondingCurve; // Bonding curve used for this share
        address creator; // Creator of the share
        string metadataURI; // URI of the metadata
    }

    /// @notice Stores the data for a given share ID
    mapping(uint256 => ShareData) public shareData;

    /// @notice Stores the bonding curve per share
    mapping(uint256 => address) public shareBondingCurves;

    /// @notice Bonding curves that can be used for shares
    mapping(address => bool) public whitelistedBondingCurves;

    /// @notice Stores the number of outstanding tokens per share and address
    mapping(uint256 => mapping(address => uint256)) public tokensByAddress;

    /// @notice Value of ShareData.shareHolderRewardsPerTokenScaled at the last time a user claimed their rewards
    mapping(uint256 => mapping(address => uint256)) public rewardsLastClaimedValue;

    /// @notice Unclaimed funds for the platform
    uint256 public platformPool;

    /// @notice If true, only the whitelisted addresses can create shares
    bool public shareCreationRestricted = true;

    /// @notice List of addresses that can add new shares when shareCreationRestricted is true
    mapping(address => bool) public whitelistedShareCreators;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event BondingCurveStateChange(address indexed curve, bool isWhitelisted);
    event ShareCreated(uint256 indexed id, string name, address indexed bondingCurve, address indexed creator);
    event SharesBought(uint256 indexed id, address indexed buyer, uint256 amount, uint256 price, uint256 fee);
    event SharesSold(uint256 indexed id, address indexed seller, uint256 amount, uint256 price, uint256 fee);
    event NFTsCreated(uint256 indexed id, address indexed creator, uint256 amount, uint256 fee);
    event NFTsBurned(uint256 indexed id, address indexed burner, uint256 amount, uint256 fee);
    event PlatformFeeClaimed(address indexed claimer, uint256 amount);
    event CreatorFeeClaimed(address indexed claimer, uint256 indexed id, uint256 amount);
    event HolderFeeClaimed(address indexed claimer, uint256 indexed id, uint256 amount);
    event ShareCreationRestricted(bool isRestricted);

    modifier onlyShareCreator() {
        require(
            !shareCreationRestricted || whitelistedShareCreators[msg.sender] || msg.sender == owner(),
            "Not allowed"
        );
        _;
    }

    /// @notice Initiates CSR on main- and testnet
    /// @param _uri ERC1155 Base URI
    /// @param _paymentToken Address of the payment token
    constructor(string memory _uri, address _paymentToken) ERC1155(_uri) Ownable() {
        token = IERC20(_paymentToken);
        if (block.chainid == 7700 || block.chainid == 7701) {
            // Register CSR on Canto main- and testnet
            Turnstile turnstile = Turnstile(0xEcf044C5B4b867CFda001101c617eCd347095B44);
            turnstile.register(tx.origin);
        }
    }

    /// @notice Whitelist or remove whitelist for a bonding curve.
    /// @dev Whitelisting status is only checked when adding a share
    /// @param _bondingCurve Address of the bonding curve
    /// @param _newState True if whitelisted, false if not
    function changeBondingCurveAllowed(address _bondingCurve, bool _newState) external onlyOwner {
        require(whitelistedBondingCurves[_bondingCurve] != _newState, "State already set");
        whitelistedBondingCurves[_bondingCurve] = _newState;
        emit BondingCurveStateChange(_bondingCurve, _newState);
    }

    /// @notice Creates a new share
    /// @param _shareName Name of the share
    /// @param _bondingCurve Address of the bonding curve, has to be whitelisted
    /// @param _metadataURI URI of the metadata
    function createNewShare(
        string memory _shareName,
        address _bondingCurve,
        string memory _metadataURI
    ) external onlyShareCreator returns (uint256 id) {
        require(whitelistedBondingCurves[_bondingCurve], "Bonding curve not whitelisted");
        require(shareIDs[_shareName] == 0, "Share already exists");
        id = ++shareCount;
        shareIDs[_shareName] = id;
        shareData[id].bondingCurve = _bondingCurve;
        shareData[id].creator = msg.sender;
        shareData[id].metadataURI = _metadataURI;
        emit ShareCreated(id, _shareName, _bondingCurve, msg.sender);
    }

    /// @notice Returns the price and fee for buying a given number of shares.
    /// @param _id The ID of the share
    /// @param _amount The number of shares to buy.
    function getBuyPrice(uint256 _id, uint256 _amount) public view returns (uint256 price, uint256 fee) {
        // If id does not exist, this will return address(0), causing a revert in the next line
        address bondingCurve = shareData[_id].bondingCurve;
        (price, fee) = IBondingCurve(bondingCurve).getPriceAndFee(shareData[_id].tokenCount + 1, _amount);
    }

    /// @notice Returns the price and fee for selling a given number of shares.
    /// @param _id The ID of the share
    /// @param _amount The number of shares to sell.
    function getSellPrice(uint256 _id, uint256 _amount) public view returns (uint256 price, uint256 fee) {
        // If id does not exist, this will return address(0), causing a revert in the next line
        address bondingCurve = shareData[_id].bondingCurve;
        (price, fee) = IBondingCurve(bondingCurve).getPriceAndFee(shareData[_id].tokenCount - _amount + 1, _amount);
    }

    /// @notice Buy amount of tokens for a given share ID
    /// @param _id ID of the share
    /// @param _amount Amount of shares to buy
    function buy(uint256 _id, uint256 _amount) external {
        require(shareData[_id].creator != msg.sender, "Creator cannot buy");
        (uint256 price, uint256 fee) = getBuyPrice(_id, _amount); // Reverts for non-existing ID
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), price + fee);
        // The reward calculation has to use the old rewards value (pre fee-split) to not include the fees of this buy
        // The rewardsLastClaimedValue then needs to be updated with the new value such that the user cannot claim fees of this buy
        uint256 rewardsSinceLastClaim = _getRewardsSinceLastClaim(_id);
        // Split the fee among holder, creator and platform
        _splitFees(_id, fee, shareData[_id].tokensInCirculation);
        rewardsLastClaimedValue[_id][msg.sender] = shareData[_id].shareHolderRewardsPerTokenScaled;

        shareData[_id].tokenCount += _amount;
        shareData[_id].tokensInCirculation += _amount;
        tokensByAddress[_id][msg.sender] += _amount;

        if (rewardsSinceLastClaim > 0) {
            SafeERC20.safeTransfer(token, msg.sender, rewardsSinceLastClaim);
        }
        emit SharesBought(_id, msg.sender, _amount, price, fee);
    }

    /// @notice Sell amount of tokens for a given share ID
    /// @param _id ID of the share
    /// @param _amount Amount of shares to sell
    function sell(uint256 _id, uint256 _amount) external {
        (uint256 price, uint256 fee) = getSellPrice(_id, _amount);
        // Split the fee among holder, creator and platform
        _splitFees(_id, fee, shareData[_id].tokensInCirculation);
        // The user also gets the rewards of his own sale (which is not the case for buys)
        uint256 rewardsSinceLastClaim = _getRewardsSinceLastClaim(_id);
        rewardsLastClaimedValue[_id][msg.sender] = shareData[_id].shareHolderRewardsPerTokenScaled;

        shareData[_id].tokenCount -= _amount;
        shareData[_id].tokensInCirculation -= _amount;
        tokensByAddress[_id][msg.sender] -= _amount; // Would underflow if user did not have enough tokens

        // Send the funds to the user
        SafeERC20.safeTransfer(token, msg.sender, rewardsSinceLastClaim + price - fee);
        emit SharesSold(_id, msg.sender, _amount, price, fee);
    }

    /// @notice Returns the price and fee for minting a given number of NFTs.
    /// @param _id The ID of the share
    /// @param _amount The number of NFTs to mint.
    function getNFTMintingPrice(uint256 _id, uint256 _amount) public view returns (uint256 fee) {
        address bondingCurve = shareData[_id].bondingCurve;
        (uint256 priceForOne, ) = IBondingCurve(bondingCurve).getPriceAndFee(shareData[_id].tokenCount, 1);
        fee = (priceForOne * _amount * NFT_FEE_BPS) / 10_000;
    }

    /// @notice Convert amount of tokens to NFTs for a given share ID
    /// @param _id ID of the share
    /// @param _amount Amount of tokens to convert. User needs to have this many tokens.
    function mintNFT(uint256 _id, uint256 _amount) external {
        uint256 fee = getNFTMintingPrice(_id, _amount);

        SafeERC20.safeTransferFrom(token, msg.sender, address(this), fee);
        _splitFees(_id, fee, shareData[_id].tokensInCirculation);
        // The user also gets the proportional rewards for the minting
        uint256 rewardsSinceLastClaim = _getRewardsSinceLastClaim(_id);
        rewardsLastClaimedValue[_id][msg.sender] = shareData[_id].shareHolderRewardsPerTokenScaled;
        tokensByAddress[_id][msg.sender] -= _amount;
        shareData[_id].tokensInCirculation -= _amount;

        _mint(msg.sender, _id, _amount, "");

        if (rewardsSinceLastClaim > 0) {
            SafeERC20.safeTransfer(token, msg.sender, rewardsSinceLastClaim);
        }
        // ERC1155 already logs, but we add this to have the price information
        emit NFTsCreated(_id, msg.sender, _amount, fee);
    }

    /// @notice Burn amount of NFTs for a given share ID to get back tokens
    /// @param _id ID of the share
    /// @param _amount Amount of NFTs to burn
    function burnNFT(uint256 _id, uint256 _amount) external {
        uint256 fee = getNFTMintingPrice(_id, _amount);

        SafeERC20.safeTransferFrom(token, msg.sender, address(this), fee);
        _splitFees(_id, fee, shareData[_id].tokensInCirculation);
        // The user does not get the proportional rewards for the burning (unless they have additional tokens that are not in the NFT)
        uint256 rewardsSinceLastClaim = _getRewardsSinceLastClaim(_id);
        rewardsLastClaimedValue[_id][msg.sender] = shareData[_id].shareHolderRewardsPerTokenScaled;
        tokensByAddress[_id][msg.sender] += _amount;
        shareData[_id].tokensInCirculation += _amount;
        _burn(msg.sender, _id, _amount);

        SafeERC20.safeTransfer(token, msg.sender, rewardsSinceLastClaim);
        // ERC1155 already logs, but we add this to have the price information
        emit NFTsBurned(_id, msg.sender, _amount, fee);
    }

    /// @notice Withdraws the accrued platform fee
    function claimPlatformFee() external onlyOwner {
        uint256 amount = platformPool;
        platformPool = 0;
        SafeERC20.safeTransfer(token, msg.sender, amount);
        emit PlatformFeeClaimed(msg.sender, amount);
    }

    /// @notice Withdraws the accrued share creator fee
    /// @param _id ID of the share
    function claimCreatorFee(uint256 _id) external {
        require(shareData[_id].creator == msg.sender, "Not creator");
        uint256 amount = shareData[_id].shareCreatorPool;
        shareData[_id].shareCreatorPool = 0;
        SafeERC20.safeTransfer(token, msg.sender, amount);
        emit CreatorFeeClaimed(msg.sender, _id, amount);
    }

    /// @notice Withdraws the accrued share holder fee
    /// @param _id ID of the share
    function claimHolderFee(uint256 _id) external {
        uint256 amount = _getRewardsSinceLastClaim(_id);
        rewardsLastClaimedValue[_id][msg.sender] = shareData[_id].shareHolderRewardsPerTokenScaled;
        if (amount > 0) {
            SafeERC20.safeTransfer(token, msg.sender, amount);
        }
        emit HolderFeeClaimed(msg.sender, _id, amount);
    }

    function _getRewardsSinceLastClaim(uint256 _id) internal view returns (uint256 amount) {
        uint256 lastClaimedValue = rewardsLastClaimedValue[_id][msg.sender];
        amount =
            ((shareData[_id].shareHolderRewardsPerTokenScaled - lastClaimedValue) * tokensByAddress[_id][msg.sender]) /
            1e18;
    }

    /// @notice Splits the fee among the share holder, creator and platform
    function _splitFees(
        uint256 _id,
        uint256 _fee,
        uint256 _tokenCount
    ) internal {
        uint256 shareHolderFee = (_fee * HOLDER_CUT_BPS) / 10_000;
        uint256 shareCreatorFee = (_fee * CREATOR_CUT_BPS) / 10_000;
        uint256 platformFee = _fee - shareHolderFee - shareCreatorFee;
        shareData[_id].shareCreatorPool += shareCreatorFee;
        if (_tokenCount > 0) {
            shareData[_id].shareHolderRewardsPerTokenScaled += (shareHolderFee * 1e18) / _tokenCount;
        } else {
            // If there are no tokens in circulation, the fee goes to the platform
            platformFee += shareHolderFee;
        }
        platformPool += platformFee;
    }

    /// @notice Restricts or unrestricts share creation
    /// @param _isRestricted True if restricted, false if not
    function restrictShareCreation(bool _isRestricted) external onlyOwner {
        require(shareCreationRestricted != _isRestricted, "State already set");
        shareCreationRestricted = _isRestricted;
        emit ShareCreationRestricted(_isRestricted);
    }

    /// @notice Adds or removes an address from the whitelist of share creators
    /// @param _address Address to add or remove
    /// @param _isWhitelisted True if whitelisted, false if not
    function changeShareCreatorWhitelist(address _address, bool _isWhitelisted) external onlyOwner {
        require(whitelistedShareCreators[_address] != _isWhitelisted, "State already set");
        whitelistedShareCreators[_address] = _isWhitelisted;
    }
}