// SPDX-License-Identifier: MIT

/*
The Official Fork of PEPE -- $PORK
If you've ever held PEPE, there is a FairDrop claim waiting for you.
Forked and Fairdropped.
 ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄ 
▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌
▐░█▀▀▀▀▀▀▀█░▌▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀█░▌▐░█▀▀▀▀▀▀▀▀▀ 
▐░▌       ▐░▌▐░▌          ▐░▌       ▐░▌▐░▌          `
▐░█▄▄▄▄▄▄▄█░▌▐░█▄▄▄▄▄▄▄▄▄ ▐░█▄▄▄▄▄▄▄█░▌▐░█▄▄▄▄▄▄▄▄▄ 
▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌
▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀ 
▐░▌          ▐░▌          ▐░▌          ▐░▌          
▐░▌          ▐░█▄▄▄▄▄▄▄▄▄ ▐░▌          ▐░█▄▄▄▄▄▄▄▄▄ 
▐░▌          ▐░░░░░░░░░░░▌▐░▌          ▐░░░░░░░░░░░▌
 ▀            ▀▀▀▀▀▀▀▀▀▀▀  ▀            ▀▀▀▀▀▀▀▀▀▀▀ 
                                                    
 ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄    ▄      
▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░▌  ▐░▌     
▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀█░▌▐░█▀▀▀▀▀▀▀█░▌▐░▌ ▐░▌      
▐░▌          ▐░▌       ▐░▌▐░▌       ▐░▌▐░▌▐░▌       
▐░█▄▄▄▄▄▄▄▄▄ ▐░▌       ▐░▌▐░█▄▄▄▄▄▄▄█░▌▐░▌░▌        
▐░░░░░░░░░░░▌▐░▌       ▐░▌▐░░░░░░░░░░░▌▐░░▌         
▐░█▀▀▀▀▀▀▀▀▀ ▐░▌       ▐░▌▐░█▀▀▀▀█░█▀▀ ▐░▌░▌        
▐░▌          ▐░▌       ▐░▌▐░▌     ▐░▌  ▐░▌▐░▌       
▐░▌          ▐░█▄▄▄▄▄▄▄█░▌▐░▌      ▐░▌ ▐░▌ ▐░▌      
▐░▌          ▐░░░░░░░░░░░▌▐░▌       ▐░▌▐░▌  ▐░▌     
 ▀            ▀▀▀▀▀▀▀▀▀▀▀  ▀         ▀  ▀    ▀      

*/
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { INonfungiblePositionManager, ISwapRouter } from './Helpers/UpInterfaces.sol';
import { IUniswapV3Pool } from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import { IUniswapV3Factory } from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';

interface IPepeFork is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
}

contract PepeFork is IERC20, ERC20, IPepeFork {
    address public forkbot;
    uint256 public constant maxSupply = 420690000000000000000000000000000;

    constructor() ERC20("PepeFork", "PORK") {
        forkbot = msg.sender;
    }

    function _safeMint(address to, uint256 amount) internal {
        _mint(to, amount);
        require(totalSupply() <= maxSupply, "Too Much Supply");
    }

    function mint(address to, uint256 amount) public {
        require(msg.sender == forkbot, "Not forkbot");
        _safeMint(to, amount);
    }

}


