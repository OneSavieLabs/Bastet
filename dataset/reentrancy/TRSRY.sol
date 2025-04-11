// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";

import "src/Kernel.sol";

// ERRORS
error TRSRY_NotApproved();
error TRSRY_NoDebtOutstanding();

/// @notice Treasury holds reserves, LP tokens and all other assets under the control
///         of the protocol.
contract OlympusTreasury is Module, ReentrancyGuard {
    using TransferHelper for ERC20;

    event ApprovedForWithdrawal(address indexed policy_, ERC20 indexed token_, uint256 amount_);
    event Withdrawal(
        address indexed policy_,
        address indexed withdrawer_,
        ERC20 indexed token_,
        uint256 amount_
    );
    event DebtIncurred(ERC20 indexed token_, address indexed policy_, uint256 amount_);
    event DebtRepaid(ERC20 indexed token_, address indexed policy_, uint256 amount_);
    event DebtSet(ERC20 indexed token_, address indexed policy_, uint256 amount_);

    /// @notice Mapping of who is approved for withdrawal.
    /// @dev    withdrawer -> token -> amount. Infinite approval is max(uint256).
    mapping(address => mapping(ERC20 => uint256)) public withdrawApproval;

    /// @notice Total debt for token across all withdrawals.
    mapping(ERC20 => uint256) public totalDebt;

    /// @notice Debt for particular token and debtor address
    mapping(ERC20 => mapping(address => uint256)) public reserveDebt;

    /*//////////////////////////////////////////////////////////////
                            MODULE INTERFACE
    //////////////////////////////////////////////////////////////*/

    constructor(Kernel kernel_) Module(kernel_) {}

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("TRSRY");
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    function getReserveBalance(ERC20 token_) external view returns (uint256) {
        return token_.balanceOf(address(this)) + totalDebt[token_];
    }

    /// @notice Sets approval for specific withdrawer addresses
    function setApprovalFor(
        address withdrawer_,
        ERC20 token_,
        uint256 amount_
    ) external permissioned {
        withdrawApproval[withdrawer_][token_] = amount_;

        emit ApprovedForWithdrawal(withdrawer_, token_, amount_);
    }

    /// @notice Allow withdrawal of reserve funds from pre-approved addresses.
    function withdrawReserves(
        address to_,
        ERC20 token_,
        uint256 amount_
    ) public {
        _checkApproval(msg.sender, token_, amount_);

        token_.safeTransfer(to_, amount_);

        emit Withdrawal(msg.sender, to_, token_, amount_);
    }

    /*//////////////////////////////////////////////////////////////
                             DEBT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pre-approved policies can get a loan to perform operations on treasury assets.
    function getLoan(ERC20 token_, uint256 amount_) external permissioned {
        _checkApproval(msg.sender, token_, amount_);

        // Add debt to caller
        reserveDebt[token_][msg.sender] += amount_;
        totalDebt[token_] += amount_;

        token_.safeTransfer(msg.sender, amount_);

        emit DebtIncurred(token_, msg.sender, amount_);
    }

    /// @notice Lets an address with debt repay their loan.
    function repayLoan(ERC20 token_, uint256 amount_) external nonReentrant {
        if (reserveDebt[token_][msg.sender] == 0) revert TRSRY_NoDebtOutstanding();

        // Deposit from caller first (to handle nonstandard token transfers)
        uint256 prevBalance = token_.balanceOf(address(this));
        token_.safeTransferFrom(msg.sender, address(this), amount_);

        uint256 received = token_.balanceOf(address(this)) - prevBalance;

        // Subtract debt from caller
        reserveDebt[token_][msg.sender] -= received;
        totalDebt[token_] -= received;

        emit DebtRepaid(token_, msg.sender, received);
    }

    /// @notice An escape hatch for setting debt in special cases, like swapping reserves to another token.
    function setDebt(
        ERC20 token_,
        address debtor_,
        uint256 amount_
    ) external permissioned {
        uint256 oldDebt = reserveDebt[token_][debtor_];

        reserveDebt[token_][debtor_] = amount_;

        if (oldDebt < amount_) totalDebt[token_] += amount_ - oldDebt;
        else totalDebt[token_] -= oldDebt - amount_;

        emit DebtSet(token_, debtor_, amount_);
    }

    function _checkApproval(
        address withdrawer_,
        ERC20 token_,
        uint256 amount_
    ) internal {
        // Must be approved
        uint256 approval = withdrawApproval[withdrawer_][token_];
        if (approval < amount_) revert TRSRY_NotApproved();

        // Check for infinite approval
        if (approval != type(uint256).max) {
            unchecked {
                withdrawApproval[withdrawer_][token_] = approval - amount_;
            }
        }
    }
}
