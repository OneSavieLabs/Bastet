// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import "../interfaces/ISafe.sol";
import "../libs/auth.sol";
import "metavest/MetaVesTController.sol";
import "./baseImplant.sol";

/// @title optimisticGrantImplant
/// @notice This implant allows for the BORG to create grants pre-approved by the DAO
contract optimisticGrantImplant is BaseImplant { //is baseImplant

    // The ID of the implant
    uint256 public immutable IMPLANT_ID = 2;

    // Limits
    uint256 public grantCountLimit;
    uint256 public currentGrantCount;
    uint256 public grantTimeLimit;

    // MetaVest contracts
    MetaVesT public metaVesT;
    MetaVesTController public metaVesTController;

     // Require BORG Vote (toggle multi-sig vote vs any BORG member)
    bool public requireBorgVote = true;

    // struct for approved grant tokens
    struct approvedGrantToken { 
        uint256 spendingLimit;
        uint256 maxPerGrant;
        uint256 amountSpent;
    }

    // Errors and events
    error optimisticGrantImplant_invalidToken();
    error optimisticGrantImplant_GrantCountLimitReached();
    error optimisticGrantImplant_GrantOverIndividualLimit();
    error optimisticGrantImplant_GrantTimeLimitReached();
    error optimisticGrantImplant_GrantSpendingLimitReached();
    error optimisticGrantImplant_CallerNotBORGMember();
    error optimisticGrantImplant_CallerNotBORG();
    error optimisticGrantImplant_ApprovalFailed();
    error optimisticGrantImplant_GrantFailed();

    event GrantTokenAdded(address token, uint256 spendingLimit, uint256 maxPerGrant);
    event GrantTokenRemoved(address token);
    event GrantLimitsSet(uint256 grantCountLimit, uint256 grantTimeLimit);
    event BorgVoteToggled(bool requireBorgVote);
    event DirectGrantCreated(address token, address recipient, uint256 amount);
    event BasicGrantCreated(address token, address recipient, uint256 amount);
    event AdvancedGrantCreated(MetaVesT.MetaVesTDetails metavestDetails);

    mapping(address => approvedGrantToken) public approvedGrantTokens;

    /// @param _auth initialize authorization parameters for this contract, including applicable conditions
    /// @param _borgSafe address of the applicable BORG's Gnosis Safe which is adding this optimisticGrantImplant
    /// @param _metaVestController address of the MetaVesTController contract
    constructor(BorgAuth _auth, address _borgSafe, address _metaVestController) BaseImplant(_auth, _borgSafe) {
        metaVesTController = MetaVesTController(_metaVestController);
        metaVesT = MetaVesT(metaVesTController.metavest());
    }

    /// @notice Add a token to the approved grant tokens list
    /// @param _token address of the token to add
    /// @param _maxPerGrant maximum amount that can be granted in a single grant
    /// @param _spendingLimit maximum amount that can be granted in total
    function addApprovedGrantToken(address _token, uint256 _maxPerGrant, uint256 _spendingLimit) external onlyOwner {
        approvedGrantTokens[_token] = approvedGrantToken(_spendingLimit, _maxPerGrant, 0);
        emit GrantTokenAdded(_token, _spendingLimit, _maxPerGrant);
    }

    /// @notice Remove a token from the approved grant tokens list
    /// @param _token address of the token to remove
    function removeApprovedGrantToken(address _token) external onlyOwner {
        approvedGrantTokens[_token] = approvedGrantToken(0, 0, 0);
        emit GrantTokenRemoved(_token);
    }

    /// @notice Set the grant limits
    /// @param _grantCountLimit maximum number of grants that can be created
    /// @param _grantTimeLimit time limit for creating grants
    function setGrantLimits(uint256 _grantCountLimit, uint256 _grantTimeLimit) external onlyOwner {
        grantCountLimit = _grantCountLimit;
        grantTimeLimit = _grantTimeLimit;
        currentGrantCount = 0;
        emit GrantLimitsSet(_grantCountLimit, _grantTimeLimit);
    }

    /// @notice Toggle the requirement for a BORG vote to create a grant
    /// @param _requireBorgVote true if a BORG vote is required, false if any BORG member can create a grant
    function toggleBorgVote(bool _requireBorgVote) external onlyOwner {
        requireBorgVote = _requireBorgVote;
        emit BorgVoteToggled(_requireBorgVote);
    }

    /// @notice Create a direct grant, bypassing metavest, using an erc20 transfer
    /// @param _token address of the token to grant
    /// @param _recipient address of the recipient
    /// @param _amount amount to grant
    function createDirectGrant(address _token, address _recipient, uint256 _amount) external {
        if(currentGrantCount >= grantCountLimit)
            revert optimisticGrantImplant_GrantCountLimitReached();

        if(_amount > approvedGrantTokens[_token].maxPerGrant)
            revert optimisticGrantImplant_GrantOverIndividualLimit();

        if(block.timestamp >= grantTimeLimit)
            revert optimisticGrantImplant_GrantTimeLimitReached();
        
        if(requireBorgVote) {
            if(BORG_SAFE != msg.sender)
                revert optimisticGrantImplant_CallerNotBORG();
        }
        else {
            if(!ISafe(BORG_SAFE).isOwner(msg.sender))
                revert optimisticGrantImplant_CallerNotBORGMember();
         }

        approvedGrantToken storage approvedToken = approvedGrantTokens[_token];
        if (approvedToken.spendingLimit == 0) {
            revert optimisticGrantImplant_invalidToken();
        }
        if(approvedToken.amountSpent + _amount > approvedToken.spendingLimit)
            revert optimisticGrantImplant_GrantSpendingLimitReached();
        
        if(_token==address(0))
            if(!ISafe(BORG_SAFE).execTransactionFromModule(_recipient, _amount, "", Enum.Operation.Call))
                revert optimisticGrantImplant_GrantFailed();
        else
            if(!ISafe(BORG_SAFE).execTransactionFromModule(_token, 0, abi.encodeWithSignature("transfer(address,uint256)", _recipient, _amount), Enum.Operation.Call))
                revert optimisticGrantImplant_GrantFailed();

        approvedToken.amountSpent += _amount;
        currentGrantCount++;
        emit DirectGrantCreated(_token, _recipient, _amount);
    }

    /// @notice Create a basic grant using metavest
    /// @param _token address of the token to grant
    /// @param _recipient address of the recipient
    /// @param _amount amount to grant
    function createBasicGrant(address _token, address _recipient, uint256 _amount) external {

        if(currentGrantCount >= grantCountLimit)
            revert optimisticGrantImplant_GrantCountLimitReached();

        if(_amount > approvedGrantTokens[_token].maxPerGrant)
            revert optimisticGrantImplant_GrantOverIndividualLimit();

        if(block.timestamp >= grantTimeLimit)
            revert optimisticGrantImplant_GrantTimeLimitReached();

         if(requireBorgVote) {
            if(BORG_SAFE != msg.sender)
                revert optimisticGrantImplant_CallerNotBORG();
        }
        else {
            if(!ISafe(BORG_SAFE).isOwner(msg.sender))
                revert optimisticGrantImplant_CallerNotBORGMember();
         }

        //Configure the metavest details
        MetaVesT.Milestone[] memory emptyMilestones;
        MetaVesT.MetaVesTDetails memory _metavestDetails = MetaVesT.MetaVesTDetails({
            metavestType: MetaVesT.MetaVesTType.ALLOCATION,
            allocation: MetaVesT.Allocation({
                tokenStreamTotal: _amount,
                tokenGoverningPower: 0,
                tokensVested: 0,
                tokensUnlocked: 0,
                vestedTokensWithdrawn: 0,
                unlockedTokensWithdrawn: 0,
                vestingCliffCredit: uint128(_amount),
                unlockingCliffCredit: uint128(_amount),
                vestingRate: 1,
                vestingStartTime: uint48(block.timestamp),
                vestingStopTime: uint48(block.timestamp+1),
                unlockRate: 1,
                unlockStartTime: uint48(block.timestamp),
                unlockStopTime: uint48(block.timestamp+1),
                tokenContract: _token
            }),
            option: MetaVesT.TokenOption({exercisePrice: 0, tokensForfeited: 0, shortStopTime: uint48(0)}),
            rta: MetaVesT.RestrictedTokenAward({repurchasePrice: 0, tokensRepurchasable: 0, shortStopTime: uint48(0)}),
            eligibleTokens: MetaVesT.GovEligibleTokens({nonwithdrawable: false, vested: true, unlocked: true}),
            grantee: _recipient,
            milestones: emptyMilestones,
            transferable: false
        });

        approvedGrantToken storage approvedToken = approvedGrantTokens[_token];
        if (approvedToken.spendingLimit == 0) {
            revert optimisticGrantImplant_invalidToken();
        }
        if(approvedToken.amountSpent + _amount > approvedToken.spendingLimit)
            revert optimisticGrantImplant_GrantSpendingLimitReached();
        
        //approve metaVest to spend the amount
        if(!ISafe(BORG_SAFE).execTransactionFromModule(_token, 0, abi.encodeWithSignature("approve(address,uint256)", address(metaVesT), _amount), Enum.Operation.Call))
            revert optimisticGrantImplant_ApprovalFailed();
        if(!ISafe(BORG_SAFE).execTransactionFromModule(address(metaVesTController), 0, abi.encodeWithSignature("createMetavestAndLockTokens((address,bool,uint8,(uint256,uint256,uint256,uint256,uint256,uint256,uint128,uint128,uint160,uint48,uint48,uint160,uint48,uint48,address),(uint256,uint208,uint48),(uint256,uint208,uint48),(bool,bool,bool),(uint256,bool,address[])[]))", _metavestDetails), Enum.Operation.Call))
            revert optimisticGrantImplant_GrantFailed();

        approvedToken.amountSpent += _amount;
        currentGrantCount++;
        emit BasicGrantCreated(_token, _recipient, _amount);
    }

    /// @notice Create an advanced grant using metavest
    /// @param _metaVestDetails metavest details for the grant
     function createAdvancedGrant(MetaVesT.MetaVesTDetails calldata _metaVestDetails) external {

        if(currentGrantCount >= grantCountLimit)
            revert optimisticGrantImplant_GrantCountLimitReached();
        if(block.timestamp >= grantTimeLimit)
            revert optimisticGrantImplant_GrantTimeLimitReached();

        if(requireBorgVote) {
            if(BORG_SAFE != msg.sender)
                revert optimisticGrantImplant_CallerNotBORG();
        }
        else {
            if(!ISafe(BORG_SAFE).isOwner(msg.sender))
                revert optimisticGrantImplant_CallerNotBORGMember();
         }

         //cycle through any allocations and approve the metavest to spend the amount
        uint256 _milestoneTotal;
        for (uint256 i; i < _metaVestDetails.milestones.length; ++i) {
            _milestoneTotal += _metaVestDetails.milestones[i].milestoneAward;
        }
        uint256 _total = _metaVestDetails.allocation.tokenStreamTotal +
            _milestoneTotal;

        approvedGrantToken storage approvedToken = approvedGrantTokens[_metaVestDetails.allocation.tokenContract];
        if (approvedToken.spendingLimit == 0) {
            revert optimisticGrantImplant_invalidToken();
        }
        if(approvedToken.amountSpent + _total > approvedToken.spendingLimit)
            revert optimisticGrantImplant_GrantSpendingLimitReached();

        if(_total > approvedGrantTokens[_metaVestDetails.allocation.tokenContract].maxPerGrant)
            revert optimisticGrantImplant_GrantOverIndividualLimit();

        if(!ISafe(BORG_SAFE).execTransactionFromModule(_metaVestDetails.allocation.tokenContract, 0, abi.encodeWithSignature("approve(address,uint256)", address(metaVesT), _total), Enum.Operation.Call))
            revert optimisticGrantImplant_ApprovalFailed();
        if(!ISafe(BORG_SAFE).execTransactionFromModule(address(metaVesTController), 0, abi.encodeWithSignature("createMetavestAndLockTokens((address,bool,uint8,(uint256,uint256,uint256,uint256,uint256,uint256,uint128,uint128,uint160,uint48,uint48,uint160,uint48,uint48,address),(uint256,uint208,uint48),(uint256,uint208,uint48),(bool,bool,bool),(uint256,bool,address[])[]))", _metaVestDetails), Enum.Operation.Call))
            revert optimisticGrantImplant_GrantFailed();
        
        approvedToken.amountSpent += _total;
        currentGrantCount++;
        emit AdvancedGrantCreated(_metaVestDetails);
      }
}
