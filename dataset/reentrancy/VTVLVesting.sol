//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.14;
// Note: using solidity 0.8, SafeMath not needed any more

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessProtected.sol";

contract VTVLVesting is Context, AccessProtected {
    using SafeERC20 for IERC20;

    /**
    @notice Address of the token that we're vesting
     */
    IERC20 public immutable tokenAddress;

    /**
    @notice How many tokens are already allocated to vesting schedules.
    @dev Our balance of the token must always be greater than this amount.
    * Otherwise we risk some users not getting their shares.
    * This gets reduced as the users are paid out or when their schedules are revoked (as it is not reserved any more).
    * In other words, this represents the amount the contract is scheduled to pay out at some point if the 
    * owner were to never interact with the contract.
    */
    uint112 public numTokensReservedForVesting = 0;

    /**
    @notice A structure representing a single claim - supporting linear and cliff vesting.
     */
    struct Claim {
        // Using 40 bits for timestamp (seconds)
        // Gives us a range from 1 Jan 1970 (Unix epoch) up to approximately 35 thousand years from then (2^40 / (365 * 24 * 60 * 60) ~= 35k)
        uint40 startTimestamp; // When does the vesting start (40 bits is enough for TS)
        uint40 endTimestamp; // When does the vesting end - the vesting goes linearly between the start and end timestamps
        uint40 cliffReleaseTimestamp; // At which timestamp is the cliffAmount released. This must be <= startTimestamp
        uint40 releaseIntervalSecs; // Every how many seconds does the vested amount increase. 
        
        // uint112 range: range 0 –     5,192,296,858,534,827,628,530,496,329,220,095.
        // uint112 range: range 0 –                             5,192,296,858,534,827.
        uint112 linearVestAmount; // total entitlement
        uint112 cliffAmount; // how much is released at the cliff
        uint112 amountWithdrawn; // how much was withdrawn thus far - released at the cliffReleaseTimestamp
        bool isActive; // whether this claim is active (or revoked)
    }    

    // Mapping every user address to his/her Claim
    // Only one Claim possible per address
    mapping (address => Claim) internal claims;

    // Track the recipients of the vesting
    address[] internal vestingRecipients;

    // Events:
    /**
    @notice Emitted when a founder adds a vesting schedule.
     */
    event ClaimCreated(address indexed _recipient, Claim _claim); 

    /**
    @notice Emitted when someone withdraws a vested amount
    */
    event Claimed(address indexed _recipient, uint112 _withdrawalAmount); 

    /** 
    @notice Emitted when a claim is revoked
    */
    event ClaimRevoked(address indexed _recipient, uint112 _numTokensWithheld, uint256 revocationTimestamp, Claim _claim);
    
    /** 
    @notice Emitted when admin withdraws.
    */
    event AdminWithdrawn(address indexed _recipient, uint112 _amountRequested);

    // 
    /**
    @notice Construct the contract, taking the ERC20 token to be vested as the parameter.
    @dev The owner can set the contract in question when creating the contract.
     */
    constructor(IERC20 _tokenAddress) {
        require(address(_tokenAddress) != address(0), "INVALID_ADDRESS");
        tokenAddress = _tokenAddress;
    }

    /**
    @notice Basic getter for a claim. 
    @dev Could be using public claims var, but this is cleaner in terms of naming. (getClaim(address) as opposed to claims(address)). 
    @param _recipient - the address for which we fetch the claim.
     */
    function getClaim(address _recipient) external view returns (Claim memory) {
        return claims[_recipient];
    }

    /**
    @notice This modifier requires that an user has a claim attached.
    @dev  To determine this, we check that a claim:
    * - is active
    * - start timestamp is nonzero.
    * These are sufficient conditions because we only ever set startTimestamp in 
    * createClaim, and we never change it. Therefore, startTimestamp will be set
    * IFF a claim has been created. In addition to that, we need to check
    * a claim is active (since this is has_*Active*_Claim)
    */
    modifier hasActiveClaim(address _recipient) {
        Claim storage _claim = claims[_recipient];
        require(_claim.startTimestamp > 0, "NO_ACTIVE_CLAIM");

        // We however still need the active check, since (due to the name of the function)
        // we want to only allow active claims
        require(_claim.isActive == true, "NO_ACTIVE_CLAIM");

        // Save gas, omit further checks
        // require(_claim.linearVestAmount + _claim.cliffAmount > 0, "INVALID_VESTED_AMOUNT");
        // require(_claim.endTimestamp > 0, "NO_END_TIMESTAMP");
        _;
    }

    /** 
    @notice Modifier which is opposite hasActiveClaim
    @dev Requires that all fields are unset
    */ 
    modifier hasNoClaim(address _recipient) {
        Claim storage _claim = claims[_recipient];
        // Start timestamp != 0 is a sufficient condition for a claim to exist
        // This is because we only ever add claims (or modify startTs) in the createClaim function 
        // Which requires that its input startTimestamp be nonzero
        // So therefore, a zero value for this indicates the claim does not exist.
        require(_claim.startTimestamp == 0, "CLAIM_ALREADY_EXISTS");
        
        // We don't even need to check for active to be unset, since this function only 
        // determines that a claim hasn't been set
        // require(_claim.isActive == false, "CLAIM_ALREADY_EXISTS");
    
        // Further checks aren't necessary (to save gas), as they're done at creation time (createClaim)
        // require(_claim.endTimestamp == 0, "CLAIM_ALREADY_EXISTS");
        // require(_claim.linearVestAmount + _claim.cliffAmount == 0, "CLAIM_ALREADY_EXISTS");
        // require(_claim.amountWithdrawn == 0, "CLAIM_ALREADY_EXISTS");
        _;
    }

    /**
    @notice Pure function to calculate the vested amount from a given _claim, at a reference timestamp
    @param _claim The claim in question
    @param _referenceTs Timestamp for which we're calculating
     */
    function _baseVestedAmount(Claim memory _claim, uint40 _referenceTs) internal pure returns (uint112) {
        uint112 vestAmt = 0;
        
        // the condition to have anything vested is to be active
        if(_claim.isActive) {
            // no point of looking past the endTimestamp as nothing should vest afterwards
            // So if we're past the end, just get the ref frame back to the end
            if(_referenceTs > _claim.endTimestamp) {
                _referenceTs = _claim.endTimestamp;
            }

            // If we're past the cliffReleaseTimestamp, we release the cliffAmount
            // We don't check here that cliffReleaseTimestamp is after the startTimestamp 
            if(_referenceTs >= _claim.cliffReleaseTimestamp) {
                vestAmt += _claim.cliffAmount;
            }

            // Calculate the linearly vested amount - this is relevant only if we're past the schedule start
            // at _referenceTs == _claim.startTimestamp, the period proportion will be 0 so we don't need to start the calc
            if(_referenceTs > _claim.startTimestamp) {
                uint40 currentVestingDurationSecs = _referenceTs - _claim.startTimestamp; // How long since the start
                // Next, we need to calculated the duration truncated to nearest releaseIntervalSecs
                uint40 truncatedCurrentVestingDurationSecs = (currentVestingDurationSecs / _claim.releaseIntervalSecs) * _claim.releaseIntervalSecs;
                uint40 finalVestingDurationSecs = _claim.endTimestamp - _claim.startTimestamp; // length of the interval

                // Calculate the linear vested amount - fraction_of_interval_completed * linearVestedAmount
                // Since fraction_of_interval_completed is truncatedCurrentVestingDurationSecs / finalVestingDurationSecs, the formula becomes
                // truncatedCurrentVestingDurationSecs / finalVestingDurationSecs * linearVestAmount, so we can rewrite as below to avoid 
                // rounding errors
                uint112 linearVestAmount = _claim.linearVestAmount * truncatedCurrentVestingDurationSecs / finalVestingDurationSecs;

                // Having calculated the linearVestAmount, simply add it to the vested amount
                vestAmt += linearVestAmount;
            }
        }
        
        // Return the bigger of (vestAmt, _claim.amountWithdrawn)
        // Rationale: no matter how we calculate the vestAmt, we can never return that less was vested than was already withdrawn.
        // Case where this could be relevant - If the claim is inactive, vestAmt would be 0, yet if something was already withdrawn 
        // on that claim, we want to return that as vested thus far - as we want the function to be monotonic.
        return (vestAmt > _claim.amountWithdrawn) ? vestAmt : _claim.amountWithdrawn;
    }

    /**
    @notice Calculate the amount vested for a given _recipient at a reference timestamp.
    @param _recipient - The address for whom we're calculating
    @param _referenceTs - The timestamp at which we want to calculate the vested amount.
    @dev Simply call the _baseVestedAmount for the claim in question
    */
    function vestedAmount(address _recipient, uint40 _referenceTs) public view returns (uint112) {
        Claim storage _claim = claims[_recipient];
        return _baseVestedAmount(_claim, _referenceTs);
    }

    /**
    @notice Calculate the total vested at the end of the schedule, by simply feeding in the end timestamp to the function above.
    @dev This fn is somewhat superfluous, should probably be removed.
    @param _recipient - The address for whom we're calculating
     */
    function finalVestedAmount(address _recipient) public view returns (uint112) {
        Claim storage _claim = claims[_recipient];
        return _baseVestedAmount(_claim, _claim.endTimestamp);
    }
    
    /**
    @notice Calculates how much can we claim, by subtracting the already withdrawn amount from the vestedAmount at this moment.
    @param _recipient - The address for whom we're calculating
    */
    function claimableAmount(address _recipient) external view returns (uint112) {
        Claim storage _claim = claims[_recipient];
        return _baseVestedAmount(_claim, uint40(block.timestamp)) - _claim.amountWithdrawn;
    }
    
    /** 
    @notice Return all the addresses that have vesting schedules attached.
    */ 
    function allVestingRecipients() external view returns (address[] memory) {
        return vestingRecipients;
    }

    /** 
    @notice Get the total number of vesting recipients.
    */
    function numVestingRecipients() external view returns (uint256) {
        return vestingRecipients.length;
    }

    /** 
    @notice Permission-unchecked version of claim creation (no onlyAdmin). Actual logic for create claim, to be run within either createClaim or createClaimBatch.
    @dev This'll simply check the input parameters, and create the structure verbatim based on passed in parameters.
    @param _recipient - The address of the recipient of the schedule
    @param _startTimestamp - The timestamp when the linear vesting starts
    @param _endTimestamp - The timestamp when the linear vesting ends
    @param _cliffReleaseTimestamp - The timestamp when the cliff is released (must be <= _startTimestamp, or 0 if no vesting)
    @param _releaseIntervalSecs - The release interval for the linear vesting. If this is, for example, 60, that means that the linearly vested amount gets released every 60 seconds.
    @param _linearVestAmount - The total amount to be linearly vested between _startTimestamp and _endTimestamp
    @param _cliffAmount - The amount released at _cliffReleaseTimestamp. Can be 0 if _cliffReleaseTimestamp is also 0.
     */
    function _createClaimUnchecked(
            address _recipient, 
            uint40 _startTimestamp, 
            uint40 _endTimestamp, 
            uint40 _cliffReleaseTimestamp, 
            uint40 _releaseIntervalSecs, 
            uint112 _linearVestAmount, 
            uint112 _cliffAmount
                ) private  hasNoClaim(_recipient) {

        require(_recipient != address(0), "INVALID_ADDRESS");
        require(_linearVestAmount + _cliffAmount > 0, "INVALID_VESTED_AMOUNT"); // Actually only one of linearvested/cliff amount must be 0, not necessarily both
        require(_startTimestamp > 0, "INVALID_START_TIMESTAMP");
        // Do we need to check whether _startTimestamp is greater than the current block.timestamp? 
        // Or do we allow schedules that started in the past? 
        // -> Conclusion: we want to allow this, for founders that might have forgotten to add some users, or to avoid issues with transactions not going through because of discoordination between block.timestamp and sender's local time
        // require(_endTimestamp > 0, "_endTimestamp must be valid"); // not necessary because of the next condition (transitively)
        require(_startTimestamp < _endTimestamp, "INVALID_END_TIMESTAMP"); // _endTimestamp must be after _startTimestamp
        require(_releaseIntervalSecs > 0, "INVALID_RELEASE_INTERVAL");
        require((_endTimestamp - _startTimestamp) % _releaseIntervalSecs == 0, "INVALID_INTERVAL_LENGTH");

        // Potential TODO: sanity check, if _linearVestAmount == 0, should we perhaps force that start and end ts are the same?

        // No point in allowing cliff TS without the cliff amount or vice versa.
        // Both or neither of _cliffReleaseTimestamp and _cliffAmount must be set. If cliff is set, _cliffReleaseTimestamp must be before or at the _startTimestamp
        require( 
            (
                _cliffReleaseTimestamp > 0 && 
                _cliffAmount > 0 && 
                _cliffReleaseTimestamp <= _startTimestamp
            ) || (
                _cliffReleaseTimestamp == 0 && 
                _cliffAmount == 0
        ), "INVALID_CLIFF");

        Claim memory _claim = Claim({
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            cliffReleaseTimestamp: _cliffReleaseTimestamp,
            releaseIntervalSecs: _releaseIntervalSecs,
            cliffAmount: _cliffAmount,
            linearVestAmount: _linearVestAmount,
            amountWithdrawn: 0,
            isActive: true
        });
        // Our total allocation is simply the full sum of the two amounts, _cliffAmount + _linearVestAmount
        // Not necessary to use the more complex logic from _baseVestedAmount
        uint112 allocatedAmount = _cliffAmount + _linearVestAmount;

        // Still no effects up to this point (and tokenAddress is selected by contract deployer and is immutable), so no reentrancy risk 
        require(tokenAddress.balanceOf(address(this)) >= numTokensReservedForVesting + allocatedAmount, "INSUFFICIENT_BALANCE");

        // Done with checks

        // Effects limited to lines below
        claims[_recipient] = _claim; // store the claim
        numTokensReservedForVesting += allocatedAmount; // track the allocated amount
        vestingRecipients.push(_recipient); // add the vesting recipient to the list
        emit ClaimCreated(_recipient, _claim); // let everyone know
    }

    /** 
    @notice Create a claim based on the input parameters.
    @dev This'll simply check the input parameters, and create the structure verbatim based on passed in parameters.
    @param _recipient - The address of the recipient of the schedule
    @param _startTimestamp - The timestamp when the linear vesting starts
    @param _endTimestamp - The timestamp when the linear vesting ends
    @param _cliffReleaseTimestamp - The timestamp when the cliff is released (must be <= _startTimestamp, or 0 if no vesting)
    @param _releaseIntervalSecs - The release interval for the linear vesting. If this is, for example, 60, that means that the linearly vested amount gets released every 60 seconds.
    @param _linearVestAmount - The total amount to be linearly vested between _startTimestamp and _endTimestamp
    @param _cliffAmount - The amount released at _cliffReleaseTimestamp. Can be 0 if _cliffReleaseTimestamp is also 0.
     */
    function createClaim(
            address _recipient, 
            uint40 _startTimestamp, 
            uint40 _endTimestamp, 
            uint40 _cliffReleaseTimestamp, 
            uint40 _releaseIntervalSecs, 
            uint112 _linearVestAmount, 
            uint112 _cliffAmount
                ) external onlyAdmin {
        _createClaimUnchecked(_recipient, _startTimestamp, _endTimestamp, _cliffReleaseTimestamp, _releaseIntervalSecs, _linearVestAmount, _cliffAmount);
    }

    /**
    @notice The batch version of the createClaim function. Each argument is an array, and this function simply repeatedly calls the createClaim.
    
     */
    function createClaimsBatch(
        address[] memory _recipients, 
        uint40[] memory _startTimestamps, 
        uint40[] memory _endTimestamps, 
        uint40[] memory _cliffReleaseTimestamps, 
        uint40[] memory _releaseIntervalsSecs, 
        uint112[] memory _linearVestAmounts, 
        uint112[] memory _cliffAmounts) 
        external onlyAdmin {
        
        uint256 length = _recipients.length;
        require(_startTimestamps.length == length &&
                _endTimestamps.length == length &&
                _cliffReleaseTimestamps.length == length &&
                _releaseIntervalsSecs.length == length &&
                _linearVestAmounts.length == length &&
                _cliffAmounts.length == length, 
                "ARRAY_LENGTH_MISMATCH"
        );

        for (uint256 i = 0; i < length; i++) {
            _createClaimUnchecked(_recipients[i], _startTimestamps[i], _endTimestamps[i], _cliffReleaseTimestamps[i], _releaseIntervalsSecs[i], _linearVestAmounts[i], _cliffAmounts[i]);
        }

        // No need for separate emit, since createClaim will emit for each claim (and this function is merely a convenience/gas-saver for multiple claims creation)
    }

    /**
    @notice Withdraw the full claimable balance.
    @dev hasActiveClaim throws off anyone without a claim.
     */
    function withdraw() hasActiveClaim(_msgSender()) external {
        // Get the message sender claim - if any

        Claim storage usrClaim = claims[_msgSender()];

        // we can use block.timestamp directly here as reference TS, as the function itself will make sure to cap it to endTimestamp
        // Conversion of timestamp to uint40 should be safe since 48 bit allows for a lot of years.
        uint112 allowance = vestedAmount(_msgSender(), uint40(block.timestamp));

        // Make sure we didn't already withdraw more that we're allowed.
        require(allowance > usrClaim.amountWithdrawn, "NOTHING_TO_WITHDRAW");

        // Calculate how much can we withdraw (equivalent to the above inequality)
        uint112 amountRemaining = allowance - usrClaim.amountWithdrawn;

        // "Double-entry bookkeeping"
        // Carry out the withdrawal by noting the withdrawn amount, and by transferring the tokens.
        usrClaim.amountWithdrawn += amountRemaining;
        // Reduce the allocated amount since the following transaction pays out so the "debt" gets reduced
        numTokensReservedForVesting -= amountRemaining;
        
        // After the "books" are set, transfer the tokens
        // Reentrancy note - internal vars have been changed by now
        // Also following Checks-effects-interactions pattern
        tokenAddress.safeTransfer(_msgSender(), amountRemaining);

        // Let withdrawal known to everyone.
        emit Claimed(_msgSender(), amountRemaining);
    }

    /**
    @notice Admin withdrawal of the unallocated tokens.
    @param _amountRequested - the amount that we want to withdraw
     */
    function withdrawAdmin(uint112 _amountRequested) public onlyAdmin {    
        // Allow the owner to withdraw any balance not currently tied up in contracts.
        uint256 amountRemaining = tokenAddress.balanceOf(address(this)) - numTokensReservedForVesting;

        require(amountRemaining >= _amountRequested, "INSUFFICIENT_BALANCE");

        // Actually withdraw the tokens
        // Reentrancy note - this operation doesn't touch any of the internal vars, simply transfers
        // Also following Checks-effects-interactions pattern
        tokenAddress.safeTransfer(_msgSender(), _amountRequested);

        // Let the withdrawal known to everyone
        emit AdminWithdrawn(_msgSender(), _amountRequested);
    }


    /** 
    @notice Allow an Owner to revoke a claim that is already active.
    @dev The requirement is that a claim exists and that it's active.
    */ 
    function revokeClaim(address _recipient) external onlyAdmin hasActiveClaim(_recipient) {
        // Fetch the claim
        Claim storage _claim = claims[_recipient];
        // Calculate what the claim should finally vest to
        uint112 finalVestAmt = finalVestedAmount(_recipient);

        // No point in revoking something that has been fully consumed
        // so require that there be unconsumed amount
        require( _claim.amountWithdrawn < finalVestAmt, "NO_UNVESTED_AMOUNT");

        // The amount that is "reclaimed" is equal to the total allocation less what was already withdrawn
        uint112 amountRemaining = finalVestAmt - _claim.amountWithdrawn;

        // Deactivate the claim, and release the appropriate amount of tokens
        _claim.isActive = false;    // This effectively reduces the liability by amountRemaining, so we can reduce the liability numTokensReservedForVesting by that much
        numTokensReservedForVesting -= amountRemaining; // Reduces the allocation

        // Tell everyone a claim has been revoked.
        emit ClaimRevoked(_recipient, amountRemaining, uint40(block.timestamp), _claim);
    }

    /**
    @notice Withdraw a token which isn't controlled by the vesting contract.
    @dev This contract controls/vests token at "tokenAddress". However, someone might send a different token. 
    To make sure these don't get accidentally trapped, give admin the ability to withdraw them (to their own address).
    Note that the token to be withdrawn can't be the one at "tokenAddress".
    @param _otherTokenAddress - the token which we want to withdraw
     */
    function withdrawOtherToken(IERC20 _otherTokenAddress) external onlyAdmin {
        require(_otherTokenAddress != tokenAddress, "INVALID_TOKEN"); // tokenAddress address is already sure to be nonzero due to constructor
        uint256 bal = _otherTokenAddress.balanceOf(address(this));
        require(bal > 0, "INSUFFICIENT_BALANCE");
        _otherTokenAddress.safeTransfer(_msgSender(), bal);
    }
}
