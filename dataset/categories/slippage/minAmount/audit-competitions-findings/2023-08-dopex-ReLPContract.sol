//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

// Contracts
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interfaces
import { IERC20WithBurn } from "../interfaces/IERC20WithBurn.sol";
import { IUniswapV2Router } from "../uniswap_V2/IUniswapV2Router.sol";
import { IUniswapV2Pair } from "../uniswap_V2/IUniswapV2Pair.sol";
import { IRdpxReserve } from "../reserve/IRdpxReserve.sol";
import { IRdpxEthOracle } from "../interfaces/IRdpxEthOracle.sol";
import { IRdpxV2Core } from "../core/IRdpxV2Core.sol";
import { IUniV2LiquidityAmo } from "../interfaces/IUniV2LiquidityAmo.sol";

// Libraries
import { UniswapV2Library } from "../uniswap_V2/libraries/UniswapV2Library.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title reLP contract
/// @author Dopex
/// @notice The reLP contract is a contract that ReLP's liquidity
contract ReLPContract is AccessControl {
  using SafeERC20 for IERC20WithBurn;
  using SafeMath for uint256;

  // ================================ STATE VARIABLES ================================ //
  struct Addresses {
    // token A address
    address tokenA; // rdpx
    // token B address
    address tokenB; // weth
    // pair address
    address pair;
    // rdpxV2Core address
    address rdpxV2Core;
    // tokenA reserve address
    address tokenAReserve;
    // amo address
    address amo;
    // rdpx price oracle
    address rdpxOracle;
    // AMM Factory
    address ammFactory;
    // AMM Router
    address ammRouter;
  }

  struct TokenAInfo {
    // tokenA reserves
    uint256 tokenAReserve;
    // rdpx price
    uint256 tokenAPrice;
    // tokenA LP reserves
    uint256 tokenALpReserve;
  }

  /// @notice  addresses of the contracts
  Addresses public addresses;

  /// @notice reLP factor
  uint256 public reLPFactor;

  /// @notice Precision used for prices, percentages and other calculations
  uint256 public constant DEFAULT_PRECISION = 1e8;

  /// @notice rdpxV2Core role
  bytes32 public constant RDPXV2CORE_ROLE = keccak256("RDPXV2CORE_ROLE");

  /// @notice liquidity slippage tolerance
  uint256 public liquiditySlippageTolerance = 5e5; // 0.5%

  /// @notice The slippage tolernce in swaps in 1e8 precision
  uint256 public slippageTolerance = 5e5; // 0.5%

  // ================================ CONSTRUCTOR ================================ //
  constructor() {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(RDPXV2CORE_ROLE, msg.sender);
  }

  // ================================ ADMIN FUNCTIONS ================================ //
  /**
   * @notice Set the re-LP factor
   * @dev    Can only be called by admin
   * @param  _reLPFactor the bond discount factor
   **/
  function setreLpFactor(
    uint256 _reLPFactor
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(
      _reLPFactor > 0,
      "reLPContract: reLP factor must be greater than 0"
    );
    reLPFactor = _reLPFactor;

    emit LogSetReLpFactor(_reLPFactor);
  }

  /**
   * @notice Set the addresses of the contracts
   * @dev    Can only be called by admin
   * @param  _tokenA the token A address
   * @param  _tokenB the token B address
   * @param _pair the pair address
   * @param _rdpxV2Core the rdpxV2Core address
   * @param _tokenAReserve the token A reserve address
   * @param _amo the AMO address
   * @param _rdpxOracle the rdpx price oracle
   * @param _ammFactory the AMM Factory
   * @param _ammRouter the AMM Router
   **/
  function setAddresses(
    address _tokenA,
    address _tokenB,
    address _pair,
    address _rdpxV2Core,
    address _tokenAReserve,
    address _amo,
    address _rdpxOracle,
    address _ammFactory,
    address _ammRouter
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(
      _tokenA != address(0) &&
        _tokenB != address(0) &&
        _pair != address(0) &&
        _rdpxV2Core != address(0) &&
        _tokenAReserve != address(0) &&
        _amo != address(0) &&
        _rdpxOracle != address(0) &&
        _ammFactory != address(0) &&
        _ammRouter != address(0),
      "reLPContract: address cannot be 0"
    );
    addresses = Addresses({
      tokenA: _tokenA,
      tokenB: _tokenB,
      pair: _pair,
      rdpxV2Core: _rdpxV2Core,
      tokenAReserve: _tokenAReserve,
      amo: _amo,
      rdpxOracle: _rdpxOracle,
      ammFactory: _ammFactory,
      ammRouter: _ammRouter
    });

    IERC20WithBurn(addresses.pair).safeApprove(
      addresses.ammRouter,
      type(uint256).max
    );

    IERC20WithBurn(addresses.tokenA).safeApprove(
      addresses.ammRouter,
      type(uint256).max
    );

    IERC20WithBurn(addresses.tokenB).safeApprove(
      addresses.ammRouter,
      type(uint256).max
    );
  }

  /**
   * @notice sets the liquidity slippage tolerance
   * @dev    Can only be called by admin
   * @param  _liquiditySlippageTolerance the liquidity slippage tolerance
   */
  function setLiquiditySlippageTolerance(
    uint256 _liquiditySlippageTolerance
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(
      _liquiditySlippageTolerance > 0,
      "reLPContract: liquidity slippage tolerance must be greater than 0"
    );
    liquiditySlippageTolerance = _liquiditySlippageTolerance;
  }

  /**
   * @notice sets the slippage tolerance
   * @dev    Can only be called by admin
   * @param  _slippageTolerance the slippage tolerance
   */
  function setSlippageTolerance(
    uint256 _slippageTolerance
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(
      _slippageTolerance > 0,
      "reLPContract: slippage tolerance must be greater than 0"
    );
    slippageTolerance = _slippageTolerance;
  }

  // ================================ RdpxV2Core FUNCTIONS ================================ //

  /**
   * @dev   re-LPs the pool
   * @param _amount the amount to reLP
   **/
  function reLP(uint256 _amount) external onlyRole(RDPXV2CORE_ROLE) {
    // get the pool reserves
    (address tokenASorted, address tokenBSorted) = UniswapV2Library.sortTokens(
      addresses.tokenA,
      addresses.tokenB
    );
    (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
      addresses.ammFactory,
      tokenASorted,
      tokenBSorted
    );

    TokenAInfo memory tokenAInfo = TokenAInfo(0, 0, 0);

    // get tokenA reserves
    tokenAInfo.tokenAReserve = IRdpxReserve(addresses.tokenAReserve)
      .rdpxReserve(); // rdpx reserves

    // get rdpx price
    tokenAInfo.tokenAPrice = IRdpxEthOracle(addresses.rdpxOracle)
      .getRdpxPriceInEth();

    tokenAInfo.tokenALpReserve = addresses.tokenA == tokenASorted
      ? reserveA
      : reserveB;

    uint256 baseReLpRatio = (reLPFactor *
      Math.sqrt(tokenAInfo.tokenAReserve) *
      1e2) / (Math.sqrt(1e18)); // 1e6 precision

    uint256 tokenAToRemove = ((((_amount * 4) * 1e18) /
      tokenAInfo.tokenAReserve) *
      tokenAInfo.tokenALpReserve *
      baseReLpRatio) / (1e18 * DEFAULT_PRECISION * 1e2);

    uint256 totalLpSupply = IUniswapV2Pair(addresses.pair).totalSupply();

    uint256 lpToRemove = (tokenAToRemove * totalLpSupply) /
      tokenAInfo.tokenALpReserve;

    // transfer LP tokens from the AMO
    IERC20WithBurn(addresses.pair).transferFrom(
      addresses.amo,
      address(this),
      lpToRemove
    );

    // calculate min amounts to remove
    uint256 mintokenAAmount = tokenAToRemove -
      ((tokenAToRemove * liquiditySlippageTolerance) / 1e8);
    uint256 mintokenBAmount = ((tokenAToRemove * tokenAInfo.tokenAPrice) /
      1e8) -
      ((tokenAToRemove * tokenAInfo.tokenAPrice) * liquiditySlippageTolerance) /
      1e16;

    (, uint256 amountB) = IUniswapV2Router(addresses.ammRouter).removeLiquidity(
      addresses.tokenA,
      addresses.tokenB,
      lpToRemove,
      mintokenAAmount,
      mintokenBAmount,
      address(this),
      block.timestamp + 10
    );

    address[] memory path;
    path = new address[](2);
    path[0] = addresses.tokenB;
    path[1] = addresses.tokenA;

    // calculate min amount of tokenA to be received
    mintokenAAmount =
      (((amountB / 2) * tokenAInfo.tokenAPrice) / 1e8) -
      (((amountB / 2) * tokenAInfo.tokenAPrice * slippageTolerance) / 1e16);

    uint256 tokenAAmountOut = IUniswapV2Router(addresses.ammRouter)
      .swapExactTokensForTokens(
        amountB / 2,
        mintokenAAmount,
        path,
        address(this),
        block.timestamp + 10
      )[path.length - 1];

    (, , uint256 lp) = IUniswapV2Router(addresses.ammRouter).addLiquidity(
      addresses.tokenA,
      addresses.tokenB,
      tokenAAmountOut,
      amountB / 2,
      0,
      0,
      address(this),
      block.timestamp + 10
    );

    // transfer the lp to the amo
    IERC20WithBurn(addresses.pair).safeTransfer(addresses.amo, lp);
    IUniV2LiquidityAmo(addresses.amo).sync();

    // transfer rdpx to rdpxV2Core
    IERC20WithBurn(addresses.tokenA).safeTransfer(
      addresses.rdpxV2Core,
      IERC20WithBurn(addresses.tokenA).balanceOf(address(this))
    );
    IRdpxV2Core(addresses.rdpxV2Core).sync();
  }

  // ================================ Events FUNCTIONS ================================ //

  event LogSetReLpFactor(uint256 _reLPFactor);
}