contract PepeForker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    error NotZkSigner();
    error InvalidClaim();
    error LPNotInitalized();
    error InitialLPAlreadyCreated();
    error MountUp();
    error LPComplete();

    bytes32 public merkleRoot;

    mapping(address => bool) public alreadyClaimedByAddress;
    
    address public zkMessageBridge;

    address public waterVault;

    IPepeFork public pepeFork;

    IWETH public wethContract;

    IERC20 public pepeContract;

    uint256[] lpTokenIDs;

    uint256 public fair = 90_696_956_521_739 ether;
    uint256 public pool = 3_288_217_391_304 ether;
    uint256 public full = 326_704_826_086_957 ether;
    uint256 public noFavorites = 236_644_079 ether;
    
    uint24 public uniPoolFee = 10000;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 200;

    IUniswapV3Factory public uniswapFactory;
    ISwapRouter public uniswapRouter;
    INonfungiblePositionManager public nonfungiblePositionManager;

    constructor(
        IWETH _wethContract,
        IERC20 _pepeContract,
        IUniswapV3Factory _uniswapFactory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        bytes32 _merkleRoot, 
        address _waterVault
    ) {
        merkleRoot = _merkleRoot;
        zkMessageBridge = msg.sender;
        pepeFork = new PepeFork();
        waterVault = _waterVault;
        wethContract = _wethContract;
        pepeContract = _pepeContract;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        uniswapFactory = _uniswapFactory;
    }

    modifier onlyZKsigner() {
        if (msg.sender != zkMessageBridge) revert NotZkSigner();
        _;
    }

    function openAquifer(IERC20 token, uint256 amount) external onlyZKsigner() {
        token.transfer(waterVault, amount);
        uint256 wethAmount = wethContract.balanceOf(address(this));
        if (wethAmount != 0) {
            wethContract.transfer(address(waterVault), wethAmount);
        }
    }
    function ethToWater() external payable onlyZKsigner returns(bool) {
        uint256 eth = address(this).balance;
        if (eth > 0){
            (bool sent, ) = address(waterVault).call{value: eth}("");
            return sent;
        }
    }

    function fairDrop() external payable{
        if (lpTokenIDs.length == 0) revert LPNotInitalized();
         pepeFork.mint(address(this), fair);
    }
    
    function latestLPToken() public view returns (uint256) {
        if (lpTokenIDs.length == 0) revert LPNotInitalized();
        return lpTokenIDs[lpTokenIDs.length - 1];
    }

    function readLPTokens() external view returns (uint256[] memory) {
        return(lpTokenIDs);
    }

    function _mintLiquidityPosition(uint desiredPepeAmount, uint desiredWethAmount) internal returns (uint256 tokenId, uint128 liquidity, uint256 pepeAmount, uint256 wethAmount) {
        (tokenId, liquidity, pepeAmount, wethAmount) = nonfungiblePositionManager.mint(INonfungiblePositionManager.MintParams({
            token0: address(pepeFork),
            token1: address(wethContract),
            fee: uniPoolFee,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            amount0Desired: desiredPepeAmount,
            amount1Desired: desiredWethAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        }));
        lpTokenIDs.push(tokenId);
        return (tokenId, liquidity, pepeAmount, wethAmount);
    }

    function bridgeLiquidityFromChain(uint pepeAmount, uint wethAmount, uint256 LPId) external onlyZKsigner returns (uint128 liquidity, uint256 pepeValue, uint256 weight) {
       return nonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: LPId,
            amount0Desired: pepeAmount,
            amount1Desired: wethAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        }));
    }

     
    function donateAndRegisterLP(uint256 poolId) external payable onlyZKsigner () {
        lpTokenIDs.push(poolId);
    }

    function isLive() public view returns (bool) {
        return (lpTokenIDs.length > 0);
    }

    function donateInitialPoolWitZKSigner() external onlyZKsigner() {
        if(lpTokenIDs.length != 0) revert InitialLPAlreadyCreated();
        pepeFork.mint(msg.sender, (pool + full));
        pepeFork.mint(address(this), (fair));
        wethContract.approve(address(nonfungiblePositionManager), type(uint256).max);
        pepeFork.approve(address(nonfungiblePositionManager), type(uint256).max);
        pepeContract.approve(address(nonfungiblePositionManager), type(uint256).max);
    }
    
    function _collectLPFees(uint256 _lpTokenId, address recipient) internal returns (uint256, uint256) {
        return nonfungiblePositionManager.collect(INonfungiblePositionManager.CollectParams({
            tokenId: _lpTokenId,
            recipient: recipient,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        }));
    }


    function collectLPFees(uint256 _lpTokenId) external payable onlyZKsigner(){
        _collectLPFees(_lpTokenId, waterVault);
        uint256 orignalBal = pepeFork.balanceOf(address(this));
        uint256 collectedBal = pepeFork.balanceOf(address(this));
        uint256 balDiff = collectedBal - orignalBal; 
        if (balDiff > 0){
            pepeFork.transfer(address(waterVault), balDiff);
        }
    }

    function _claim(
        address _address,
        bytes32[] calldata _merkleProof
    ) private nonReentrant {
        if(_canClaim(_address, _merkleProof) != true) revert InvalidClaim();
        alreadyClaimedByAddress[_address] = true;
        SafeERC20.safeTransfer(pepeFork, _address, noFavorites);
    }

    function claim(
        bytes32[] calldata _merkleProof
    ) external payable {
        _claim(msg.sender, _merkleProof);
    }

    function canClaim(
        address _address,
        bytes32[] calldata _merkleProof
    ) external view returns (bool) {
        return _canClaim(_address, _merkleProof);
    }

    function _canClaim(
        address user,
        bytes32[] calldata merkleProof
    ) internal view returns (bool canUserClaim) {
        if(lpTokenIDs.length == 0) revert LPNotInitalized();
        if (alreadyClaimedByAddress[user]) {
            return false;
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user))));
        canUserClaim = MerkleProof.verify(merkleProof, merkleRoot, leaf);
        return canUserClaim;
    }
}