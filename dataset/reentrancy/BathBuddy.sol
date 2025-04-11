// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

import "./VestingWallet.sol";
import "../interfaces/IBathBuddy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BathBuddy
 * @dev *** This contract is a lightly modified version of Vesting Wallet by OpenZeppelin
 * @dev PLEASE FIND OZ DOCUMENTATION FOR THIS CONTRACT HERE: https://docs.openzeppelin.com/contracts/4.x/api/finance#VestingWallet
 *
 * @dev The only entrypoint used in the system is the release function called by the Bath Token. Extra care should be taken to make sure only the beneficiary can ever access the funds and send them to the withdrawer (and fee to self)
 *
 * @dev This contract handles the vesting ERC20 tokens for a given beneficiary. Custody of multiple tokens
 * can be given to this contract, which will release the token to the beneficiary following a given vesting schedule.
 * The vesting schedule is customizable through the {vestedAmount} function.
 *
 * Any token transferred to this contract will follow the vesting schedule as if they were locked from the beginning.
 * Consequently, if the vesting has already started, any amount of tokens sent to this contract will (at least partly)
 * be immediately releasable.
 */
contract BathBuddy is IBathBuddy {
    using SafeMath for uint256;

    // Public versions of the base VestingWallet storage
    uint256 private _released;
    mapping(address => uint256) private _erc20Released;

    // Beneficiary must be the Bath Token vault recipient that will call release() for its withdrawer
    address public beneficiary;
    uint64 public start;
    uint64 public duration;

    /**
     * @dev Set the beneficiary, start timestamp and vesting duration of the vesting wallet.
     */
    constructor(
        address beneficiaryAddress,
        uint64 startTimestamp,
        uint64 durationSeconds
    ) {
        require(
            beneficiaryAddress != address(0),
            "VestingWallet: beneficiary is zero address"
        );
        beneficiary = beneficiaryAddress;
        start = startTimestamp;
        duration = durationSeconds;
    }

    // OZ
    event EtherReleased(uint256 amount);
    event ERC20Released(address indexed token, uint256 amount);

    /// @notice Log bonus token reward event
    event LogClaimBonusToken(
        address indexed receiver,
        address indexed callingPool,
        uint256 amountReceived,
        uint256 shares,
        IERC20 bonusToken,
        uint256 releasableAmountToWholePool
    );

    /**
     * @dev The contract should be able to receive Eth.
     */
    receive() external payable {}

    /**
     * @dev Amount of eth already released
     */
    function released() public view returns (uint256) {
        return _released;
    }

    /**
     * @dev Amount of token already released
     */
    function released(address token) public view returns (uint256) {
        return _erc20Released[token];
    }

    /// @inheritdoc IBathBuddy
    /// @dev Added and modified release function. Should be the only callable release function
    function release(
        IERC20 token,
        address recipient,
        uint256 sharesWithdrawn,
        uint256 initialTotalSupply,
        uint256 poolFee
    ) external override {
        require(
            msg.sender == beneficiary,
            "Caller is not the Bath Token beneficiary of these rewards"
        );
        uint256 releasable = vestedAmount(
            address(token),
            uint64(block.timestamp)
        ) - released(address(token));
        if (releasable > 0) {
            uint256 amount = releasable.mul(sharesWithdrawn).div(
                initialTotalSupply
            );
            uint256 _fee = amount.mul(poolFee).div(10000);

            // If FeeTo == address(this) then the fee is effectively accrued by the pool
            // Assume the caller is the liquidity pool and they receive the fee
            // Keep tokens here by not transfering the _fee anywhere, it is accrued to the Bath Token's Bath Buddy
            // token.transfer(address(this), _fee);

            uint256 amountWithdrawn = amount.sub(_fee);
            token.transfer(recipient, amountWithdrawn);

            _erc20Released[address(token)] += amount;
            emit ERC20Released(address(token), amount);

            emit LogClaimBonusToken(
                recipient,
                msg.sender,
                amountWithdrawn,
                sharesWithdrawn,
                token,
                releasable
            );
        }
    }

    /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     */
    function vestedAmount(address token, uint64 timestamp)
        public
        view
        returns (uint256)
    {
        return
            _vestingSchedule(
                IERC20(token).balanceOf(address(this)) + released(token),
                timestamp
            );
    }

    /**
     * @dev Virtual implementation of the vesting formula. This returns the amount vested, as a function of time, for
     * an asset given its total historical allocation.
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp)
        internal
        view
        returns (uint256)
    {
        if (timestamp < start) {
            return 0;
        } else if (timestamp > start + duration) {
            return totalAllocation;
        } else {
            return (totalAllocation * (timestamp - start)) / duration;
        }
    }
}
