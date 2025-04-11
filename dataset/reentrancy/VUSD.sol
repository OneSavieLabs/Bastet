// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.9;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { ERC20PresetMinterPauserUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/presets/ERC20PresetMinterPauserUpgradeable.sol";
import { IVUSD } from './Interfaces.sol';

/**
 * @title VUSD is a wrapper over USDC (also the gas token). VUSD it the 0th collateral in the system and also the only coin accepted by the insurance fund.
 * @notice In Hubble Exchange docs/contracts etc, VUSD is interchangeably referred to as hUSD
*/
contract VUSD is ERC20PresetMinterPauserUpgradeable, ReentrancyGuard, IVUSD {

    uint8 private constant PRECISION = 6;
    uint256 private constant SCALING_FACTOR = 1e12;

    struct Withdrawal {
        address usr;
        uint amount;
    }
    Withdrawal[] public withdrawals;

    /// @dev withdrawals will start processing at withdrawals[start]
    uint public start;

    /// @dev Constrained by block gas limit
    uint public maxWithdrawalProcesses;

    uint256[50] private __gap;

    function initialize(string memory name, string memory symbol) public override virtual {
        super.initialize(name, symbol); // has initializer modifier
        _revokeRole(MINTER_ROLE, _msgSender()); // __ERC20PresetMinterPauser_init_unchained grants this but is not required
        maxWithdrawalProcesses = 100;
    }

    /**
    * @notice mint hUSD by depositing hubble gas token
    * @dev keeping the function name same as v1 for compatibility
    * @param to address to mint for
    * @param amount amount to mint - precision 1e6
    * msg.value has to be exactly 1e12 times `amount`
    */
    function mintWithReserve(address to, uint amount) external override payable whenNotPaused {
        require(msg.value == amount * SCALING_FACTOR, "vUSD: Insufficient amount transferred");
        _mint(to, amount);
    }

    function withdraw(uint amount) external override whenNotPaused {
        _withdrawTo(_msgSender(), amount);
    }

    /**
    * @notice Burn vusd from msg.sender and Q the withdrawal to `to`
    * @dev no need to add onlyMarginAccountHelper modifier as vusd is burned from caller and sent to specified address
    */
    function withdrawTo(address to, uint amount) external override whenNotPaused {
        _withdrawTo(to, amount);
    }

    /**
     * @notice Process withdrawals in the queue. Sends gas token to the user.
    */
    function processWithdrawals() external override whenNotPaused nonReentrant {
        uint reserve = address(this).balance;
        require(reserve >= withdrawals[start].amount, 'Cannot process withdrawals at this time: Not enough balance');
        uint i = start;
        while (i < withdrawals.length && (i - start) < maxWithdrawalProcesses) {
            Withdrawal memory withdrawal = withdrawals[i];
            if (reserve < withdrawal.amount) {
                break;
            }

            (bool success, bytes memory data) = withdrawal.usr.call{value: withdrawal.amount}("");
            if (success) {
                reserve -= withdrawal.amount;
            } else {
                emit WithdrawalFailed(withdrawal.usr, withdrawal.amount, data);
            }
            i += 1;
        }
        // re-entracy not possible, hence can update `start` at the end
        start = i;
    }

    function withdrawalQueue() external view returns(Withdrawal[] memory queue) {
        uint l = _min(withdrawals.length-start, maxWithdrawalProcesses);
        queue = new Withdrawal[](l);

        for (uint i = 0; i < l; i++) {
            queue[i] = withdrawals[start+i];
        }
    }

    function withdrawalQLength() external view returns (uint) {
        return withdrawals.length;
    }

    function decimals() public pure override returns (uint8) {
        return PRECISION;
    }

    function setMaxWithdrawalProcesses(uint _maxWithdrawalProcesses) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "ERC20PresetMinterPauser: must have admin role");
        maxWithdrawalProcesses = _maxWithdrawalProcesses;
    }

    function _withdrawTo(address to, uint amount) internal {
        require(amount >= 5 * (10 ** PRECISION), "min withdraw is 5 vusd");
        burn(amount); // burn vusd from msg.sender
        withdrawals.push(Withdrawal(to, amount * SCALING_FACTOR));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
