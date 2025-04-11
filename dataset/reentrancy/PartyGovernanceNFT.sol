// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "../utils/ReadOnlyDelegateCall.sol";
import "../utils/LibSafeCast.sol";
import "../utils/LibAddress.sol";
import "openzeppelin/contracts/interfaces/IERC2981.sol";
import "../globals/IGlobals.sol";
import "../tokens/IERC721.sol";
import "../vendor/solmate/ERC721.sol";
import "./PartyGovernance.sol";
import "../renderers/RendererStorage.sol";

/// @notice ERC721 functionality built on top of `PartyGovernance`.
contract PartyGovernanceNFT is PartyGovernance, ERC721, IERC2981 {
    using LibSafeCast for uint256;
    using LibSafeCast for uint96;
    using LibERC20Compat for IERC20;
    using LibAddress for address payable;

    error OnlyAuthorityError();
    error OnlySelfError();
    error UnauthorizedToBurnError();
    error FixedRageQuitTimestampError(uint40 rageQuitTimestamp);
    error CannotRageQuitError(uint40 rageQuitTimestamp);
    error CannotDisableRageQuitAfterInitializationError();
    error InvalidTokenOrderError();

    event AuthorityAdded(address indexed authority);
    event AuthorityRemoved(address indexed authority);
    event RageQuitSet(uint40 oldRageQuitTimestamp, uint40 newRageQuitTimestamp);
    event RageQuit(uint256[] indexed tokenIds, IERC20[] withdrawTokens, address receiver);

    uint40 private constant ENABLE_RAGEQUIT_PERMANENTLY = 0x6b5b567bfe; // uint40(uint256(keccak256("ENABLE_RAGEQUIT_PERMANENTLY")))
    uint40 private constant DISABLE_RAGEQUIT_PERMANENTLY = 0xab2cb21860; // uint40(uint256(keccak256("DISABLE_RAGEQUIT_PERMANENTLY")))

    // Token address used to indicate ETH.
    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // The `Globals` contract storing global configuration values. This contract
    // is immutable and its address will never change.
    IGlobals private immutable _GLOBALS;

    /// @notice The number of tokens that have been minted.
    uint96 public tokenCount;
    /// @notice The total minted voting power.
    ///         Capped to `_governanceValues.totalVotingPower` unless minting
    ///         party cards for initial crowdfund.
    uint96 public mintedVotingPower;
    /// @notice The timestamp until which ragequit is enabled. Can be set to the
    ///         `ENABLE_RAGEQUIT_PERMANENTLY`/`DISABLE_RAGEQUIT_PERMANENTLY`
    ///         values to enable/disable ragequit permanently.
    ///         `DISABLE_RAGEQUIT_PERMANENTLY` can only be set during
    ///         initialization.
    uint40 public rageQuitTimestamp;
    /// @notice The voting power of `tokenId`.
    mapping(uint256 => uint256) public votingPowerByTokenId;
    /// @notice Address with authority to mint cards and update voting power for the party.
    mapping(address => bool) public isAuthority;

    modifier onlyAuthority() {
        if (!isAuthority[msg.sender]) {
            revert OnlyAuthorityError();
        }
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert OnlySelfError();
        }
        _;
    }

    // Set the `Globals` contract. The name or symbol of ERC721 does not matter;
    // it will be set in `_initialize()`.
    constructor(IGlobals globals) payable PartyGovernance(globals) ERC721("", "") {
        _GLOBALS = globals;
    }

    // Initialize storage for proxy contracts.
    function _initialize(
        string memory name_,
        string memory symbol_,
        uint256 customizationPresetId,
        PartyGovernance.GovernanceOpts memory governanceOpts,
        ProposalStorage.ProposalEngineOpts memory proposalEngineOpts,
        IERC721[] memory preciousTokens,
        uint256[] memory preciousTokenIds,
        address[] memory authorities,
        uint40 rageQuitTimestamp_
    ) internal {
        PartyGovernance._initialize(
            governanceOpts,
            proposalEngineOpts,
            preciousTokens,
            preciousTokenIds
        );
        name = name_;
        symbol = symbol_;
        rageQuitTimestamp = rageQuitTimestamp_;
        unchecked {
            for (uint256 i; i < authorities.length; ++i) {
                isAuthority[authorities[i]] = true;
            }
        }
        if (customizationPresetId != 0) {
            RendererStorage(_GLOBALS.getAddress(LibGlobals.GLOBAL_RENDERER_STORAGE))
                .useCustomizationPreset(customizationPresetId);
        }
    }

    /// @inheritdoc ERC721
    function ownerOf(
        uint256 tokenId
    ) public view override(ERC721, ITokenDistributorParty) returns (address owner) {
        return ERC721.ownerOf(tokenId);
    }

    /// @inheritdoc EIP165
    function supportsInterface(
        bytes4 interfaceId
    ) public pure override(PartyGovernance, ERC721, IERC165) returns (bool) {
        return
            PartyGovernance.supportsInterface(interfaceId) ||
            ERC721.supportsInterface(interfaceId) ||
            interfaceId == type(IERC2981).interfaceId;
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256) public view override returns (string memory) {
        _delegateToRenderer();
        return ""; // Just to make the compiler happy.
    }

    /// @notice Returns a URI for the storefront-level metadata for your contract.
    function contractURI() external view returns (string memory) {
        _delegateToRenderer();
        return ""; // Just to make the compiler happy.
    }

    /// @notice Called with the sale price to determine how much royalty
    //          is owed and to whom.
    function royaltyInfo(uint256, uint256) external view returns (address, uint256) {
        _delegateToRenderer();
        return (address(0), 0); // Just to make the compiler happy.
    }

    /// @inheritdoc ITokenDistributorParty
    function getDistributionShareOf(uint256 tokenId) public view returns (uint256) {
        uint256 totalVotingPower = _governanceValues.totalVotingPower;

        if (totalVotingPower == 0) {
            return 0;
        } else {
            return (votingPowerByTokenId[tokenId] * 1e18) / totalVotingPower;
        }
    }

    /// @notice Mint a governance NFT for `owner` with `votingPower` and
    ///         immediately delegate voting power to `delegate.` Only callable
    ///         by an authority.
    /// @param owner The owner of the NFT.
    /// @param votingPower The voting power of the NFT.
    /// @param delegate The address to delegate voting power to.
    function mint(
        address owner,
        uint256 votingPower,
        address delegate
    ) external onlyAuthority onlyDelegateCall returns (uint256 tokenId) {
        uint96 mintedVotingPower_ = mintedVotingPower;
        uint96 totalVotingPower = _governanceValues.totalVotingPower;

        // Cap voting power to remaining unminted voting power supply.
        uint96 votingPower_ = votingPower.safeCastUint256ToUint96();
        // Allow minting past total voting power if minting party cards for
        // initial crowdfund when there is no total voting power.
        if (totalVotingPower != 0 && totalVotingPower - mintedVotingPower_ < votingPower_) {
            votingPower_ = totalVotingPower - mintedVotingPower_;
        }

        // Update state.
        unchecked {
            tokenId = ++tokenCount;
        }
        mintedVotingPower += votingPower_;
        votingPowerByTokenId[tokenId] = votingPower_;

        // Use delegate from party over the one set during crowdfund.
        address delegate_ = delegationsByVoter[owner];
        if (delegate_ != address(0)) {
            delegate = delegate_;
        }

        _adjustVotingPower(owner, votingPower_.safeCastUint96ToInt192(), delegate);
        _safeMint(owner, tokenId);
    }

    /// @notice Add voting power to an existing NFT. Only callable by an
    ///         authority.
    /// @param tokenId The ID of the NFT to add voting power to.
    /// @param votingPower The amount of voting power to add.
    function addVotingPower(
        uint256 tokenId,
        uint256 votingPower
    ) external onlyAuthority onlyDelegateCall {
        uint96 mintedVotingPower_ = mintedVotingPower;
        uint96 totalVotingPower = _governanceValues.totalVotingPower;
        // Cap voting power to remaining unminted voting power supply.
        uint96 votingPower_ = votingPower.safeCastUint256ToUint96();
        // Allow minting past total voting power if minting party cards for
        // initial crowdfund when there is no total voting power.
        if (totalVotingPower != 0 && totalVotingPower - mintedVotingPower_ < votingPower_) {
            votingPower_ = totalVotingPower - mintedVotingPower_;
        }

        // Update state.
        mintedVotingPower += votingPower_;
        votingPowerByTokenId[tokenId] += votingPower_;

        _adjustVotingPower(ownerOf(tokenId), votingPower_.safeCastUint96ToInt192(), address(0));
    }

    /// @notice Update the total voting power of the party. Only callable by
    ///         an authority.
    /// @param newVotingPower The new total voting power to add.
    function increaseTotalVotingPower(
        uint96 newVotingPower
    ) external onlyAuthority onlyDelegateCall {
        _governanceValues.totalVotingPower += newVotingPower;
    }

    /// @notice Burn a governance NFT and remove its voting power.
    /// @param tokenId The ID of the NFT to burn.
    function burn(uint256 tokenId) public onlyDelegateCall {
        address owner = ownerOf(tokenId);
        uint96 totalVotingPower = _governanceValues.totalVotingPower;
        bool authority = isAuthority[msg.sender];
        if (
            msg.sender != owner &&
            getApproved[tokenId] != msg.sender &&
            !isApprovedForAll[owner][msg.sender]
        ) {
            // Allow authority to burn cards if the total voting power has not yet
            // been set (e.g. for initial crowdfunds) meaning the party has not
            // yet started.
            if (totalVotingPower != 0 || !authority) revert UnauthorizedToBurnError();
        }

        // Update last burn timestamp.
        lastBurnTimestamp = uint40(block.timestamp);

        uint96 votingPower = votingPowerByTokenId[tokenId].safeCastUint256ToUint96();
        mintedVotingPower -= votingPower;
        delete votingPowerByTokenId[tokenId];

        if (totalVotingPower != 0) {
            _governanceValues.totalVotingPower = totalVotingPower - votingPower;
        } else {
            if (!authority) revert OnlyAuthorityError();
        }

        _adjustVotingPower(owner, -votingPower.safeCastUint96ToInt192(), address(0));

        _burn(tokenId);
    }

    /// @notice Set the timestamp until which ragequit is enabled.
    /// @param newRageQuitTimestamp The new ragequit timestamp.
    function setRageQuit(uint40 newRageQuitTimestamp) external onlyHost {
        uint40 oldRageQuitTimestamp = rageQuitTimestamp;

        // Prevent disabling ragequit after initialization.
        if (newRageQuitTimestamp == DISABLE_RAGEQUIT_PERMANENTLY) {
            revert CannotDisableRageQuitAfterInitializationError();
        }

        // Prevent setting timestamp if it is permanently enabled/disabled.
        if (
            oldRageQuitTimestamp == ENABLE_RAGEQUIT_PERMANENTLY ||
            oldRageQuitTimestamp == DISABLE_RAGEQUIT_PERMANENTLY
        ) {
            revert FixedRageQuitTimestampError(oldRageQuitTimestamp);
        }

        emit RageQuitSet(oldRageQuitTimestamp, rageQuitTimestamp = newRageQuitTimestamp);
    }

    /// @notice Burn a governance NFT and withdraw a fair share of fungible tokens from the party.
    /// @param tokenIds The IDs of the governance NFTs to burn.
    /// @param withdrawTokens The fungible tokens to withdraw.
    /// @param receiver The address to receive the withdrawn tokens.
    function rageQuit(
        uint256[] calldata tokenIds,
        IERC20[] calldata withdrawTokens,
        address receiver
    ) external {
        // Check if ragequit is allowed.
        uint40 currentRageQuitTimestamp = rageQuitTimestamp;
        if (currentRageQuitTimestamp != ENABLE_RAGEQUIT_PERMANENTLY) {
            if (
                currentRageQuitTimestamp == DISABLE_RAGEQUIT_PERMANENTLY ||
                currentRageQuitTimestamp < block.timestamp
            ) {
                revert CannotRageQuitError(currentRageQuitTimestamp);
            }
        }

        // Used as a reentrancy guard. Will be updated back after ragequit.
        delete rageQuitTimestamp;

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];

            // Must be retrieved before burning the token.
            uint256 shareOfVotingPower = getDistributionShareOf(tokenId);

            // Burn caller's party card. This will revert if caller is not the owner
            // of the card.
            burn(tokenId);

            // Withdraw fair share of tokens from the party.
            IERC20 prevToken;
            for (uint256 j; j < withdrawTokens.length; ++j) {
                IERC20 token = withdrawTokens[j];

                // Prevent null and duplicate transfers.
                if (prevToken >= token) revert InvalidTokenOrderError();

                prevToken = token;

                // Check if token is ETH.
                if (address(token) == ETH_ADDRESS) {
                    // Transfer fair share of ETH to receiver.
                    uint256 amount = (address(this).balance * shareOfVotingPower) / 1e18;
                    if (amount != 0) {
                        payable(receiver).transferEth(amount);
                    }
                } else {
                    // Transfer fair share of tokens to receiver.
                    uint256 amount = (token.balanceOf(address(this)) * shareOfVotingPower) / 1e18;
                    if (amount != 0) {
                        token.compatTransfer(receiver, amount);
                    }
                }
            }
        }

        // Update ragequit timestamp back to before.
        rageQuitTimestamp = currentRageQuitTimestamp;

        emit RageQuit(tokenIds, withdrawTokens, receiver);
    }

    /// @inheritdoc ERC721
    function transferFrom(
        address owner,
        address to,
        uint256 tokenId
    ) public override onlyDelegateCall {
        // Transfer voting along with token.
        _transferVotingPower(owner, to, votingPowerByTokenId[tokenId]);
        super.transferFrom(owner, to, tokenId);
    }

    /// @inheritdoc ERC721
    function safeTransferFrom(
        address owner,
        address to,
        uint256 tokenId
    ) public override onlyDelegateCall {
        // super.safeTransferFrom() will call transferFrom() first which will
        // transfer voting power.
        super.safeTransferFrom(owner, to, tokenId);
    }

    /// @inheritdoc ERC721
    function safeTransferFrom(
        address owner,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) public override onlyDelegateCall {
        // super.safeTransferFrom() will call transferFrom() first which will
        // transfer voting power.
        super.safeTransferFrom(owner, to, tokenId, data);
    }

    /// @notice Add a new authority.
    /// @dev Used in `AddAuthorityProposal`. Only the party itself can add
    ///      authorities to prevent it from being used anywhere else.
    function addAuthority(address authority) external onlySelf onlyDelegateCall {
        isAuthority[authority] = true;

        emit AuthorityAdded(authority);
    }

    /// @notice Relinquish the authority role.
    function abdicateAuthority() external onlyAuthority onlyDelegateCall {
        delete isAuthority[msg.sender];

        emit AuthorityRemoved(msg.sender);
    }

    function _delegateToRenderer() private view {
        _readOnlyDelegateCall(
            // Instance of IERC721Renderer.
            _GLOBALS.getAddress(LibGlobals.GLOBAL_GOVERNANCE_NFT_RENDER_IMPL),
            msg.data
        );
        assert(false); // Will not be reached.
    }
}
