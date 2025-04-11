// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Common} from "./libraries/Common.sol";

interface IRewardDistributor {
    function updateRewardsMetadata(
        Common.Distribution[] calldata _distributions
    ) external;
}

contract BribeVault is AccessControl {
    using SafeERC20 for IERC20;

    struct Bribe {
        address token;
        uint256 amount;
    }

    uint256 public fee; // 5000 = 0.5%
    address public feeRecipient; // Protocol treasury
    address public distributor; // RewardDistributor contract
    uint256 public constant feeDivisor = 1000000;
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // Bribe identifiers mapped to Bribe structs
    // A bribe identifier is composed of different info (e.g. protocol, voting round, etc.)
    mapping(bytes32 => Bribe) public bribes;

    // Protocol-specific reward identifiers mapped to bribe identifiers
    // Allows us to group bribes by reward tokens (one token may be used across many bribes)
    mapping(bytes32 => bytes32[]) public rewardToBribes;

    event GrantDepositorRole(address depositor);
    event RevokeDepositorRole(address depositor);
    event SetFee(uint256 _fee);
    event SetFeeRecipient(address _feeRecipient);
    event SetDistributor(address _distributor);
    event DepositBribe(
        bytes32 bribeIdentifier,
        bytes32 rewardIdentifier,
        address token,
        uint256 amount,
        uint256 totalAmount,
        address briber
    );
    event TransferBribe(
        bytes32 rewardIdentifier,
        address token,
        bytes32 proof,
        uint256 feeAmount,
        uint256 distributorAmount
    );
    event EmergencyWithdrawal(address token, uint256 amount, address admin);

    constructor(
        uint256 _fee,
        address _feeRecipient,
        address _distributor
    ) {
        require(_fee <= feeDivisor, "Invalid fee");
        fee = _fee;

        require(_feeRecipient != address(0), "Invalid feeRecipient");
        feeRecipient = _feeRecipient;

        require(_distributor != address(0), "Invalid distributor");
        distributor = _distributor;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
        @notice Grant the depositor role to an address
        @param  depositor  address  Address to grant the depositor role
     */
    function grantDepositorRole(address depositor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(depositor != address(0), "Invalid depositor");
        _grantRole(DEPOSITOR_ROLE, depositor);

        emit GrantDepositorRole(depositor);
    }

    /**
        @notice Revoke the depositor role from an address
        @param  depositor  address  Address to revoke the depositor role
     */
    function revokeDepositorRole(address depositor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(hasRole(DEPOSITOR_ROLE, depositor), "Invalid depositor");
        _revokeRole(DEPOSITOR_ROLE, depositor);

        emit RevokeDepositorRole(depositor);
    }

    /**
        @notice Set the fee collected by the protocol
        @param  _fee  uint256  Fee
     */
    function setFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee <= feeDivisor, "Invalid _fee");
        fee = _fee;

        emit SetFee(_fee);
    }

    /**
        @notice Set the protocol address where fees will be transferred
        @param  _feeRecipient  address  Fee recipient
     */
    function setFeeRecipient(address _feeRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_feeRecipient != address(0), "Invalid feeRecipient");
        feeRecipient = _feeRecipient;

        emit SetFeeRecipient(_feeRecipient);
    }

    /**
        @notice Set the RewardDistributor contract address
        @param  _distributor  address  Distributor
     */
    function setDistributor(address _distributor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_distributor != address(0), "Invalid distributor");
        distributor = _distributor;

        emit SetDistributor(_distributor);
    }

    /**
        @notice Get bribe information based on the specified identifier
        @param  bribeIdentifier  bytes32  The specified bribe identifier
     */
    function getBribe(bytes32 bribeIdentifier)
        external
        view
        returns (address token, uint256 amount)
    {
        Bribe memory b = bribes[bribeIdentifier];
        return (b.token, b.amount);
    }

    /**
        @notice Deposit bribe (ERC20 only)
        @param  bribeIdentifier   bytes32  Unique identifier related to bribe
        @param  rewardIdentifier  bytes32  Unique identifier related to reward
        @param  token             address  Bribe token
        @param  amount            uint256  Bribe token amount
        @param  briber            address  Address that originally called the depositor contract
     */
    function depositBribeERC20(
        bytes32 bribeIdentifier,
        bytes32 rewardIdentifier,
        address token,
        uint256 amount,
        address briber
    ) external onlyRole(DEPOSITOR_ROLE) {
        require(bribeIdentifier.length > 0, "Invalid bribeIdentifier");
        require(rewardIdentifier.length > 0, "Invalid rewardIdentifier");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be greater than 0");
        require(briber != address(0), "Invalid briber");

        Bribe storage b = bribes[bribeIdentifier];
        address currentToken = b.token;
        require(
            // If bribers want to bribe with a different token they need a new identifier
            currentToken == address(0) || currentToken == token,
            "Cannot change token"
        );

        // Since this method is called by a depositor contract, we must transfer from the account
        // that called the depositor contract - amount must be approved beforehand
        IERC20(token).safeTransferFrom(briber, address(this), amount);

        b.amount += amount; // Allow bribers to increase bribe

        // Only set the token address and update the reward-to-bribe mapping if not yet set
        if (currentToken == address(0)) {
            b.token = token;
            rewardToBribes[rewardIdentifier].push(bribeIdentifier);
        }

        emit DepositBribe(
            bribeIdentifier,
            rewardIdentifier,
            token,
            amount,
            b.amount,
            briber
        );
    }

    /**
        @notice Deposit bribe (native token only)
        @param  bribeIdentifier   bytes32 Unique identifier related to bribe
        @param  rewardIdentifier  bytes32 Unique identifier related to reward
        @param  briber            address  Address that originally called the depositor contract
     */
    function depositBribe(
        bytes32 bribeIdentifier,
        bytes32 rewardIdentifier,
        address briber
    ) external payable onlyRole(DEPOSITOR_ROLE) {
        require(bribeIdentifier.length > 0, "Invalid bribeIdentifier");
        require(rewardIdentifier.length > 0, "Invalid rewardIdentifier");
        require(briber != address(0), "Invalid briber");
        require(msg.value > 0, "Value must be greater than 0");

        Bribe storage b = bribes[bribeIdentifier];
        address currentToken = b.token;
        require(
            // For native tokens, the token address is set to this contract to prevent
            // overwriting storage - the address can be anything but address(this) safer
            currentToken == address(0) || currentToken == address(this),
            "Cannot change token"
        );

        b.amount += msg.value; // Allow bribers to increase bribe

        // Only set the token address and update the reward-to-bribe mapping if not yet set
        if (currentToken == address(0)) {
            b.token = address(this);
            rewardToBribes[rewardIdentifier].push(bribeIdentifier);
        }

        emit DepositBribe(
            bribeIdentifier,
            rewardIdentifier,
            b.token,
            msg.value,
            b.amount,
            briber
        );
    }

    /**
        @notice Transfer fees to fee recipient and bribes to distributor and update rewards metadata
        @param  distributions    Distribution[] List of distribution details
        @param  amounts          uint256[] List of amounts for distributor
        @param  fees             uint256[] List of fee amounts for fee recipient
     */
    function transferBribes(
        Common.Distribution[] calldata distributions,
        uint256[] calldata amounts,
        uint256[] calldata fees
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(distributions.length > 0, "Invalid distributions");
        require(
            distributions.length == amounts.length &&
                distributions.length == fees.length,
            "Distributions, amounts, and fees must contain the same # of elements"
        );

        // Transfer the bribe funds to fee recipient and reward distributor
        for (uint256 i = 0; i < distributions.length; i++) {
            bytes32 rewardIdentifier = distributions[i].rewardIdentifier;
            uint256 distributorAmount = amounts[i];
            uint256 feeAmount = fees[i];
            address token = distributions[i].token;
            require(
                rewardToBribes[rewardIdentifier].length > 0,
                "Invalid reward identifier"
            );
            require(token != address(0), "Invalid token address");
            require(distributorAmount > 0, "Invalid pending reward amount");

            // Check whether it's a native token reward
            if (token == address(this)) {
                (bool sentFeeRecipient, ) = feeRecipient.call{value: feeAmount}(
                    ""
                );
                require(
                    sentFeeRecipient,
                    "Failed to transfer to fee recipient"
                );

                (bool sentDistributor, ) = distributor.call{
                    value: distributorAmount
                }("");
                require(sentDistributor, "Failed to transfer to distributor");
            } else {
                IERC20(token).transfer(feeRecipient, feeAmount);
                IERC20(token).transfer(distributor, distributorAmount);
            }

            emit TransferBribe(
                rewardIdentifier,
                token,
                distributions[i].proof,
                feeAmount,
                distributorAmount
            );
        }

        // Update the rewards' metadata
        IRewardDistributor(distributor).updateRewardsMetadata(distributions);
    }

    /**
        @notice Update the rewards metadata of the specified identifiers (only if absolutely needed)
        @param  distributions    Distribution[] List of distribution details
     */
    function updateRewardsMetadata(Common.Distribution[] calldata distributions)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(distributions.length > 0, "Invalid distributions");
        IRewardDistributor(distributor).updateRewardsMetadata(distributions);
    }

    /**
        @notice Withdraw ERC20 tokens to the admin address
        @param  token   address  Token address
        @param  amount  uint256  Token amount
     */
    function emergencyWithdrawERC20(address token, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Invalid amount");

        IERC20(token).transfer(msg.sender, amount);

        emit EmergencyWithdrawal(token, amount, msg.sender);
    }

    /**
        @notice Withdraw native tokens to the admin address
        @param  amount  uint256  Token amount
     */
    function emergencyWithdraw(uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(amount > 0, "Invalid amount");

        (bool sentAdmin, ) = msg.sender.call{value: amount}("");
        require(sentAdmin, "Failed to withdraw");

        emit EmergencyWithdrawal(address(this), amount, msg.sender);
    }
}
