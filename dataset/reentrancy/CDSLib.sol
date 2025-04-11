// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

import "../interface/ITreasury.sol";
import "../interface/IUSDa.sol";
import "../interface/IBorrowing.sol";
import "../interface/CDSInterface.sol";
import "../interface/IGlobalVariables.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

library CDSLib {
    uint128 constant PRECISION = 1e12;
    uint128 constant RATIO_PRECISION = 1e4;
    uint256 constant NORM_PRECISION = 1e8;

    /**
     * @dev calculates the cumulative value
     * @param _price eth price
     * @param totalCdsDepositedAmount total cds deposited amount
     * @param lastEthPrice last recorded eth price
     * @param vaultBal treasury vault balance
     */
    function calculateCumulativeValue(
        uint128 _price,
        uint256 totalCdsDepositedAmount,
        uint128 lastEthPrice,
        uint256 vaultBal
    ) public pure returns (CDSInterface.CalculateValueResult memory) {
        uint128 _amount = 1000;
        uint128 priceDiff;
        uint128 value;
        bool gains;
        // if total cds deposited amount is zero
        if (totalCdsDepositedAmount == 0) {
            value = 0;
            gains = true;
        } else {
            // If the current eth price is higher than last eth price,then it is gains
            if (_price > lastEthPrice) {
                priceDiff = _price - lastEthPrice;
                gains = true;
            } else {
                priceDiff = lastEthPrice - _price;
                gains = false;
            }

            value = uint128((_amount * vaultBal * priceDiff * 1e6) / (PRECISION * totalCdsDepositedAmount));
        }
        return CDSInterface.CalculateValueResult(value, gains);
    }

    /**
     * @dev get the options fees proportions
     * @param optionsFees optionsFees
     * @param _totalCdsDepositedAmount cds amount in this chain
     * @param _totalGlobalCdsDepositedAmount cds amount in global
     * @param _totalCdsDepositedAmountWithOptionFees cds amount with options fees in this chain
     * @param _totalGlobalCdsDepositedAmountWithOptionFees cds amount with options fees in global
     */
    function getOptionsFeesProportions(
        uint256 optionsFees,
        uint256 _totalCdsDepositedAmount,
        uint256 _totalGlobalCdsDepositedAmount,
        uint256 _totalCdsDepositedAmountWithOptionFees,
        uint256 _totalGlobalCdsDepositedAmountWithOptionFees
    ) public pure returns (uint256) {
        // calculate other chain cds amount
        uint256 otherChainCDSAmount = _totalGlobalCdsDepositedAmount - _totalCdsDepositedAmount;
        // calculate option fees in otherchain
        uint256 totalOptionFeesInOtherChain = _totalGlobalCdsDepositedAmountWithOptionFees - _totalCdsDepositedAmountWithOptionFees - otherChainCDSAmount;
        // calculate options fees in this chain
        uint256 totalOptionFeesInThisChain = _totalCdsDepositedAmountWithOptionFees - _totalCdsDepositedAmount;
        // calculate share of both chains
        uint256 share = (otherChainCDSAmount * 1e10) / _totalGlobalCdsDepositedAmount;
        // options fees to get from other chain
        uint256 optionsfeesToGet = (optionsFees * share) / 1e10;
        // options fees to get from this chain
        uint256 optionsFeesRemaining = optionsFees - optionsfeesToGet;

        // if the options fees in other chain is zero
        if (totalOptionFeesInOtherChain == 0) {
            // options fees to get from otherchain is zero
            optionsfeesToGet = 0;
        } else {
            // if the options fees in other chain is insufficient
            // take the remaining from this chain
            if (totalOptionFeesInOtherChain < optionsfeesToGet) {
                optionsfeesToGet = totalOptionFeesInOtherChain;
            } else {
                if (
                    totalOptionFeesInOtherChain > optionsfeesToGet &&
                    totalOptionFeesInThisChain < optionsFeesRemaining
                ) {
                    optionsfeesToGet += optionsFeesRemaining - totalOptionFeesInThisChain;
                } else {
                    optionsfeesToGet = optionsfeesToGet;
                }
            }
        }
        return optionsfeesToGet;
    }

    /**
     * @dev gets cumulative value
     * @param _value value to add
     * @param _gains eth price change gains
     * @param _cumulativeValueSign boolean tells, whether the cumlative value is positive or negative
     * @param _cumulativeValue cumulative value
     */
    function getCumulativeValue(
        uint128 _value,
        bool _gains,
        bool _cumulativeValueSign,
        uint128 _cumulativeValue
    ) public pure returns (uint128, bool) {
        if (_gains) {
            // If the cumulativeValue is positive
            if (_cumulativeValueSign) {
                // Add value to cumulativeValue
                _cumulativeValue += _value;
            } else {
                // if the cumulative value is greater than value
                if (_cumulativeValue > _value) {
                    // Remains in negative
                    _cumulativeValue -= _value;
                } else {
                    // Going to postive since value is higher than cumulative value
                    _cumulativeValue = _value - _cumulativeValue;
                    _cumulativeValueSign = true;
                }
            }
        } else {
            // If cumulative value is in positive
            if (_cumulativeValueSign) {
                if (_cumulativeValue > _value) {
                    // Cumulative value remains in positive
                    _cumulativeValue -= _value;
                } else {
                    // Going to negative since value is higher than cumulative value
                    _cumulativeValue = _value - _cumulativeValue;
                    _cumulativeValueSign = false;
                }
            } else {
                // Cumulative value is in negative
                _cumulativeValue += _value;
            }
        }

        return (_cumulativeValue, _cumulativeValueSign);
    }

    /**
     * @dev calculates the cumulative rate
     * @param _fees options fees
     * @param _totalCdsDepositedAmount cds deposited amount
     * @param _totalCdsDepositedAmountWithOptionFees cds deposited amount with options fees
     * @param _totalGlobalCdsDepositedAmountWithOptionFees global cds depsoited amount with options fees
     * @param _lastCumulativeRate last cumulative rate
     * @param _noOfBorrowers number of borrowers
     */
    function calculateCumulativeRate(
        uint128 _fees,
        uint256 _totalCdsDepositedAmount,
        uint256 _totalCdsDepositedAmountWithOptionFees,
        uint256 _totalGlobalCdsDepositedAmountWithOptionFees,
        uint128 _lastCumulativeRate,
        uint128 _noOfBorrowers
    ) public pure returns (uint256, uint256, uint128) {
        // check the fees is non zero
        require(_fees != 0, "Fees should not be zero");
        // if there is some deposits in cds then only increment fees
        if (_totalCdsDepositedAmount > 0) {
            _totalCdsDepositedAmountWithOptionFees += _fees;
        }
        uint128 netCDSPoolValue = uint128(
            _totalGlobalCdsDepositedAmountWithOptionFees
        );
        _totalGlobalCdsDepositedAmountWithOptionFees += _fees;
        // Calculate percentage change
        uint128 percentageChange = (_fees * PRECISION) / netCDSPoolValue;
        uint128 currentCumulativeRate;
        // If there is no borrowers
        if (_noOfBorrowers == 0 && _lastCumulativeRate == PRECISION) {
            currentCumulativeRate = PRECISION + percentageChange;
            _lastCumulativeRate = currentCumulativeRate;
        } else {
            currentCumulativeRate = _lastCumulativeRate * (PRECISION + percentageChange);
            _lastCumulativeRate = (currentCumulativeRate / PRECISION);
        }

        return (
            _totalCdsDepositedAmountWithOptionFees,
            _totalGlobalCdsDepositedAmountWithOptionFees,
            _lastCumulativeRate
        );
    }

    /**
     * @dev calcultes user proportion in withraw
     * @param depositedAmount deposited amount
     * @param returnAmount withdraw amount
     */
    function calculateUserProportionInWithdraw(
        uint256 depositedAmount,
        uint256 returnAmount
    ) public pure returns (uint128) {
        uint256 toUser;
        // if the return amount is greater than depsoited amount,
        // deduct 10% from it
        if (returnAmount > depositedAmount) {
            uint256 profit = returnAmount - depositedAmount;
            toUser = returnAmount - (profit * 10) / 100;
        } else {
            toUser = returnAmount;
        }

        return uint128(toUser);
    }

    /**
     * @dev calculates cds amount to return based on price change gain or loss
     * @param depositData struct contains deposit user data
     * @param result struct containing, calculate value result
     * @param currentCumulativeValue current cumulative value
     * @param currentCumulativeValueSign current cumulative value sign
     */
    function cdsAmountToReturn(
        CDSInterface.CdsAccountDetails memory depositData,
        CDSInterface.CalculateValueResult memory result,
        uint128 currentCumulativeValue,
        bool currentCumulativeValueSign
    ) public pure returns (uint256) {
        // get the cumulative value
        (uint128 cumulativeValue, bool cumulativeValueSign) = getCumulativeValue(
                result.currentValue,
                result.gains,
                currentCumulativeValueSign,
                currentCumulativeValue
            );
        uint256 depositedAmount = depositData.depositedAmount;
        uint128 cumulativeValueAtDeposit = depositData.depositValue;
        // Get the cumulative value sign at the time of deposit
        bool cumulativeValueSignAtDeposit = depositData.depositValueSign;
        uint128 valDiff;
        uint128 cumulativeValueAtWithdraw = cumulativeValue;

        // If the depositVal and cumulativeValue both are in same sign
        if (cumulativeValueSignAtDeposit == cumulativeValueSign) {
            if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                valDiff = cumulativeValueAtDeposit - cumulativeValueAtWithdraw;
            } else {
                valDiff = cumulativeValueAtWithdraw - cumulativeValueAtDeposit;
            }
            // If cumulative value sign at the time of deposit is positive
            if (cumulativeValueSignAtDeposit) {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    // Its loss since cumulative val is low
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                } else {
                    // Its gain since cumulative val is high
                    uint256 profit = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount + profit);
                }
            } else {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    uint256 profit = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount + profit);
                } else {
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                }
            }
        } else {
            valDiff = cumulativeValueAtDeposit + cumulativeValueAtWithdraw;
            if (cumulativeValueSignAtDeposit) {
                uint256 loss = (depositedAmount * valDiff) / 1e11;
                return (depositedAmount - loss);
            } else {
                uint256 profit = (depositedAmount * valDiff) / 1e11;
                return (depositedAmount + profit);
            }
        }
    }

    /**
     * @dev get user share
     * @param amount amount in wei
     * @param share share in percentage with 1e10 precision
     */
    function getUserShare(
        uint128 amount,
        uint128 share
    ) public pure returns (uint128) {
        return (amount * share) / 1e10;
    }

    /**
     * @dev gets the lz fucntions to do in dst chain
     * @param optionsFeesToGetFromOtherChain options Fees To Get From OtherChain
     * @param collateralToGetFromOtherChain collateral To Get From OtherChain
     */
    function getLzFunctionToDo(
        uint256 optionsFeesToGetFromOtherChain,
        uint256 collateralToGetFromOtherChain
    ) public pure returns (uint8 functionToDo) {
        //Based on non zero value, the function to do is defined,
        // FunctionToDo enum is defined in the interface
        if (optionsFeesToGetFromOtherChain > 0 && collateralToGetFromOtherChain == 0) {
            functionToDo = 3;
        } else if (optionsFeesToGetFromOtherChain == 0 && collateralToGetFromOtherChain > 0) {
            functionToDo = 4;
        } else if (optionsFeesToGetFromOtherChain > 0 && collateralToGetFromOtherChain > 0) {
            functionToDo = 5;
        }
    }

    /**
     * @dev Returns the which type of collateral to give to user which is accured during liquidation
     * @param param struct contains, param
     */
    function getLiquidatedCollateralToGive(
        CDSInterface.GetLiquidatedCollateralToGiveParam memory param
    ) public pure returns (uint128, uint128, uint128, uint128, uint128) {
        // calculate the amount needed in eth value
        uint256 totalAmountNeededInETH = param.ethAmountNeeded + (param.weETHAmountNeeded * param.weETHExRate) / 1 ether + (param.rsETHAmountNeeded * param.rsETHExRate) / 1 ether;
        // calculate amount needed in weeth value
        uint256 totalAmountNeededInWeETH = (totalAmountNeededInETH * 1 ether) / param.weETHExRate;
        // calculate amount needed in rseth value
        uint256 totalAmountNeededInRsETH = (totalAmountNeededInETH * 1 ether) / param.rsETHExRate;

        uint256 liquidatedCollateralToGiveInETH;
        uint256 liquidatedCollateralToGiveInWeETH;
        uint256 liquidatedCollateralToGiveInRsETH;
        uint256 liquidatedCollateralToGetFromOtherChainInETHValue;
        // If this chain has sufficient amount
        if (param.totalCollateralAvailableInETHValue >= totalAmountNeededInETH) {
            // If total amount is avaialble in eth itself
            if (param.ethAvailable >= totalAmountNeededInETH) {
                liquidatedCollateralToGiveInETH = totalAmountNeededInETH;
                // If total amount is avaialble in weeth itself
            } else if (param.weETHAvailable >= totalAmountNeededInWeETH) {
                liquidatedCollateralToGiveInWeETH = totalAmountNeededInWeETH;
                // If total amount is avaialble in rseth itself
            } else if (param.rsETHAvailable >= totalAmountNeededInRsETH) {
                liquidatedCollateralToGiveInRsETH = totalAmountNeededInRsETH;
            } else {
                // else, get the available amount in each
                liquidatedCollateralToGiveInETH = param.ethAvailable;
                liquidatedCollateralToGiveInWeETH = ((totalAmountNeededInETH - liquidatedCollateralToGiveInETH) * 1 ether) / param.weETHExRate;
                if (param.weETHAvailable < liquidatedCollateralToGiveInWeETH) {
                    liquidatedCollateralToGiveInWeETH = param.weETHAvailable;
                    liquidatedCollateralToGiveInRsETH = (
                            (totalAmountNeededInETH - liquidatedCollateralToGiveInETH - (liquidatedCollateralToGiveInWeETH * param.weETHExRate) / 1 ether) * 1 ether
                        ) / param.rsETHExRate;
                }
            }
        } else {
            liquidatedCollateralToGiveInETH = param.ethAvailable;
            liquidatedCollateralToGiveInWeETH = param.weETHAvailable;
            liquidatedCollateralToGiveInRsETH = param.rsETHAvailable;

            liquidatedCollateralToGetFromOtherChainInETHValue = totalAmountNeededInETH - param.totalCollateralAvailableInETHValue;
        }
        return (
            uint128(totalAmountNeededInETH),
            uint128(liquidatedCollateralToGiveInETH),
            uint128(liquidatedCollateralToGiveInWeETH),
            uint128(liquidatedCollateralToGiveInRsETH),
            uint128(liquidatedCollateralToGetFromOtherChainInETHValue)
        );
    }

    /**
     * @dev acts as dex usda to usdt
     * @param usdaAmount usda amount to deposit
     * @param usdaPrice usda price
     * @param usdtPrice usdt price
     */
    function redeemUSDT(
        CDSInterface.Interfaces memory interfaces,
        uint256 burnedUSDaInRedeem,
        uint128 usdaAmount,
        uint64 usdaPrice,
        uint64 usdtPrice
    ) external returns (uint256) {
        // CHeck the usdaAmount is non zero
        if (usdaAmount == 0) revert CDSInterface.CDS_NeedsMoreThanZero();
        // Check the user has enough usda balance
        if (interfaces.usda.balanceOf(msg.sender) < usdaAmount)
            revert CDSInterface.CDS_Insufficient_USDa_Balance();
        // Increment burnedUSDaInRedeem
        burnedUSDaInRedeem += usdaAmount;
        // GET the omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = interfaces.globalVariables.getOmniChainData();
        // Increment burnedUSDaInRedeem
        omniChainData.burnedUSDaInRedeem += usdaAmount;
        // burn usda
        bool transfer = interfaces.usda.burnFromUser(msg.sender, usdaAmount);
        if (!transfer) revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.USDa);
        // calculate the USDT USDa ratio
        uint128 usdtAmount = ((usdaPrice * usdaAmount) / usdtPrice);

        interfaces.treasury.approveTokens(IBorrowing.AssetName.TUSDT, address(interfaces.cds), usdtAmount);
        // Transfer usdt to user
        bool success = interfaces.usdt.transferFrom(
            address(interfaces.treasury),
            msg.sender,
            usdtAmount
        );
        if (!success) revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.TUSDT);

        interfaces.globalVariables.setOmniChainData(omniChainData);

        return burnedUSDaInRedeem;
    }

    function deposit(
        CDSInterface.DepositUserParams memory params,
        mapping(address => CDSInterface.CdsDetails) storage cdsDetails,
        CDSInterface.Interfaces memory interfaces
    ) public returns (CDSInterface.DepositResult memory) {
        // totalDepositingAmount is usdt and usda
        uint256 totalDepositingAmount = params.usdtAmount + params.usdaAmount;
        // Check the totalDepositingAmount is non zero
        if (totalDepositingAmount == 0) revert CDSInterface.CDS_ShouldNotBeZero(); // check _amount not zero
        // Check the liquidationAmount is lesser than totalDepositingAmount
        if (params.liquidationAmount > totalDepositingAmount) revert CDSInterface.CDS_LiqAmountExceedsDepositAmount(
                params.liquidationAmount,
                totalDepositingAmount
            );
        // Get the global omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = interfaces.globalVariables.getOmniChainData();

        // Check whether the usdt limit is reached or not
        if (omniChainData.usdtAmountDepositedTillNow < params.usdtLimit) {
            // If the usdtAmountDepositedTillNow and current depositing usdt amount is lesser or
            // equal to usdtLimit
            if (
                (omniChainData.usdtAmountDepositedTillNow +
                    params.usdtAmount) <= params.usdtLimit
            ) {
                // Check the totalDepositingAmount is usdt amount
                if (params.usdtAmount != totalDepositingAmount) revert CDSInterface.CDS_NeedsUSDTOnly();
            } else {
                revert CDSInterface.CDS_SurplusUSDT();
            }
        } else {
            // usda amount must be 80% of totalDepositingAmount
            if (
                params.usdaAmount <
                (params.usdaLimit * totalDepositingAmount) / 100
            ) revert CDSInterface.CDS_RequiredUSDaNotMet();
            // Check the user has enough usda
            if (interfaces.usda.balanceOf(msg.sender) < params.usdaAmount) revert CDSInterface.CDS_Insufficient_USDa_Balance(); // check if user has sufficient USDa token
        }
        // Check the eth price is non zero
        if (params.ethPrice == 0) revert CDSInterface.CDS_ETH_PriceFeed_Failed();
        uint64 index;

        // check if msg.sender is depositing for the first time
        // if yes change hasDeposited from desDeposit structure of msg.sender to true.
        // if not increase index of msg.sender in cdsDetails by 1.
        if (!cdsDetails[msg.sender].hasDeposited) {
            //change index value to 1
            index = cdsDetails[msg.sender].index = 1;

            //change hasDeposited to true
            cdsDetails[msg.sender].hasDeposited = true;
            //Increase cdsCount if msg.sender is depositing for the first time
            ++params.cdsCount;
            // updating global data
            ++omniChainData.cdsCount;
        } else {
            //increase index value by 1
            index = ++cdsDetails[msg.sender].index;
        }

        CDSInterface.CdsAccountDetails memory cdsDepositDetails = cdsDetails[msg.sender].cdsAccountDetails[index];

        //add deposited amount of msg.sender of the perticular index in cdsAccountDetails
        cdsDepositDetails.depositedAmount = totalDepositingAmount;

        //storing current ETH/USD rate
        cdsDepositDetails.depositPrice = params.ethPrice;
        // Calculate the cumulatice value
        CDSInterface.CalculateValueResult memory result = calculateCumulativeValue(
            params.ethPrice,
            omniChainData.totalCdsDepositedAmount,
            params.lastEthPrice,
            //params.fallbackEthPrice,
            omniChainData.totalVolumeOfBorrowersAmountinWei
        );
        // Set the cumulative value
        (omniChainData.cumulativeValue, omniChainData.cumulativeValueSign) = getCumulativeValue(
            result.currentValue,
            result.gains,
            omniChainData.cumulativeValueSign,
            omniChainData.cumulativeValue
        );

        // updating global data
        if (omniChainData.downsideProtected > 0) {
            omniChainData.totalCdsDepositedAmount -= omniChainData.downsideProtected;
            omniChainData.totalCdsDepositedAmountWithOptionFees -= omniChainData.downsideProtected;
            omniChainData.downsideProtected = 0;
        }
        // Store the cumulative value and cumulative value sign
        cdsDepositDetails.depositValue = omniChainData.cumulativeValue;
        cdsDepositDetails.depositValueSign = omniChainData.cumulativeValueSign;

        //add deposited amount to totalCdsDepositedAmount
        params.totalCdsDepositedAmount += totalDepositingAmount;
        params.totalCdsDepositedAmountWithOptionFees += totalDepositingAmount;

        omniChainData.totalCdsDepositedAmount += totalDepositingAmount;
        omniChainData.totalCdsDepositedAmountWithOptionFees += totalDepositingAmount;

        //increment usdtAmountDepositedTillNow
        params.usdtAmountDepositedTillNow += params.usdtAmount;

        // updating global data
        omniChainData.usdtAmountDepositedTillNow += params.usdtAmount;
        omniChainData.cdsPoolValue += totalDepositingAmount;

        //add deposited time of perticular index and amount in cdsAccountDetails
        cdsDepositDetails.depositedTime = uint64(block.timestamp);
        cdsDepositDetails.normalizedAmount = ((totalDepositingAmount * PRECISION * NORM_PRECISION) / (omniChainData.lastCumulativeRate));

        // update the user data
        cdsDepositDetails.optedLiquidation = params.liquidate;
        cdsDepositDetails.lockingPeriod = params.lockingPeriod;
        cdsDepositDetails.depositedUSDa = params.usdaAmount;
        cdsDepositDetails.depositedUSDT = params.usdtAmount;

        //If user opted for liquidation
        if (params.liquidate) {
            cdsDepositDetails.liquidationindex = omniChainData.noOfLiquidations;
            cdsDepositDetails.liquidationAmount = params.liquidationAmount;
            cdsDepositDetails.initialLiquidationAmount = params.liquidationAmount;
            params.totalAvailableLiquidationAmount += params.liquidationAmount;

            // updating global data
            omniChainData.totalAvailableLiquidationAmount += params.liquidationAmount;
        }

        cdsDetails[msg.sender].cdsAccountDetails[index] = cdsDepositDetails;

        if (params.usdtAmount != 0 && params.usdaAmount != 0) {
            if (interfaces.usdt.balanceOf(msg.sender) < params.usdtAmount) revert CDSInterface.CDS_Insufficient_USDT_Balance(); // check if user has sufficient USDa token
            bool usdtTransfer = interfaces.usdt.transferFrom(
                msg.sender,
                address(interfaces.treasury),
                params.usdtAmount
            ); // transfer amount to this contract
            if (!usdtTransfer) revert CDSInterface.CDS_USDT_TransferFailed();
            //Transfer USDa tokens from msg.sender to this contract
            bool usdaTransfer = interfaces.usda.transferFrom(
                msg.sender,
                address(interfaces.treasury),
                params.usdaAmount
            ); // transfer amount to this contract
            if (!usdaTransfer) revert CDSInterface.CDS_USDa_TransferFailed();
        } else if (params.usdtAmount == 0) {
            bool transfer = interfaces.usda.transferFrom(
                msg.sender,
                address(interfaces.treasury),
                params.usdaAmount
            ); // transfer amount to this contract
            //check it token have successfully transfer or not
            if (!transfer) revert CDSInterface.CDS_USDa_TransferFailed();
        } else {
            if (interfaces.usdt.balanceOf(msg.sender) < params.usdtAmount) revert CDSInterface.CDS_Insufficient_USDT_Balance(); // check if user has sufficient USDa token
            bool transfer = interfaces.usdt.transferFrom(
                msg.sender,
                address(interfaces.treasury),
                params.usdtAmount
            ); // transfer amount to this contract
            //check it token have successfully transfer or not
            if (!transfer) revert CDSInterface.CDS_USDT_TransferFailed();
        }

        // If the entered usda amount is eligible mint it
        if (params.usdtAmount != 0) {
            bool success = interfaces.usda.mint(
                address(interfaces.treasury),
                params.usdtAmount
            );
            if (!success) revert CDSInterface.CDS_USDa_MintFailed();
        }

        interfaces.globalVariables.setOmniChainData(omniChainData);

        return CDSInterface.DepositResult(
                params.usdtAmountDepositedTillNow,
                params.totalCdsDepositedAmount,
                params.totalCdsDepositedAmountWithOptionFees,
                params.totalAvailableLiquidationAmount,
                params.cdsCount
            );
    }

    /**
     * @dev Withdraw CDS user positions, who opted for liquidation
     * @param params Struct, contains params required for withdraw
     */
    function withdrawUser(
        CDSInterface.WithdrawUserParams memory params,
        CDSInterface.Interfaces memory interfaces,
        uint256 totalCdsDepositedAmount,
        uint256 totalCdsDepositedAmountWithOptionFees,
        mapping(uint128 liquidationIndex => CDSInterface.LiquidationInfo)
            storage omniChainCDSLiqIndexToInfo
    ) public returns (CDSInterface.WithdrawResult memory) {
        if (!params.cdsDepositDetails.optedLiquidation) {
            return withdrawUserWhoNotOptedForLiq(
                    params,
                    interfaces,
                    totalCdsDepositedAmount,
                    totalCdsDepositedAmountWithOptionFees
                );
        } else {
            uint128 weETHAmount;
            uint128 rsETHAmount;
            uint128 weETHAmountInETHValue;
            uint128 rsETHAmountInETHValue;
            uint128 collateralToGetFromOtherChain;
            uint128 totalWithdrawCollateralAmountInETH;

            uint128 liquidationIndexAtDeposit = params.cdsDepositDetails.liquidationindex;
            // If the number of liquidations is greater than or equal to liquidationIndexAtDeposit
            if (
                params.omniChainData.noOfLiquidations >=
                liquidationIndexAtDeposit
            ) {
                // Loop through the liquidations that were done after user enters
                for (uint128 i = (liquidationIndexAtDeposit + 1); i <= params.omniChainData.noOfLiquidations; i++) {
                    uint128 liquidationAmount = params.cdsDepositDetails.liquidationAmount;
                    // If the user available liquidation is non zero
                    if (liquidationAmount > 0) {
                        CDSInterface.LiquidationInfo memory liquidationData = omniChainCDSLiqIndexToInfo[i];
                        // Calculate the share by taking ratio between
                        // User's available liquidation amount and total available liquidation amount
                        uint128 share = (liquidationAmount * 1e10) / uint128(liquidationData.availableLiquidationAmount);
                        // Update users available liquidation amount
                        params.cdsDepositDetails.liquidationAmount -= getUserShare(liquidationData.liquidationAmount, share);
                        // Based on the collateral type calculate the liquidated collateral to give to user
                        if (liquidationData.assetName == IBorrowing.AssetName.ETH) {
                            // increment eth amount
                            params.ethAmount += getUserShare(liquidationData.collateralAmount, share);
                        } else if (liquidationData.assetName == IBorrowing.AssetName.WeETH) {
                            // increment weeth amount and weth amount value
                            weETHAmount += getUserShare(liquidationData.collateralAmount, share);
                            weETHAmountInETHValue += getUserShare(liquidationData.collateralAmountInETHValue, share);
                        } else if (liquidationData.assetName == IBorrowing.AssetName.WrsETH) {
                            // increment rseth amount and rseth amount value
                            rsETHAmount += getUserShare(liquidationData.collateralAmount, share);
                            rsETHAmountInETHValue += getUserShare(liquidationData.collateralAmountInETHValue, share);
                        }
                    }
                }
                uint256 returnAmountWithGains = params.returnAmount + params.cdsDepositDetails.liquidationAmount;
                returnAmountWithGains -= params.cdsDepositDetails.initialLiquidationAmount;
                // Calculate the yields which is accured between liquidation and now
                interfaces.treasury.updateYieldsFromLiquidatedLrts(
                    weETHAmount - ((weETHAmountInETHValue * 1 ether) /  params.weETH_ExchangeRate) + 
                    rsETHAmount - ((rsETHAmountInETHValue * 1 ether) /  params.rsETH_ExchangeRate)
                );
                // Calculate the weeth and rseth amount without yields
                weETHAmount = weETHAmount - (weETHAmount - ((weETHAmountInETHValue * 1 ether) / params.weETH_ExchangeRate));
                rsETHAmount = rsETHAmount - (rsETHAmount - ((rsETHAmountInETHValue * 1 ether) / params.rsETH_ExchangeRate));

                // call getLiquidatedCollateralToGive in cds library to get in which assests to give liquidated collateral
                (
                    totalWithdrawCollateralAmountInETH,
                    params.ethAmount,
                    weETHAmount,
                    rsETHAmount,
                    collateralToGetFromOtherChain
                ) = getLiquidatedCollateralToGive(
                    CDSInterface.GetLiquidatedCollateralToGiveParam(
                        params.ethAmount,
                        weETHAmount,
                        rsETHAmount,
                        interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.ETH),
                        interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.WeETH),
                        interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.WrsETH),
                        interfaces.treasury.totalVolumeOfBorrowersAmountLiquidatedInWei(),
                        params.weETH_ExchangeRate,
                        params.rsETH_ExchangeRate
                    )
                );

                // Update the totalCdsDepositedAmount based on collateral amounts
                if (
                    params.ethAmount == 0 &&
                    weETHAmount == 0 &&
                    rsETHAmount == 0 &&
                    collateralToGetFromOtherChain == 0
                ) {
                    if (
                        totalCdsDepositedAmount >
                        params.cdsDepositDetails.depositedAmount
                    ) {
                        // update totalCdsDepositedAmount
                        totalCdsDepositedAmount -= params.cdsDepositDetails.depositedAmount;
                    } else {
                        totalCdsDepositedAmount = 0;
                    }

                    params.omniChainData.totalCdsDepositedAmount -= params.cdsDepositDetails.depositedAmount;
                    // update totalCdsDepositedAmountWithOptionFees

                    if (
                        totalCdsDepositedAmountWithOptionFees >
                        (params.cdsDepositDetails.depositedAmount + (params.optionFees - params.optionsFeesToGetFromOtherChain))
                    ) {
                        // update totalCdsDepositedAmountWithOptionFees
                        totalCdsDepositedAmountWithOptionFees -= (params.cdsDepositDetails.depositedAmount + (params.optionFees - params.optionsFeesToGetFromOtherChain));
                    } else {
                        totalCdsDepositedAmountWithOptionFees = 0;
                    }
                    params.omniChainData.totalCdsDepositedAmountWithOptionFees -= (params.cdsDepositDetails.depositedAmount + params.optionFees);
                } else {
                    // update totalCdsDepositedAmount
                    totalCdsDepositedAmount -= (params.cdsDepositDetails.depositedAmount - params.cdsDepositDetails.liquidationAmount);
                    params.omniChainData.totalCdsDepositedAmount -= (params.cdsDepositDetails.depositedAmount - params.cdsDepositDetails.liquidationAmount);
                    // update totalCdsDepositedAmountWithOptionFees
                    totalCdsDepositedAmountWithOptionFees -= (params.cdsDepositDetails.depositedAmount - params.cdsDepositDetails.liquidationAmount + params.optionsFeesToGetFromOtherChain);
                    params.omniChainData.totalCdsDepositedAmountWithOptionFees -= (
                        params.cdsDepositDetails.depositedAmount -
                        params.cdsDepositDetails.liquidationAmount +
                        params.optionFees);
                }

                // if any one of the optionsFeesToGetFromOtherChain & ethAmount
                // are positive get it from other chains
                if (
                    params.optionsFeesToGetFromOtherChain > 0 ||
                    collateralToGetFromOtherChain > 0
                ) {
                    uint128 ethAmountFromOtherChain;
                    uint128 weETHAmountFromOtherChain;
                    uint128 rsETHAmountFromOtherChain;
                    // If needs to get the liquidated collateral from other chain
                    if (collateralToGetFromOtherChain != 0) {
                        // again call getLiquidatedCollateralToGive in cds library
                        (
                            ,
                            ethAmountFromOtherChain,
                            weETHAmountFromOtherChain,
                            rsETHAmountFromOtherChain,

                        ) = getLiquidatedCollateralToGive(
                            CDSInterface.GetLiquidatedCollateralToGiveParam(
                                collateralToGetFromOtherChain,
                                0,
                                0,
                                interfaces.globalVariables.getOmniChainCollateralData(IBorrowing.AssetName.ETH).totalLiquidatedAmount -
                                    interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.ETH),
                                interfaces.globalVariables.getOmniChainCollateralData(IBorrowing.AssetName.WeETH).totalLiquidatedAmount -
                                    interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.WeETH),
                                interfaces.globalVariables.getOmniChainCollateralData(IBorrowing.AssetName.WrsETH).totalLiquidatedAmount -
                                    interfaces.treasury.liquidatedCollateralAmountInWei(IBorrowing.AssetName.WrsETH),
                                params.omniChainData.totalVolumeOfBorrowersAmountLiquidatedInWei -
                                    interfaces.treasury.totalVolumeOfBorrowersAmountLiquidatedInWei(),
                                params.weETH_ExchangeRate,
                                params.rsETH_ExchangeRate
                            )
                        );

                        params.ethAmount = ethAmountFromOtherChain +  params.ethAmount;
                        weETHAmount = weETHAmountFromOtherChain + weETHAmount;
                        rsETHAmount = rsETHAmountFromOtherChain + rsETHAmount;
                    }
                    // Get the assets from other chain
                    interfaces.globalVariables.oftOrCollateralReceiveFromOtherChains{
                        value: msg.value - params.fee
                    }(
                        IGlobalVariables.FunctionToDo(
                            // Call getLzFunctionToDo in cds library to get, which action needs to do in dst chain
                            getLzFunctionToDo(params.optionsFeesToGetFromOtherChain, collateralToGetFromOtherChain)
                        ),
                        IGlobalVariables.USDaOftTransferData(address(interfaces.treasury), params.optionsFeesToGetFromOtherChain),
                        IGlobalVariables.CollateralTokenTransferData(
                            address(interfaces.treasury),
                            ethAmountFromOtherChain,
                            weETHAmountFromOtherChain,
                            rsETHAmountFromOtherChain
                        ),
                        IGlobalVariables.CallingFunction.CDS_WITHDRAW,
                        msg.sender
                    );
                    if (rsETHAmountFromOtherChain > 0) {
                        interfaces.treasury.wrapRsETH(rsETHAmountFromOtherChain);
                    }
                }
                //Calculate the usda amount to give to user after deducting 10% from the above final amount
                params.usdaToTransfer = calculateUserProportionInWithdraw(params.cdsDepositDetails.depositedAmount, returnAmountWithGains);
                //Update the treasury data
                interfaces.treasury.updateUsdaCollectedFromCdsWithdraw(returnAmountWithGains - params.usdaToTransfer);
                interfaces.treasury.updateLiquidatedETHCollectedFromCdsWithdraw(params.ethAmount);
                // Update deposit data
                params.cdsDepositDetails.withdrawedAmount = params.usdaToTransfer;
                params.cdsDepositDetails.withdrawCollateralAmount = totalWithdrawCollateralAmountInETH;
                params.cdsDepositDetails.optionFees = params.optionFees;
                params.cdsDepositDetails.optionFeesWithdrawn = params.optionFees;
                // Get approval from treasury
                interfaces.treasury.approveTokens(
                    IBorrowing.AssetName.USDa,
                    address(interfaces.cds),
                    params.usdaToTransfer
                );

                //Call transferFrom in usda
                bool success = interfaces.usda.contractTransferFrom(
                    address(interfaces.treasury),
                    msg.sender,
                    params.usdaToTransfer
                ); // transfer amount to msg.sender
                if (!success)revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.USDa);

                if (params.ethAmount != 0) {
                    params.omniChainData.collateralProfitsOfLiquidators -= totalWithdrawCollateralAmountInETH;
                    // Call transferEthToCdsLiquidators to tranfer eth
                    interfaces.treasury.transferEthToCdsLiquidators(
                        msg.sender,
                        params.ethAmount
                    );
                }
                if (weETHAmount != 0) {
                    interfaces.treasury.approveTokens(IBorrowing.AssetName.WeETH, address(interfaces.cds), weETHAmount);
                    bool sent = IERC20(interfaces.borrowing.assetAddress(IBorrowing.AssetName.WeETH)).transferFrom(
                            address(interfaces.treasury),
                            msg.sender,
                            weETHAmount
                        ); // transfer amount to msg.sender
                    if (!sent) revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.WeETH);
                }
                if (rsETHAmount != 0) {
                    interfaces.treasury.approveTokens(IBorrowing.AssetName.WrsETH, address(interfaces.cds), rsETHAmount);
                    bool sent = IERC20(interfaces.borrowing.assetAddress(IBorrowing.AssetName.WrsETH)).transferFrom(
                            address(interfaces.treasury),
                            msg.sender,
                            rsETHAmount
                        ); // transfer amount to msg.sender
                    if (!sent) revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.WrsETH);
                }
            }

            return CDSInterface.WithdrawResult(
                        params.cdsDepositDetails,
                        params.omniChainData,
                        params.ethAmount,
                        params.usdaToTransfer,
                        params.optionFees,
                        totalCdsDepositedAmount,
                        totalCdsDepositedAmountWithOptionFees
                    );
        }
    }

    function withdrawUserWhoNotOptedForLiq(
        CDSInterface.WithdrawUserParams memory params,
        CDSInterface.Interfaces memory interfaces,
        uint256 totalCdsDepositedAmount,
        uint256 totalCdsDepositedAmountWithOptionFees
    ) public returns (CDSInterface.WithdrawResult memory) {
        // if the optionsFeesToGetFromOtherChain
        // is positive get it from other chains
        if (params.optionsFeesToGetFromOtherChain > 0) {
            interfaces.globalVariables.oftOrCollateralReceiveFromOtherChains{
                value: msg.value - params.fee
            }(
                IGlobalVariables.FunctionToDo(3),
                IGlobalVariables.USDaOftTransferData(address(interfaces.treasury), params.optionsFeesToGetFromOtherChain),
                IGlobalVariables.CollateralTokenTransferData(address(0),0,0,0),
                IGlobalVariables.CallingFunction.CDS_WITHDRAW,
                msg.sender
            );
        }
        totalCdsDepositedAmount -= params.cdsDepositDetails.depositedAmount;
        totalCdsDepositedAmountWithOptionFees -= params.returnAmount - params.optionsFeesToGetFromOtherChain;

        params.omniChainData.totalCdsDepositedAmount -= params.cdsDepositDetails.depositedAmount;
        params.omniChainData.totalCdsDepositedAmountWithOptionFees -= params.returnAmount;

        // Call calculateUserProportionInWithdraw in cds library to get usda to transfer to user
        params.usdaToTransfer = calculateUserProportionInWithdraw(params.cdsDepositDetails.depositedAmount, params.returnAmount);
        // Update user deposit details
        params.cdsDepositDetails.withdrawedAmount = params.usdaToTransfer;
        params.cdsDepositDetails.optionFees = params.optionFees;
        params.cdsDepositDetails.optionFeesWithdrawn = params.optionFees;

        interfaces.treasury.approveTokens(
            IBorrowing.AssetName.USDa,
            address(interfaces.cds),
            params.usdaToTransfer
        );
        bool transfer = interfaces.usda.contractTransferFrom(
            address(interfaces.treasury),
            msg.sender,
            params.usdaToTransfer
        ); // transfer amount to msg.sender
        // Check the transfer is successfull or not
        if (!transfer) revert CDSInterface.CDS_TransferFailed(IBorrowing.AssetName.USDa);

        return CDSInterface.WithdrawResult(
                    params.cdsDepositDetails,
                    params.omniChainData,
                    0,
                    params.usdaToTransfer,
                    params.optionFees,
                    totalCdsDepositedAmount,
                    totalCdsDepositedAmountWithOptionFees
                );
    }
}
