// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Logo } from "../lib/Logo.sol";
import { ICuratorRewardsDistributor } from "../interfaces/ICuratorRewardsDistributor.sol";
import { IPhiRewards } from "../interfaces/IPhiRewards.sol";
import { ICred } from "../interfaces/ICred.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { console2 } from "forge-std/console2.sol";
/// @title CuratorRewardsDistributor
/// @notice Manager of deposits & withdrawals for curator rewards
/// @dev This contract is deployed to same network as the cred contract

contract CuratorRewardsDistributor is Logo, Ownable2Step, ICuratorRewardsDistributor {
    /*//////////////////////////////////////////////////////////////
                                 USING
    //////////////////////////////////////////////////////////////*/
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    IPhiRewards public phiRewardsContract;
    ICred public credContract;

    uint256 private withdrawRoyalty = 100;
    uint256 private immutable RATIO_BASE = 10_000;
    uint256 private immutable MAX_ROYALTY_RANGE = 1000;
    mapping(uint256 credId => uint256 balance) public balanceOf;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address phiRewardsContract_, address credContract_) payable Ownable(msg.sender) {
        if (phiRewardsContract_ == address(0) || credContract_ == address(0)) {
            revert InvalidAddressZero();
        }

        phiRewardsContract = IPhiRewards(phiRewardsContract_);
        credContract = ICred(credContract_);
    }

    /*//////////////////////////////////////////////////////////////
                            SETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function updatePhiRewardsContract(address phiRewardsContract_) external onlyOwner {
        if (phiRewardsContract_ == address(0)) {
            revert InvalidAddressZero();
        }
        phiRewardsContract = IPhiRewards(phiRewardsContract_);
        emit PhiRewardsContractUpdated(phiRewardsContract_);
    }

    function updateRoyalty(uint256 newRoyalty_) external onlyOwner {
        if (newRoyalty_ > MAX_ROYALTY_RANGE) {
            revert InvalidRoyalty(newRoyalty_);
        }
        withdrawRoyalty = newRoyalty_;
        emit RoyaltyUpdated(newRoyalty_);
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function deposit(uint256 credId, uint256 amount) external payable {
        if (!credContract.isExist(credId)) revert InvalidCredId();
        if (msg.value != amount) {
            revert InvalidValue(msg.value, amount);
        }
        balanceOf[credId] += amount;
        emit Deposit(credId, amount);
    }

    function distribute(uint256 credId) external {
        if (!credContract.isExist(credId)) revert InvalidCredId();
        uint256 totalBalance = balanceOf[credId];
        if (totalBalance == 0) {
            revert NoBalanceToDistribute();
        }

        address[] memory distributeAddresses = credContract.getCuratorAddresses(credId, 0, 0);
        uint256 totalNum;

        for (uint256 i = 0; i < distributeAddresses.length; i++) {
            totalNum += credContract.getShareNumber(credId, distributeAddresses[i]);
        }

        if (totalNum == 0) {
            revert NoSharesToDistribute();
        }

        uint256[] memory amounts = new uint256[](distributeAddresses.length);
        bytes4[] memory reasons = new bytes4[](distributeAddresses.length);

        uint256 royaltyfee = (totalBalance * withdrawRoyalty) / RATIO_BASE;
        uint256 distributeAmount = totalBalance - royaltyfee;

        // actualDistributeAmount is used to avoid rounding errors
        // amount[0] = 333 333 333 333 333 333
        // amount[1] = 333 333 333 333 333 333
        // amount[2] = 333 333 333 333 333 333
        uint256 actualDistributeAmount = 0;
        for (uint256 i = 0; i < distributeAddresses.length; i++) {
            address user = distributeAddresses[i];

            uint256 userAmounts = credContract.getShareNumber(credId, user);
            uint256 userRewards = (distributeAmount * userAmounts) / totalNum;

            if (userRewards > 0) {
                amounts[i] = userRewards;
                actualDistributeAmount += userRewards;
            }
        }

        balanceOf[credId] -= totalBalance;

        _msgSender().safeTransferETH(royaltyfee + distributeAmount - actualDistributeAmount);

        //slither-disable-next-line arbitrary-send-eth
        phiRewardsContract.depositBatch{ value: actualDistributeAmount }(
            distributeAddresses, amounts, reasons, "deposit from curator rewards distributor"
        );

        emit RewardsDistributed(
            credId, _msgSender(), royaltyfee + distributeAmount - actualDistributeAmount, distributeAmount, totalBalance
        );
    }
}
