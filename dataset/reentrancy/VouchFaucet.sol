//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IUserManager} from "../interfaces/IUserManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @author Union
/// @title VouchFaucet
contract VouchFaucet is Ownable {
    /* -------------------------------------------------------------------
      Storage 
    ------------------------------------------------------------------- */

    // @notice UserManager contract address
    address public immutable USER_MANAGER;

    // @notice UserManager staking token eg (DAI)
    address public immutable STAKING_TOKEN;

    /// @notice Amount of claimable trust
    uint256 public immutable TRUST_AMOUNT;

    /// @notice Token address to msg sender to claimed amount
    mapping(address => mapping(address => uint256)) public claimedTokens;

    /// @notice Token address to max claimable amount
    mapping(address => uint256) public maxClaimable;

    /* -------------------------------------------------------------------
      Events 
    ------------------------------------------------------------------- */

    /// @notice Fired when max claimable is updated
    /// @param token The token address
    /// @param amount The max amount of tokens claimable
    event SetMaxClaimable(address token, uint256 amount);

    /// @notice Fired when a vouch is claimed
    /// @param sender Msg sender
    event VouchClaimed(address sender);

    /// @notice Fired when tokens are claimed
    /// @param sender Msg sender
    /// @param token The token address
    /// @param amount The amount of token
    event TokensClaimed(address sender, address token, uint256 amount);

    /// @notice Exit
    /// @param amount Amount unstaked
    event Exit(uint256 amount);

    /* -------------------------------------------------------------------
      Constructor 
    ------------------------------------------------------------------- */

    /// @param _userManager UserManager address
    /// @param _trustAmount Amount of trust to give
    constructor(address _userManager, uint256 _trustAmount) {
        address stakingToken = IUserManager(_userManager).stakingToken();

        IERC20(stakingToken).approve(_userManager, 0);
        IERC20(stakingToken).approve(_userManager, type(uint256).max);

        STAKING_TOKEN = stakingToken;
        USER_MANAGER = _userManager;
        TRUST_AMOUNT = _trustAmount;
    }

    /* -------------------------------------------------------------------
      Setters 
    ------------------------------------------------------------------- */

    /// @notice Set the max amount claimable for a token
    /// @param token The token address
    /// @param amount The max amount claimable
    function setMaxClaimable(address token, uint256 amount) external onlyOwner {
        maxClaimable[token] = amount;
        emit SetMaxClaimable(token, amount);
    }

    /* -------------------------------------------------------------------
      Claim Functions 
    ------------------------------------------------------------------- */

    /// @notice Claim vouch from this contract
    function claimVouch() external {
        IUserManager(USER_MANAGER).updateTrust(msg.sender, uint96(TRUST_AMOUNT));
        emit VouchClaimed(msg.sender);
    }

    /// @notice Claim tokens from this contract
    function claimTokens(address token, uint256 amount) external {
        require(claimedTokens[token][msg.sender] <= maxClaimable[token], "amount>max");
        IERC20(token).transfer(msg.sender, amount);
        emit TokensClaimed(msg.sender, token, amount);
    }

    /* -------------------------------------------------------------------
      Union Functions 
    ------------------------------------------------------------------- */

    /// @notice Stake into the UserManager contract
    function stake() external {
        address stakingToken = STAKING_TOKEN;
        uint256 balance = IERC20(stakingToken).balanceOf(address(this));
        IUserManager(USER_MANAGER).stake(uint96(balance));
    }

    /// @notice Exit. Unstake the max unstakable from the userManager
    function exit() external onlyOwner {
        uint256 stakeAmount = IUserManager(USER_MANAGER).getStakerBalance(address(this));
        uint256 locked = IUserManager(USER_MANAGER).getTotalLockedStake(address(this));
        uint256 maxUnstake = stakeAmount - locked;
        IUserManager(USER_MANAGER).unstake(uint96(maxUnstake));
        emit Exit(maxUnstake);
    }

    /// @notice Transfer ERC20 tokens
    /// @param token Token address
    /// @param to Token receiver
    /// @param amount Amount of tokens to send
    function transferERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
