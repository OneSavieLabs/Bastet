// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {BondBaseTeller, IBondAggregator, Authority} from "./bases/BondBaseTeller.sol";
import {IBondFixedTermTeller} from "./interfaces/IBondFixedTermTeller.sol";

import {TransferHelper} from "./lib/TransferHelper.sol";
import {FullMath} from "./lib/FullMath.sol";
import {ERC1155} from "./lib/ERC1155.sol";

/// @title Bond Fixed Term Teller
/// @notice Bond Fixed Term Teller Contract
/// @dev Bond Protocol is a permissionless system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Bond Fixed Term Teller is an implementation of the
///      Bond Base Teller contract specific to handling user bond transactions
///      and tokenizing bond markets where purchases vest in a fixed amount of time
///      (rounded to the day) as ERC1155 tokens.
///
/// @author Oighty, Zeus, Potted Meat, indigo
contract BondFixedTermTeller is BondBaseTeller, IBondFixedTermTeller, ERC1155 {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== EVENTS ========== */
    event ERC1155BondTokenCreated(uint256 tokenId, ERC20 indexed underlying, uint48 indexed expiry);

    /* ========== STATE VARIABLES ========== */

    mapping(uint256 => TokenMetadata) public tokenMetadata; // metadata for bond tokens

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address protocol_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondBaseTeller(protocol_, aggregator_, guardian_, authority_) {}

    /* ========== PURCHASE ========== */

    /// @notice             Handle payout to recipient
    /// @param recipient_   Address to receive payout
    /// @param payout_      Amount of payoutToken to be paid
    /// @param payoutToken_   Token to be paid out
    /// @param vesting_     Amount of time to vest from current timestamp
    /// @return expiry      Timestamp when the payout will vest
    function _handlePayout(
        address recipient_,
        uint256 payout_,
        ERC20 payoutToken_,
        uint48 vesting_
    ) internal override returns (uint48 expiry) {
        // If there is no vesting time, the deposit is treated as an instant swap.
        // otherwise, deposit info is stored and payout is available at a future timestamp.
        // instant swap is denoted by expiry == 0.
        //
        // bonds mature with a cliff at a set timestamp
        // prior to the expiry timestamp, no payout tokens are accessible to the user
        // after the expiry timestamp, the entire payout can be redeemed
        //
        // fixed-term bonds mature in a set amount of time from deposit
        // i.e. term = 1 week. when alice deposits on day 1, her bond
        // expires on day 8. when bob deposits on day 2, his bond expires day 9.
        if (vesting_ != 0) {
            // Normalizing fixed term vesting timestamps to the same time each day
            expiry = ((vesting_ + uint48(block.timestamp)) / uint48(1 days)) * uint48(1 days);

            // Fixed-term user payout information is handled in BondTeller.
            // Teller mints ERC-1155 bond tokens for user.
            uint256 tokenId = getTokenId(payoutToken_, expiry);

            // Create new bond token if it doesn't exist yet
            if (!tokenMetadata[tokenId].active) {
                _deploy(tokenId, payoutToken_, expiry);
            }

            // Mint bond token to recipient
            _mintToken(recipient_, tokenId, payout_);
        } else {
            // If no expiry, then transfer payout directly to user
            payoutToken_.safeTransfer(recipient_, payout_);
        }
    }

    /* ========== DEPOSIT/MINT ========== */

    /// @inheritdoc IBondFixedTermTeller
    function create(
        ERC20 underlying_,
        uint48 expiry_,
        uint256 amount_
    ) external override nonReentrant returns (uint256, uint256) {
        // Revert if expiry is in the past
        if (expiry_ < block.timestamp) revert Teller_InvalidParams();

        uint256 tokenId = getTokenId(underlying_, expiry_);

        // Revert if no token exists, must call deploy first
        if (!tokenMetadata[tokenId].active) revert Teller_TokenDoesNotExist(underlying_, expiry_);

        // Transfer in underlying
        // Check that amount received is not less than amount expected
        // Handles edge cases like fee-on-transfer tokens (which are not supported)
        uint256 oldBalance = underlying_.balanceOf(address(this));
        underlying_.safeTransferFrom(msg.sender, address(this), amount_);
        if (underlying_.balanceOf(address(this)) < oldBalance + amount_)
            revert Teller_UnsupportedToken();

        // If fee is greater than the create discount, then calculate the fee and store it
        // Otherwise, fee is zero.
        if (protocolFee > createFeeDiscount) {
            // Calculate fee amount
            uint256 feeAmount = amount_.mulDiv(protocolFee - createFeeDiscount, FEE_DECIMALS);
            rewards[_protocol][underlying_] += feeAmount;

            // Mint new bond tokens
            _mintToken(msg.sender, tokenId, amount_ - feeAmount);

            return (tokenId, amount_ - feeAmount);
        } else {
            // Mint new bond tokens
            _mintToken(msg.sender, tokenId, amount_);

            return (tokenId, amount_);
        }
    }

    /* ========== REDEEM ========== */

    function _redeem(uint256 tokenId_, uint256 amount_) internal {
        // Check that the tokenId is active
        if (!tokenMetadata[tokenId_].active) revert Teller_InvalidParams();

        // Cache token metadata
        TokenMetadata memory meta = tokenMetadata[tokenId_];

        // Check that the token has matured
        if (block.timestamp < meta.expiry) revert Teller_TokenNotMatured(meta.expiry);

        // Burn bond token and transfer underlying to sender
        _burnToken(msg.sender, tokenId_, amount_);
        meta.underlying.safeTransfer(msg.sender, amount_);
    }

    /// @inheritdoc IBondFixedTermTeller
    function redeem(uint256 tokenId_, uint256 amount_) public override nonReentrant {
        _redeem(tokenId_, amount_);
    }

    /// @inheritdoc IBondFixedTermTeller
    function batchRedeem(uint256[] calldata tokenIds_, uint256[] calldata amounts_)
        external
        override
        nonReentrant
    {
        uint256 len = tokenIds_.length;
        if (len != amounts_.length) revert Teller_InvalidParams();
        for (uint256 i; i < len; ++i) {
            _redeem(tokenIds_[i], amounts_[i]);
        }
    }

    /* ========== TOKENIZATION ========== */

    /// @inheritdoc IBondFixedTermTeller
    function deploy(ERC20 underlying_, uint48 expiry_)
        external
        override
        nonReentrant
        returns (uint256)
    {
        uint256 tokenId = getTokenId(underlying_, expiry_);
        // Only creates token if it does not exist
        if (!tokenMetadata[tokenId].active) {
            _deploy(tokenId, underlying_, expiry_);
        }
        return tokenId;
    }

    /// @notice             "Deploy" a new ERC1155 bond token and stores its ID
    /// @dev                ERC1155 tokens used for fixed term bonds
    /// @param tokenId_     Calculated ID of new bond token (from getTokenId)
    /// @param underlying_  Underlying token to be paid out when the bond token vests
    /// @param expiry_      Timestamp that the token will vest at
    function _deploy(
        uint256 tokenId_,
        ERC20 underlying_,
        uint48 expiry_
    ) internal {
        // Revert if expiry is in the past
        if (uint256(expiry_) < block.timestamp) revert Teller_InvalidParams();

        // Store token metadata
        tokenMetadata[tokenId_] = TokenMetadata(
            true,
            underlying_,
            uint8(underlying_.decimals()),
            expiry_,
            0
        );

        emit ERC1155BondTokenCreated(tokenId_, underlying_, expiry_);
    }

    /// @notice             Mint bond token and update supply
    /// @param to_          Address to mint tokens to
    /// @param tokenId_     ID of bond token to mint
    /// @param amount_      Amount of bond tokens to mint
    function _mintToken(
        address to_,
        uint256 tokenId_,
        uint256 amount_
    ) internal {
        _mint(to_, tokenId_, amount_, bytes(""));
        tokenMetadata[tokenId_].supply += amount_;
    }

    /// @notice             Burn bond token and update supply
    /// @param from_        Address to burn tokens from
    /// @param tokenId_     ID of bond token to burn
    /// @param amount_      Amount of bond token to burn
    function _burnToken(
        address from_,
        uint256 tokenId_,
        uint256 amount_
    ) internal {
        _burn(from_, tokenId_, amount_);
        tokenMetadata[tokenId_].supply -= amount_;
    }

    /* ========== TOKEN NAMING ========== */

    /// @inheritdoc IBondFixedTermTeller
    function getTokenId(ERC20 underlying_, uint48 expiry_) public pure override returns (uint256) {
        // Vesting is divided by 1 day (in seconds) since bond tokens are only unique
        // to a day, not a specific timestamp.
        uint256 tokenId = uint256(
            keccak256(abi.encodePacked(underlying_, expiry_ / uint48(1 days)))
        );
        return tokenId;
    }

    /// @inheritdoc IBondFixedTermTeller
    function getTokenNameAndSymbol(uint256 tokenId_)
        external
        view
        override
        returns (string memory, string memory)
    {
        TokenMetadata memory meta = tokenMetadata[tokenId_];
        (string memory name, string memory symbol) = _getNameAndSymbol(
            meta.underlying,
            meta.expiry
        );
        return (name, symbol);
    }
}
