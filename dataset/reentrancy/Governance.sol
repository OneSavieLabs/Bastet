// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

// The Governance Policy submits & activates instructions in a INSTR module

import {OlympusInstructions} from "modules/INSTR.sol";
import {OlympusVotes} from "modules/VOTES.sol";
import "src/Kernel.sol";

// proposing
error NotEnoughVotesToPropose();

// endorsing
error CannotEndorseNullProposal();
error CannotEndorseInvalidProposal();

// activating
error NotAuthorizedToActivateProposal();
error NotEnoughEndorsementsToActivateProposal();
error ProposalAlreadyActivated();
error ActiveProposalNotExpired();
error SubmittedProposalHasExpired();

// voting
error NoActiveProposalDetected();
error UserAlreadyVoted();

// executing
error NotEnoughVotesToExecute();
error ExecutionTimelockStillActive();

// claiming
error VotingTokensAlreadyReclaimed();
error CannotReclaimTokensForActiveVote();
error CannotReclaimZeroVotes();

struct ProposalMetadata {
    bytes32 title;
    address submitter;
    uint256 submissionTimestamp;
    string proposalURI;
}

struct ActivatedProposal {
    uint256 proposalId;
    uint256 activationTimestamp;
}

/// @notice OlympusGovernance
/// @dev The Governor Policy is also the Kernel's Executor.
contract OlympusGovernance is Policy {
    /////////////////////////////////////////////////////////////////////////////////
    //                         Kernel Policy Configuration                         //
    /////////////////////////////////////////////////////////////////////////////////

    OlympusInstructions public INSTR;
    OlympusVotes public VOTES;

    constructor(Kernel kernel_) Policy(kernel_) {}

    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("INSTR");
        dependencies[1] = toKeycode("VOTES");

        INSTR = OlympusInstructions(getModuleAddress(dependencies[0]));
        VOTES = OlympusVotes(getModuleAddress(dependencies[1]));
    }

    function requestPermissions()
        external
        view
        override
        onlyKernel
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](2);
        requests[0] = Permissions(INSTR.KEYCODE(), INSTR.store.selector);
        requests[1] = Permissions(VOTES.KEYCODE(), VOTES.transferFrom.selector);
    }

    /////////////////////////////////////////////////////////////////////////////////
    //                             Policy Variables                                //
    /////////////////////////////////////////////////////////////////////////////////

    event ProposalSubmitted(uint256 proposalId);
    event ProposalEndorsed(uint256 proposalId, address voter, uint256 amount);
    event ProposalActivated(uint256 proposalId, uint256 timestamp);
    event WalletVoted(uint256 proposalId, address voter, bool for_, uint256 userVotes);
    event ProposalExecuted(uint256 proposalId);

    /// @notice The currently activated proposal in the governance system.
    ActivatedProposal public activeProposal;

    /// @notice Return a proposal metadata object for a given proposal id.
    mapping(uint256 => ProposalMetadata) public getProposalMetadata;

    /// @notice Return the total endorsements for a proposal id.
    mapping(uint256 => uint256) public totalEndorsementsForProposal;

    /// @notice Return the number of endorsements a user has given a proposal id.
    mapping(uint256 => mapping(address => uint256)) public userEndorsementsForProposal;

    /// @notice Return whether a proposal id has been activated. Once this is true, it should never be flipped false.
    mapping(uint256 => bool) public proposalHasBeenActivated;

    /// @notice Return the total yes votes for a proposal id used in calculating net votes.
    mapping(uint256 => uint256) public yesVotesForProposal;

    /// @notice Return the total no votes for a proposal id used in calculating net votes.
    mapping(uint256 => uint256) public noVotesForProposal;

    /// @notice Return the amount of votes a user has applied to a proposal id. This does not record how the user voted.
    mapping(uint256 => mapping(address => uint256)) public userVotesForProposal;

    /// @notice Return the amount of tokens reclaimed by a user after voting on a proposal id.
    mapping(uint256 => mapping(address => bool)) public tokenClaimsForProposal;

    /// @notice The amount of votes a proposer needs in order to submit a proposal as a percentage of total supply (in basis points).
    /// @dev    This is set to 1% of the total supply.
    uint256 public constant SUBMISSION_REQUIREMENT = 100;

    /// @notice Amount of time a submitted proposal has to activate before it expires.
    uint256 public constant ACTIVATION_DEADLINE = 2 weeks;

    /// @notice Amount of time an activated proposal must stay up before it can be replaced by a new activated proposal.
    uint256 public constant GRACE_PERIOD = 1 weeks;

    /// @notice Endorsements required to activate a proposal as percentage of total supply.
    uint256 public constant ENDORSEMENT_THRESHOLD = 20;

    /// @notice Net votes required to execute a proposal on chain as a percentage of total supply.
    uint256 public constant EXECUTION_THRESHOLD = 33;

    /// @notice Required time for a proposal to be active before it can be executed.
    /// @dev    This amount should be greater than 0 to prevent flash loan attacks.
    uint256 public constant EXECUTION_TIMELOCK = 3 days;

    /////////////////////////////////////////////////////////////////////////////////
    //                               User Actions                                  //
    /////////////////////////////////////////////////////////////////////////////////

    /// @notice Return the metadata for a proposal.
    /// @dev    Used to return & access the entire metadata struct in solidity
    function getMetadata(uint256 proposalId_) public view returns (ProposalMetadata memory) {
        return getProposalMetadata[proposalId_];
    }

    /// @notice Return the currently active proposal in governance.
    /// @dev    Used to return & access the entire struct active proposal struct in solidity.
    function getActiveProposal() public view returns (ActivatedProposal memory) {
        return activeProposal;
    }

    /// @notice Submit an on chain governance proposal.
    /// @param  instructions_ - an array of Instruction objects each containing a Kernel Action and a target Contract address.
    /// @param  title_ - a human-readable title of the proposal — i.e. "OIP XX - My Proposal Title".
    /// @param  proposalURI_ - an arbitrary url linking to a human-readable description of the proposal - i.e. Snapshot, Discourse, Google Doc.
    function submitProposal(
        Instruction[] calldata instructions_,
        bytes32 title_,
        string memory proposalURI_
    ) external {
        if (VOTES.balanceOf(msg.sender) * 10000 < VOTES.totalSupply() * SUBMISSION_REQUIREMENT)
            revert NotEnoughVotesToPropose();

        uint256 proposalId = INSTR.store(instructions_);
        getProposalMetadata[proposalId] = ProposalMetadata(
            title_,
            msg.sender,
            block.timestamp,
            proposalURI_
        );

        emit ProposalSubmitted(proposalId);
    }

    /// @notice Endorse a proposal.
    /// @param  proposalId_ - The ID of the proposal being endorsed.
    function endorseProposal(uint256 proposalId_) external {
        uint256 userVotes = VOTES.balanceOf(msg.sender);

        if (proposalId_ == 0) {
            revert CannotEndorseNullProposal();
        }

        Instruction[] memory instructions = INSTR.getInstructions(proposalId_);
        if (instructions.length == 0) {
            revert CannotEndorseInvalidProposal();
        }

        // undo any previous endorsement the user made on these instructions
        uint256 previousEndorsement = userEndorsementsForProposal[proposalId_][msg.sender];
        totalEndorsementsForProposal[proposalId_] -= previousEndorsement;

        // reapply user endorsements with most up-to-date votes
        userEndorsementsForProposal[proposalId_][msg.sender] = userVotes;
        totalEndorsementsForProposal[proposalId_] += userVotes;

        emit ProposalEndorsed(proposalId_, msg.sender, userVotes);
    }

    /// @notice Activate a proposal.
    /// @param  proposalId_ - The ID of the proposal being activated.
    function activateProposal(uint256 proposalId_) external {
        ProposalMetadata memory proposal = getProposalMetadata[proposalId_];

        if (msg.sender != proposal.submitter) {
            revert NotAuthorizedToActivateProposal();
        }

        if (block.timestamp > proposal.submissionTimestamp + ACTIVATION_DEADLINE) {
            revert SubmittedProposalHasExpired();
        }

        if (
            (totalEndorsementsForProposal[proposalId_] * 100) <
            VOTES.totalSupply() * ENDORSEMENT_THRESHOLD
        ) {
            revert NotEnoughEndorsementsToActivateProposal();
        }

        if (proposalHasBeenActivated[proposalId_] == true) {
            revert ProposalAlreadyActivated();
        }

        if (block.timestamp < activeProposal.activationTimestamp + GRACE_PERIOD) {
            revert ActiveProposalNotExpired();
        }

        activeProposal = ActivatedProposal(proposalId_, block.timestamp);

        proposalHasBeenActivated[proposalId_] = true;

        emit ProposalActivated(proposalId_, block.timestamp);
    }

    /// @notice Cast a vote for the currently active proposal.
    /// @param  for_ - A boolean representing the vote: true for yes, false for no.
    function vote(bool for_) external {
        uint256 userVotes = VOTES.balanceOf(msg.sender);

        if (activeProposal.proposalId == 0) {
            revert NoActiveProposalDetected();
        }

        if (userVotesForProposal[activeProposal.proposalId][msg.sender] > 0) {
            revert UserAlreadyVoted();
        }

        if (for_) {
            yesVotesForProposal[activeProposal.proposalId] += userVotes;
        } else {
            noVotesForProposal[activeProposal.proposalId] += userVotes;
        }

        userVotesForProposal[activeProposal.proposalId][msg.sender] = userVotes;

        VOTES.transferFrom(msg.sender, address(this), userVotes);

        emit WalletVoted(activeProposal.proposalId, msg.sender, for_, userVotes);
    }

    /// @notice Execute the currently active proposal.
    function executeProposal() external {
        uint256 netVotes = yesVotesForProposal[activeProposal.proposalId] -
            noVotesForProposal[activeProposal.proposalId];
        if (netVotes * 100 < VOTES.totalSupply() * EXECUTION_THRESHOLD) {
            revert NotEnoughVotesToExecute();
        }

        if (block.timestamp < activeProposal.activationTimestamp + EXECUTION_TIMELOCK) {
            revert ExecutionTimelockStillActive();
        }

        Instruction[] memory instructions = INSTR.getInstructions(activeProposal.proposalId);

        for (uint256 step; step < instructions.length; ) {
            kernel.executeAction(instructions[step].action, instructions[step].target);
            unchecked {
                ++step;
            }
        }

        emit ProposalExecuted(activeProposal.proposalId);

        // deactivate the active proposal
        activeProposal = ActivatedProposal(0, 0);
    }

    /// @notice Reclaim locked votes from the contract after the proposal is no longer active.
    /// @dev    The governance contract locks casted votes into the contract until the proposal
    ///         is no longer active to prevent repeated voting with the same tokens.
    /// @param  proposalId_ - The proposal that the user is reclaiming tokens for.
    function reclaimVotes(uint256 proposalId_) external {
        uint256 userVotes = userVotesForProposal[proposalId_][msg.sender];

        if (userVotes == 0) {
            revert CannotReclaimZeroVotes();
        }

        if (proposalId_ == activeProposal.proposalId) {
            revert CannotReclaimTokensForActiveVote();
        }

        if (tokenClaimsForProposal[proposalId_][msg.sender] == true) {
            revert VotingTokensAlreadyReclaimed();
        }

        tokenClaimsForProposal[proposalId_][msg.sender] = true;

        VOTES.transferFrom(address(this), msg.sender, userVotes);
    }
}
