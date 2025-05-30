// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

// ███████╗███████╗██████╗  ██████╗
// ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗
//   ███╔╝ █████╗  ██████╔╝██║   ██║
//  ███╔╝  ██╔══╝  ██╔══██╗██║   ██║
// ███████╗███████╗██║  ██║╚██████╔╝
// ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝

// Website: https://zerolend.xyz
// Discord: https://discord.gg/zerolend
// Twitter: https://twitter.com/zerolendxyz
// Telegram: https://t.me/zerolendxyz

import {IPool} from '../../../interfaces/pool/IPool.sol';
import {DataTypes} from '../configuration/DataTypes.sol';

import {PositionBalanceConfiguration} from '../configuration/PositionBalanceConfiguration.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';

import {TokenConfiguration} from '../configuration/TokenConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {PercentageMath} from '../utils/PercentageMath.sol';

import {PoolEventsLib} from '../../../interfaces/events/PoolEventsLib.sol';
import {WadRayMath} from '../utils/WadRayMath.sol';
import {GenericLogic} from './GenericLogic.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title LiquidationLogic library
 * @notice Implements actions involving management of collateral in the protocol, the main one being the liquidations
 */
library LiquidationLogic {
  using PercentageMath for uint256;
  using PositionBalanceConfiguration for DataTypes.PositionBalance;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using ReserveLogic for DataTypes.ReserveCache;
  using ReserveLogic for DataTypes.ReserveData;
  using SafeERC20 for IERC20;
  using TokenConfiguration for address;
  using UserConfiguration for DataTypes.UserConfigurationMap;
  using WadRayMath for uint256;

  /**
   * @dev Default percentage of borrower's debt to be repaid in a liquidation.
   * @dev Percentage applied when the users health factor is above `CLOSE_FACTOR_HF_THRESHOLD`
   * Expressed in bps, a value of 0.5e4 results in 50.00%
   */
  uint256 internal constant DEFAULT_LIQUIDATION_CLOSE_FACTOR = 0.5e4;

  /**
   * @dev Maximum percentage of borrower's debt to be repaid in a liquidation
   * @dev Percentage applied when the users health factor is below `CLOSE_FACTOR_HF_THRESHOLD`
   * Expressed in bps, a value of 1e4 results in 100.00%
   */
  uint256 public constant MAX_LIQUIDATION_CLOSE_FACTOR = 1e4;

  /**
   * @dev This constant represents below which health factor value it is possible to liquidate
   * an amount of debt corresponding to `MAX_LIQUIDATION_CLOSE_FACTOR`.
   * A value of 0.95e18 results in 0.95
   */
  uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;

  struct LiquidationCallLocalVars {
    uint256 userCollateralBalance;
    uint256 userDebt;
    uint256 actualDebtToLiquidate;
    uint256 actualCollateralToLiquidate;
    uint256 liquidationBonus;
    uint256 healthFactor;
    uint256 liquidationProtocolFeeAmount;
    address collateralPriceSource;
    address debtPriceSource;
    address asset;
    DataTypes.ReserveCache debtReserveCache;
  }

  /**
   * @notice Function to liquidate a position if its Health Factor drops below 1. The caller (liquidator)
   * covers `debtToCover` amount of debt of the user getting liquidated, and receives
   * a proportional amount of the `collateralAsset` plus a bonus to cover market risk
   * @dev Emits the `LiquidationCall()` event
   * @param reservesData The state of all the reserves
   * @param reservesList The addresses of all the active reserves
   * @param usersConfig The users configuration mapping that track the supplied/borrowed assets
   * @param params The additional parameters needed to execute the liquidation function
   */
  function executeLiquidationCall(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    mapping(address => DataTypes.ReserveSupplies) storage totalSupplies,
    mapping(bytes32 => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) external {
    LiquidationCallLocalVars memory vars;

    DataTypes.ReserveData storage collateralReserve = reservesData[params.collateralAsset];
    DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset];
    DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.position];
    vars.debtReserveCache = debtReserve.cache(totalSupplies[params.debtAsset]);
    debtReserve.updateState(params.reserveFactor, vars.debtReserveCache);

    (,,,, vars.healthFactor,) = GenericLogic.calculateUserAccountData(
      balances,
      reservesData,
      reservesList,
      DataTypes.CalculateUserAccountDataParams({userConfig: userConfig, position: params.position, pool: params.pool})
    );

    (vars.userDebt, vars.actualDebtToLiquidate) = _calculateDebt(
      // vars.debtReserveCache,
      params,
      vars.healthFactor,
      balances
    );

    ValidationLogic.validateLiquidationCall(
      userConfig,
      collateralReserve,
      DataTypes.ValidateLiquidationCallParams({
        debtReserveCache: vars.debtReserveCache,
        totalDebt: vars.userDebt,
        healthFactor: vars.healthFactor
      })
    );

    (vars.collateralPriceSource, vars.debtPriceSource, vars.liquidationBonus) = _getConfigurationData(collateralReserve, params);

    vars.userCollateralBalance = balances[params.collateralAsset][params.position].supplyShares;

    (vars.actualCollateralToLiquidate, vars.actualDebtToLiquidate, vars.liquidationProtocolFeeAmount) =
    _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      vars.debtReserveCache,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance,
      vars.liquidationBonus,
      IPool(params.pool).getAssetPrice(params.collateralAsset),
      IPool(params.pool).getAssetPrice(params.debtAsset),
      IPool(params.pool).factory().liquidationProtocolFeePercentage()
    );

    if (vars.userDebt == vars.actualDebtToLiquidate) {
      userConfig.setBorrowing(debtReserve.id, false);
    }

    // If the collateral being liquidated is equal to the user balance,
    // we set the currency as not being used as collateral anymore
    if (vars.actualCollateralToLiquidate + vars.liquidationProtocolFeeAmount == vars.userCollateralBalance) {
      userConfig.setUsingAsCollateral(collateralReserve.id, false);
      emit PoolEventsLib.ReserveUsedAsCollateralDisabled(params.collateralAsset, params.position);
    }

    _repayDebtTokens(params, vars, balances[params.debtAsset], totalSupplies[params.debtAsset]);

    debtReserve.updateInterestRates(
      totalSupplies[params.debtAsset],
      vars.debtReserveCache,
      params.debtAsset,
      IPool(params.pool).getReserveFactor(),
      vars.actualDebtToLiquidate,
      0,
      '',
      ''
    );

    _burnCollateralTokens(
      collateralReserve, params, vars, balances[params.collateralAsset][params.position], totalSupplies[params.collateralAsset]
    );

    // Transfer fee to treasury if it is non-zero
    if (vars.liquidationProtocolFeeAmount != 0) {
      uint256 liquidityIndex = collateralReserve.getNormalizedIncome();
      uint256 scaledDownLiquidationProtocolFee = vars.liquidationProtocolFeeAmount.rayDiv(liquidityIndex);
      uint256 scaledDownUserBalance = balances[params.collateralAsset][params.position].supplyShares;

      if (scaledDownLiquidationProtocolFee > scaledDownUserBalance) {
        vars.liquidationProtocolFeeAmount = scaledDownUserBalance.rayMul(liquidityIndex);
      }

      IERC20(params.collateralAsset).safeTransfer(IPool(params.pool).factory().treasury(), vars.liquidationProtocolFeeAmount);
    }

    // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
    IERC20(params.debtAsset).safeTransferFrom(msg.sender, address(params.pool), vars.actualDebtToLiquidate);

    emit PoolEventsLib.LiquidationCall(
      params.collateralAsset, params.debtAsset, params.position, vars.actualDebtToLiquidate, vars.actualCollateralToLiquidate, msg.sender
    );
  }

  /**
   * @notice Burns the collateral aTokens and transfers the underlying to the liquidator.
   * @dev   The function also updates the state and the interest rate of the collateral reserve.
   *
   * @param collateralReserve The data of the collateral reserve
   * @param params The additional parameters needed to execute the liquidation function
   * @param vars The executeLiquidationCall() function local vars
   */
  function _burnCollateralTokens(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars,
    DataTypes.PositionBalance storage balances,
    DataTypes.ReserveSupplies storage totalSupplies
  ) internal {
    DataTypes.ReserveCache memory collateralReserveCache = collateralReserve.cache(totalSupplies);
    collateralReserve.updateState(params.reserveFactor, collateralReserveCache);
    collateralReserve.updateInterestRates(
      totalSupplies,
      collateralReserveCache,
      params.collateralAsset,
      IPool(params.pool).getReserveFactor(),
      0,
      vars.actualCollateralToLiquidate,
      params.position,
      params.data.interestRateData
    );

    // Burn the equivalent amount of aToken, sending the underlying to the liquidator
    balances.withdrawCollateral(totalSupplies, vars.actualCollateralToLiquidate, collateralReserveCache.nextLiquidityIndex);
    IERC20(params.collateralAsset).safeTransfer(msg.sender, vars.actualCollateralToLiquidate);
  }

  /**
   * @notice Burns the debt tokens of the user up to the amount being repaid by the liquidator.
   * @dev The function alters the `debtReserveCache` state in `vars` to update the debt related data.
   *
   * @param params The additional parameters needed to execute the liquidation function
   * @param vars the executeLiquidationCall() function local vars
   */
  function _repayDebtTokens(
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars,
    mapping(bytes32 => DataTypes.PositionBalance) storage balances,
    DataTypes.ReserveSupplies storage totalSupplies
  ) internal {
    uint256 burnt = balances[params.position].repayDebt(totalSupplies, vars.actualDebtToLiquidate, vars.debtReserveCache.nextBorrowIndex);
    vars.debtReserveCache.nextDebtShares = burnt;
  }

  /**
   * @notice Calculates the total debt of the user and the actual amount to liquidate depending on the health factor
   * and corresponding close factor.
   *
   * @dev If the Health Factor is below CLOSE_FACTOR_HF_THRESHOLD, the close factor is increased to MAX_LIQUIDATION_CLOSE_FACTOR
   * @param params The additional parameters needed to execute the liquidation function
   * @param healthFactor The health factor of the position
   * @return The debt of the user
   * @return The actual debt to liquidate as a function of the closeFactor
   */
  function _calculateDebt(
    DataTypes.ExecuteLiquidationCallParams memory params,
    uint256 healthFactor,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances
  ) internal view returns (uint256, uint256) {
    uint256 userDebt = balances[params.debtAsset][params.position].debtShares;

    uint256 closeFactor = healthFactor > CLOSE_FACTOR_HF_THRESHOLD ? DEFAULT_LIQUIDATION_CLOSE_FACTOR : MAX_LIQUIDATION_CLOSE_FACTOR;

    uint256 maxLiquidatableDebt = userDebt.percentMul(closeFactor);

    uint256 actualDebtToLiquidate = params.debtToCover > maxLiquidatableDebt ? maxLiquidatableDebt : params.debtToCover;

    return (userDebt, actualDebtToLiquidate);
  }

  /**
   * @notice Returns the configuration data for the debt and the collateral reserves.
   * @param collateralReserve The data of the collateral reserve
   * @param params The additional parameters needed to execute the liquidation function
   *
   * @return The address to use as price source for the collateral
   * @return The address to use as price source for the debt
   * @return The liquidation bonus to apply to the collateral
   */
  function _getConfigurationData(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) internal view returns (address, address, uint256) {
    uint256 liquidationBonus = collateralReserve.configuration.getLiquidationBonus();

    address collateralPriceSource = params.collateralAsset;
    address debtPriceSource = params.debtAsset;

    return (collateralPriceSource, debtPriceSource, liquidationBonus);
  }

  struct AvailableCollateralToLiquidateLocalVars {
    uint256 collateralPrice;
    uint256 debtAssetPrice;
    uint256 maxCollateralToLiquidate;
    uint256 baseCollateral;
    uint256 bonusCollateral;
    uint256 debtAssetDecimals;
    uint256 collateralDecimals;
    uint256 collateralAssetUnit;
    uint256 debtAssetUnit;
    uint256 collateralAmount;
    uint256 debtAmountNeeded;
    uint256 liquidationProtocolFeePercentage;
    uint256 liquidationProtocolFee;
  }

  /**
   * @notice Calculates how much of a specific collateral can be liquidated, given
   * a certain amount of debt asset.
   *
   * @dev This function needs to be called after all the checks to validate the liquidation have been performed,
   *   otherwise it might fail.
   *
   * @param collateralReserve The data of the collateral reserve
   * @param debtReserveCache The cached data of the debt reserve
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param userCollateralBalance The collateral balance for the specific `collateralAsset` of the user being liquidated
   * @param liquidationBonus The collateral bonus percentage to receive as result of the liquidation
   * @return The maximum amount that is possible to liquidate given all the liquidation constraints (user balance, close factor)
   * @return The amount to repay with the liquidation
   * @return The fee taken from the liquidation bonus amount to be paid to the protocol
   */
  function _calculateAvailableCollateralToLiquidate(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ReserveCache memory debtReserveCache,
    uint256 debtToCover,
    uint256 userCollateralBalance,
    uint256 liquidationBonus,
    uint256 collateralPrice,
    uint256 debtAssetPrice,
    uint256 liquidationProtocolFeePercentage
  ) internal view returns (uint256, uint256, uint256) {
    AvailableCollateralToLiquidateLocalVars memory vars;

    vars.collateralPrice = collateralPrice; // oracle.getAssetPrice(collateralAsset);
    vars.debtAssetPrice = debtAssetPrice; // oracle.getAssetPrice(debtAsset);

    vars.collateralDecimals = collateralReserve.configuration.getDecimals();
    vars.debtAssetDecimals = debtReserveCache.reserveConfiguration.getDecimals();

    unchecked {
      vars.collateralAssetUnit = 10 ** vars.collateralDecimals;
      vars.debtAssetUnit = 10 ** vars.debtAssetDecimals;
    }

    // This is the base collateral to liquidate based on the given debt to cover
    vars.baseCollateral = ((vars.debtAssetPrice * debtToCover * vars.collateralAssetUnit)) / (vars.collateralPrice * vars.debtAssetUnit);

    vars.maxCollateralToLiquidate = vars.baseCollateral.percentMul(liquidationBonus);

    if (vars.maxCollateralToLiquidate > userCollateralBalance) {
      vars.collateralAmount = userCollateralBalance;
      vars.debtAmountNeeded = (
        (vars.collateralPrice * vars.collateralAmount * vars.debtAssetUnit) / (vars.debtAssetPrice * vars.collateralAssetUnit)
      ).percentDiv(liquidationBonus);
    } else {
      vars.collateralAmount = vars.maxCollateralToLiquidate;
      vars.debtAmountNeeded = debtToCover;
    }

    if (liquidationProtocolFeePercentage != 0) {
      vars.bonusCollateral = vars.collateralAmount - vars.collateralAmount.percentDiv(liquidationBonus);
      vars.liquidationProtocolFee = vars.bonusCollateral.percentMul(liquidationProtocolFeePercentage);
      return (vars.collateralAmount - vars.liquidationProtocolFee, vars.debtAmountNeeded, vars.liquidationProtocolFee);
    } else {
      return (vars.collateralAmount, vars.debtAmountNeeded, 0);
    }
  }
}
