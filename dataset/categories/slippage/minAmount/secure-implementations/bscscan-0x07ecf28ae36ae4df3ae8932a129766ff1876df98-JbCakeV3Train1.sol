/**
 *Submitted for verification at BscScan.com on 2024-09-17
*/

pragma solidity 0.8.26;

/*
 SPDX-License-Identifier: MIT
------------------------------------
 Jonny Blockchain (R) JbCakeTrain smart contract v. 1
 Website :  https://jonnyblockchain.com
------------------------------------
*/
contract JbCakeV3Train1 {
    using SafeBEP20 for IBEP20;
    address payable owner;
    bool locked = false;

    /**
     * owner only access
     */
    modifier onlyOwner() {
        if (msg.sender == owner) {
            _;
        }
    }

    constructor() {
        owner = payable(msg.sender);
    }

    /**
     * train call
     */
    function train(uint amountIn, uint amountOutMin, bytes calldata path, address recipient, uint deadline, address tokenIn) external onlyOwner {
        require(!locked, "The contract is locked");
        require(amountIn > 0, "No amount to process");

        IBEP20 token = IBEP20(tokenIn);
        token.safeTransferFrom(recipient, address(this), amountIn);
        require(token.balanceOf(address(this)) >= amountIn, "Not enough funds");

        uint result = ISwapRouter(0x1b81D678ffb9C0263b24A97847620C99d213eB14).exactInput(ISwapRouter.ExactInputParams(path, recipient, deadline, amountIn, amountOutMin));

        require(result > 0, "Exchange finished with a zero result");
    }

    /**
     * approves the token spending cap
     */
    function approve(address spender, address tokenAddress, uint256 amount) external onlyOwner {
        IBEP20 token = IBEP20(tokenAddress);
        token.approve(spender, amount);
    }

    /**
     * this prevents the contract from freezing
     */
    function retrieveToken(address tokenAddress) external onlyOwner {
        IBEP20 token = IBEP20(tokenAddress);
        uint frozen = token.balanceOf(address(this));
        token.safeTransfer(owner, frozen);
    }

    /**
     * this prevents the contract from freezing
     */
    function retrieveBnb() external onlyOwner {
        uint frozen = address(this).balance;
        owner.transfer(frozen);
    }

    /**
     * this locks contract so it's not able to process requests anymore
     */
    function lock() external onlyOwner {
        locked = true;
    }
}

interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeBEP20 {
    using SafeMath for uint256;
    using Address for address;
    function safeTransfer(IBEP20 token, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    function safeTransferFrom(IBEP20 token, address from, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }
    function callOptionalReturn(IBEP20 token, bytes memory data) private {
        require(address(token).isContract(), "SafeBEP20: call to non-contract");
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeBEP20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeBEP20: BEP20 operation did not succeed");
        }
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        assembly { codehash := extcodehash(account) }
        return (codehash != 0x0 && codehash != accountHash);
    }
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        uint256 c = a - b;
        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        uint256 c = a / b;
        return c;
    }
}