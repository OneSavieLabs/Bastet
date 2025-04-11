// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";

import "./SimpleAccessControl.sol";
import "../../interfaces/access/IGovernanceProxy.sol";

contract GovernanceProxy is IGovernanceProxy, SimpleAccessControl {
    using Address for address;

    bytes32 public constant GOVERNANCE_ROLE = "GOVERNANCE";
    bytes32 public constant VETO_ROLE = "VETO";

    uint64 public nextChangeId;

    /// @notice mapping from function selector to delay in seconds
    /// NOTE: For simplicity, delays are only based on selectors and not on the
    /// contract address, which means that if two functions in different
    /// contracts have the exact same name and arguments, they will share the same delay
    mapping(bytes4 => uint64) public override delays;

    /// @dev array of pending changes to execute
    /// We perform linear searches through this using the change ID, so in theory
    /// this could run out of gas. However, in practice, the number of pending
    /// changes should never become large enough for this to become an issue
    Change[] internal pendingChanges;

    /// @dev this is an array of all changes that have ended, regardless of their status
    /// this is only used to make it easier to query but should not be used from within
    /// any contract as the length is completely unbounded
    Change[] internal endedChanges;

    constructor(address governance, address veto) {
        _grantRole(GOVERNANCE_ROLE, governance);
        _grantRole(VETO_ROLE, veto);
    }

    /// @return change the pending change with the given id if found
    /// this reverts if the change is not found
    function getPendingChange(uint64 changeId) external view returns (Change memory change) {
        (change, ) = _findPendingChange(changeId);
    }

    /// @return all the pending changes
    /// this should typically be quite small so no need for pagination
    function getPendingChanges() external view returns (Change[] memory) {
        return pendingChanges;
    }

    /// @return total number of ended changes
    function getEndedChangesCount() external view returns (uint256) {
        return endedChanges.length;
    }

    /// @return all the ended changes
    /// this can become large so `getEndedChanges(uint256 offset, uint256 n)`
    /// is the preferred way to query
    function getEndedChanges() external view returns (Change[] memory) {
        return endedChanges;
    }

    /// @return `n` ended changes starting from offset
    /// This is useful is you want to paginate through the changes
    /// note that the changes are in chronological order of execution/cancelation
    /// which means that it might be useful to start paginatign from the end of the array
    function getEndedChanges(uint256 offset, uint256 n) external view returns (Change[] memory) {
        Change[] memory paginated = new Change[](n);
        for (uint256 i; i < n; i++) {
            paginated[i] = endedChanges[offset + i];
        }
        return paginated;
    }

    /// @notice Requests a list of function calls to be executed as a change
    /// @dev If the change requires no delay, it will be executed immediately
    /// @param calls the calls to be executed
    /// this should be fully encoded including the selectors and the abi-encoded arguments
    /// Changes can only be requested by governance
    function requestChange(Call[] calldata calls) external onlyRole(GOVERNANCE_ROLE) {
        // Calculating the maximum delay for all calls
        uint64 maxDelay;
        for (uint256 i; i < calls.length; i++) {
            uint64 delay = _computeDelay(calls[i].data);
            if (delay > maxDelay) maxDelay = delay;
        }

        (Change storage change, uint256 index) = _requestChange(maxDelay, calls);

        // If the change requires no delay, execute it immediately
        if (maxDelay == 0) {
            _executeChange(change, index);
        }
    }

    /// @notice Executes a change
    /// The deadline of the change must be past
    /// Anyone can execute a pending change but in practice, this will be called by governance too
    function executeChange(uint64 id) external {
        (Change storage change, uint256 index) = _findPendingChange(id);
        _executeChange(change, index);
    }

    /// @notice Cancels a pending change
    /// Both governance and users having veto power can cancel a pending change
    function cancelChange(uint64 id) external {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender) || hasRole(VETO_ROLE, msg.sender),
            "not authorized"
        );

        (Change storage change, uint256 index) = _findPendingChange(id);
        emit ChangeCanceled(id);
        _endChange(change, index, Status.Canceled);
    }

    // the following functions should be called through `executeChange`

    function updateDelay(bytes4 selector, uint64 delay) external override {
        require(msg.sender == address(this), "not authorized");
        delays[selector] = delay;
        emit DelayUpdated(selector, delay);
    }

    function grantRole(bytes32 role, address account) external override {
        require(msg.sender == address(this), "not authorized");
        require(role == GOVERNANCE_ROLE || role == VETO_ROLE, "invalid role");
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external override {
        require(msg.sender == address(this), "not authorized");
        require(
            role != GOVERNANCE_ROLE || getRoleMemberCount(role) > 1,
            "need at least one governor"
        );
        _revokeRole(role, account);
    }

    // internal helpers

    function _requestChange(
        uint64 delay,
        Call[] calldata calls
    ) internal returns (Change storage change, uint256 index) {
        uint64 id = nextChangeId++;
        change = pendingChanges.push();
        change.id = id;
        change.requestedAt = uint64(block.timestamp);
        change.endedAt = 0;
        change.delay = delay;
        change.status = Status.Pending;
        for (uint256 i; i < calls.length; i++) {
            change.calls.push(calls[i]);
        }

        index = pendingChanges.length - 1;

        emit ChangeRequested(calls, delay, id);
    }

    function _executeChange(Change storage change, uint256 index) internal {
        require(
            change.requestedAt + change.delay <= block.timestamp,
            "deadline has not been reached"
        );

        for (uint256 i; i < change.calls.length; i++) {
            change.calls[i].target.functionCall(change.calls[i].data);
        }

        emit ChangeExecuted(change.id);
        _endChange(change, index, Status.Executed);
    }

    function _endChange(Change storage change, uint256 index, Status status) internal {
        change.status = status;
        change.endedAt = uint64(block.timestamp);
        endedChanges.push(change);
        _removePendingChange(index);
    }

    function _removePendingChange(uint256 index) internal {
        pendingChanges[index] = pendingChanges[pendingChanges.length - 1];
        pendingChanges.pop();
    }

    function _findPendingChange(uint64 id) internal view returns (Change storage, uint256 index) {
        for (uint256 i; i < pendingChanges.length; i++) {
            if (pendingChanges[i].id == id) {
                return (pendingChanges[i], i);
            }
        }
        revert("change not found");
    }

    function _computeDelay(bytes calldata data) internal view returns (uint64) {
        bytes4 selector = bytes4(data[:4]);

        // special case for `updateDelay`, we want to set the delay
        // as the delay for the current function for which the delay
        // will be changed, rather than a generic delay for `updateDelay` itself
        // for all the other functions, we use their actual delay
        if (selector == GovernanceProxy.updateDelay.selector) {
            bytes memory callData = data[4:];
            (selector, ) = abi.decode(callData, (bytes4, uint256));
        }

        return delays[selector];
    }
}
