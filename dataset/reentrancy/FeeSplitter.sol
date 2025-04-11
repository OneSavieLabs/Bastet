// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./Curves.sol";
import "./Security.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeSplitter is Security {
    Curves public curves;
    uint256 constant PRECISION = 1e18;

    // Custom errors
    error NoFeesToClaim();
    error NoTokenHolders();

    struct TokenData {
        uint256 cumulativeFeePerToken;
        mapping(address => uint256) userFeeOffset;
        mapping(address => uint256) unclaimedFees;
    }

    struct UserClaimData {
        uint256 claimableFees;
        address token;
    }

    mapping(address => TokenData) internal tokensData;
    mapping(address => address[]) internal userTokens;

    event FeesClaimed(address indexed token, address indexed user, uint256 amount);

    constructor() Security() {}

    function setCurves(Curves curves_) public {
        curves = curves_;
    }

    function balanceOf(address token, address account) public view returns (uint256) {
        return curves.curvesTokenBalance(token, account) * PRECISION;
    }

    function totalSupply(address token) public view returns (uint256) {
        //@dev: this is the amount of tokens that are not locked in the contract. The locked tokens are in the ERC20 contract
        return (curves.curvesTokenSupply(token) - curves.curvesTokenBalance(token, address(curves))) * PRECISION;
    }

    function getUserTokens(address user) public view returns (address[] memory) {
        return userTokens[user];
    }

    function getUserTokensAndClaimable(address user) public view returns (UserClaimData[] memory) {
        address[] memory tokens = getUserTokens(user);
        UserClaimData[] memory result = new UserClaimData[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 claimable = getClaimableFees(token, user);
            result[i] = UserClaimData(claimable, token);
        }
        return result;
    }

    function updateFeeCredit(address token, address account) internal {
        TokenData storage data = tokensData[token];
        uint256 balance = balanceOf(token, account);
        if (balance > 0) {
            uint256 owed = (data.cumulativeFeePerToken - data.userFeeOffset[account]) * balance;
            data.unclaimedFees[account] += owed / PRECISION;
            data.userFeeOffset[account] = data.cumulativeFeePerToken;
        }
    }

    function getClaimableFees(address token, address account) public view returns (uint256) {
        TokenData storage data = tokensData[token];
        uint256 balance = balanceOf(token, account);
        uint256 owed = (data.cumulativeFeePerToken - data.userFeeOffset[account]) * balance;
        return (owed / PRECISION) + data.unclaimedFees[account];
    }

    function claimFees(address token) external {
        updateFeeCredit(token, msg.sender);
        uint256 claimable = getClaimableFees(token, msg.sender);
        if (claimable == 0) revert NoFeesToClaim();
        tokensData[token].unclaimedFees[msg.sender] = 0;
        payable(msg.sender).transfer(claimable);
        emit FeesClaimed(token, msg.sender, claimable);
    }

    function addFees(address token) public payable onlyManager {
        uint256 totalSupply_ = totalSupply(token);
        if (totalSupply_ == 0) revert NoTokenHolders();
        TokenData storage data = tokensData[token];
        data.cumulativeFeePerToken += (msg.value * PRECISION) / totalSupply_;
    }

    function onBalanceChange(address token, address account) public onlyManager {
        TokenData storage data = tokensData[token];
        data.userFeeOffset[account] = data.cumulativeFeePerToken;
        if (balanceOf(token, account) > 0) userTokens[account].push(token);
    }

    //@dev: this may fail if the the list is long. Get first the list with getUserTokens to estimate and prepare the batch
    function batchClaiming(address[] calldata tokenList) external {
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            updateFeeCredit(token, msg.sender);
            uint256 claimable = getClaimableFees(token, msg.sender);
            if (claimable > 0) {
                tokensData[token].unclaimedFees[msg.sender] = 0;
                totalClaimable += claimable;
                emit FeesClaimed(token, msg.sender, claimable);
            }
        }
        if (totalClaimable == 0) revert NoFeesToClaim();
        payable(msg.sender).transfer(totalClaimable);
    }

    receive() external payable {}
}
