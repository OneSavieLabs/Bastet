// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../interface/ITreasury.sol";
import "../interface/IBorrowing.sol";
import "../interface/CDSInterface.sol";
import "../interface/IUSDa.sol";
import "../interface/IBorrowLiquidation.sol";
import "../interface/IGlobalVariables.sol";
import "../interface/Synthetix/IPerpsV2MarketConsolidated.sol";
import "../interface/IWETH9.sol";
import {BorrowLib} from "../lib/BorrowLib.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

interface IWrapper {
    function mint(uint amount) external;
}

interface ISynthetix {
    function exchange(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    ) external returns (uint amountReceived);
}

/**
 * @title BorrowLiquidation contract
 * @author Autonomint
 * @notice Main contract for liquidation
 * @dev In this contract, the positions are Liquidated.
 * @dev Liquidation is happening in 3 different types based on total CDS value
 * @dev All functions are callable by the borrowing contract only
 */
contract BorrowLiquidation is
    IBorrowLiquidation,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    IBorrowing borrowing; // Borrowing contract instance
    ITreasury treasury; // Treasury contract instance
    CDSInterface cds; // CDS contract instance
    IUSDa usda; // USDa instance
    IGlobalVariables private globalVariables; // GlobalVariable(OApp) contract instance
    address public admin; // Admin address
    using OptionsBuilder for bytes; // Options builder library for layer zero transactions
    IWETH9 weth; // WETH instance
    IPerpsV2MarketConsolidated synthetixPerpsV2; // Synthetix perps v2 instance
    IWrapper wrapper; // Wrapper instance to mint sETH
    ISynthetix synthetix; // Synthetix instance for exchange between sETH and sUSD

    /**
     * @dev Initialize function to initialize the contract with
     * initializer modifier
     * @param borrowingAddress borrowing contract addresss
     * @param cdsAddress cds address
     * @param usdaAddress usda address
     * @param globalVariablesAddress global variables address
     * @param wethAddress WETH token address
     * @param wrapperAddress wrapper contract address
     * @param synthetixPerpsV2Address perps v2 address
     */

    function initialize(
        address borrowingAddress,
        address cdsAddress,
        address usdaAddress,
        address globalVariablesAddress,
        address wethAddress,
        address wrapperAddress,
        address synthetixPerpsV2Address,
        address synthetixAddress
    ) public initializer {
        // Initialize owner
        __Ownable_init(msg.sender);
        //Initialize proxy contracts
        __UUPSUpgradeable_init();
        borrowing = IBorrowing(borrowingAddress);
        cds = CDSInterface(cdsAddress);
        usda = IUSDa(usdaAddress);
        globalVariables = IGlobalVariables(globalVariablesAddress);
        weth = IWETH9(wethAddress);
        synthetixPerpsV2 = IPerpsV2MarketConsolidated(synthetixPerpsV2Address);
        wrapper = IWrapper(wrapperAddress);
        synthetix = ISynthetix(synthetixAddress);
    }

    function _authorizeUpgrade(
        address implementation
    ) internal override onlyOwner {}

    /**
     * Modifier with allow only borrowing contract can call the functions
     */
    modifier onlyBorrowingContract() {
        require(msg.sender == address(borrowing),"This function can only called by borrowing contract");
        _;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param addr address to check whether the address is an contract address or EOA
     */
    function isContract(address addr) internal view returns (bool) {
        uint size;
        // If the address exist in the chain, then it will return the size which is non zero
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @dev sets the treasury contract instance, can only be called by owner
     * @param treasuryAddress Treasury contract address
     */

    function setTreasury(address treasuryAddress) external onlyOwner {
        // Check whether the input address is not a zero address and EOA
        require(treasuryAddress != address(0) && isContract(treasuryAddress),"Treasury must be contract address & can't be zero address");
        treasury = ITreasury(treasuryAddress);
    }

    /**
     * @dev Function to set admin address, can only be called by owner
     * @param adminAddress Address of the admin.
     */

    function setAdmin(address adminAddress) external onlyOwner {
        // Check whether the input address is not a zero address and EOA
        require(adminAddress != address(0) && !isContract(adminAddress),"Admin can't be zero address and contract address");
        admin = adminAddress;
    }

    /**
     * @dev This function liquidate ETH which are below downside protection, can only be called borrowing contract
     * @param user The address to whom to liquidate ETH.
     * @param index Index of the borrow
     * @param currentEthPrice Current ETH price
     * @param liquidationType what type of liquidation needs to be done
     * @param lastCumulativeRate Cumulative rate which is stored previously.
     */

    function liquidateBorrowPosition(
        address user,
        uint64 index,
        uint64 currentEthPrice,
        IBorrowing.LiquidationType liquidationType,
        uint256 lastCumulativeRate
    ) external payable onlyBorrowingContract returns (CDSInterface.LiquidationInfo memory liquidationInfo) {
        //? Based on liquidationType do the liquidation
        // Type 1: Liquidation through CDS
        if (liquidationType == IBorrowing.LiquidationType.ONE) {
            return liquidationType1(user, index, currentEthPrice, lastCumulativeRate);
            // Type 2: Liquidation by taking short position in synthetix with 1x leverage
        } else if (liquidationType == IBorrowing.LiquidationType.TWO) {
            liquidationType2(user, index, currentEthPrice);
        }
    }

    /**
     * @dev Liquidate the position by using CDS
     * @param user Borrower's address
     * @param index Liquidating index
     * @param currentEthPrice current ETH price
     * @param lastCumulativeRate last cumulative rate
     */
    function liquidationType1(
        address user,
        uint64 index,
        uint64 currentEthPrice,
        uint256 lastCumulativeRate
    ) internal returns (CDSInterface.LiquidationInfo memory liquidationInfo) {
        // Get the borrower and deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(user, index);
        ITreasury.DepositDetails memory depositDetail = getBorrowingResult.depositDetails;
        // Check whether the position is already liquidated or not
        require(!depositDetail.liquidated, "Already Liquidated");

        // Get the exchange rate and ETH price
        (uint128 exchangeRate /*uint128 ethPrice*/, ) = borrowing.getUSDValue(borrowing.assetAddress(depositDetail.assetName));

        // Check whether the position is eligible for liquidation
        uint128 ratio = BorrowLib.calculateEthPriceRatio(depositDetail.ethPriceAtDeposit, currentEthPrice);
        require(ratio <= 8000,"You cannot liquidate, ratio is greater than 0.8");

        // Get global omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Get the specific collateral global data
        IGlobalVariables.CollateralData memory collateralData = globalVariables.getOmniChainCollateralData(depositDetail.assetName);

        // Increment global number of liquidations
        ++omniChainData.noOfLiquidations;

        //Update the position to liquidated
        depositDetail.liquidated = true;

        // Calculate borrower's debt
        uint256 borrowerDebt = ((depositDetail.normalizedAmount * lastCumulativeRate) / BorrowLib.RATE_PRECISION);
        uint128 returnToTreasury = uint128(borrowerDebt);

        // 20% to abond usda pool
        uint128 returnToAbond = BorrowLib.calculateReturnToAbond(depositDetail.depositedAmountInETH, depositDetail.ethPriceAtDeposit, returnToTreasury);
        treasury.updateAbondUSDaPool(returnToAbond, true);
        // Calculate the CDS profits
        uint128 cdsProfits = (((depositDetail.depositedAmountInETH * depositDetail.ethPriceAtDeposit) / BorrowLib.USDA_PRECISION) / 100) - returnToTreasury - returnToAbond;
        // Liquidation amount in usda needed for liquidation
        uint128 liquidationAmountNeeded = returnToTreasury + returnToAbond;
        // Check whether the cds have enough usda for liquidation
        require(omniChainData.totalAvailableLiquidationAmount >= liquidationAmountNeeded, "Don't have enough USDa in CDS to liquidate");

        // Store the liquidation info in cds
        liquidationInfo = CDSInterface.LiquidationInfo(
            liquidationAmountNeeded,
            cdsProfits,
            depositDetail.depositedAmount,
            omniChainData.totalAvailableLiquidationAmount,
            depositDetail.assetName,
            ((depositDetail.depositedAmount * exchangeRate) / 1 ether)
        );
        // calculate the amount of usda to get from Other chains
        uint256 liqAmountToGetFromOtherChain = BorrowLib.getLiquidationAmountProportions(
                liquidationAmountNeeded,
                cds.getTotalCdsDepositedAmount(),
                omniChainData.totalCdsDepositedAmount - omniChainData.downsideProtected,
                cds.totalAvailableLiquidationAmount(),
                omniChainData.totalAvailableLiquidationAmount
            );
        // Calculate CDS profits to give to the users of other chains.
        uint128 cdsProfitsForOtherChain = BorrowLib.getCdsProfitsProportions(liquidationAmountNeeded, uint128(liqAmountToGetFromOtherChain), cdsProfits);
        // USDa from cds to get from this chain.
        uint128 cdsAmountToGetFromThisChain = (liquidationAmountNeeded - uint128(liqAmountToGetFromOtherChain)) - (cdsProfits - cdsProfitsForOtherChain);

        // Update the CDS data
        cds.updateLiquidationInfo(omniChainData.noOfLiquidations, liquidationInfo);
        cds.updateTotalCdsDepositedAmount(cdsAmountToGetFromThisChain);
        cds.updateTotalCdsDepositedAmountWithOptionFees(cdsAmountToGetFromThisChain);
        cds.updateTotalAvailableLiquidationAmount(cdsAmountToGetFromThisChain);
        omniChainData.collateralProfitsOfLiquidators += depositDetail.depositedAmountInETH;

        // Update the global data
        omniChainData.totalCdsDepositedAmount -= liquidationAmountNeeded - cdsProfits; //! need to revisit this
        omniChainData.totalCdsDepositedAmountWithOptionFees -= liquidationAmountNeeded - cdsProfits;
        omniChainData.totalAvailableLiquidationAmount -= liquidationAmountNeeded - cdsProfits;
        omniChainData.totalInterestFromLiquidation += uint256(borrowerDebt - depositDetail.borrowedAmount);
        omniChainData.totalVolumeOfBorrowersAmountinWei -= depositDetail.depositedAmountInETH;
        omniChainData.totalVolumeOfBorrowersAmountinUSD -= depositDetail.depositedAmountUsdValue;
        omniChainData.totalVolumeOfBorrowersAmountLiquidatedInWei += depositDetail.depositedAmountInETH;

        // Update totalInterestFromLiquidation
        uint256 totalInterestFromLiquidation = uint256(borrowerDebt - depositDetail.borrowedAmount);

        // Update individual collateral data
        --collateralData.noOfIndices;
        collateralData.totalDepositedAmount -= depositDetail.depositedAmount;
        collateralData.totalDepositedAmountInETH -= depositDetail.depositedAmountInETH;
        collateralData.totalLiquidatedAmount += depositDetail.depositedAmount;
        // Calculate the yields
        uint256 yields = depositDetail.depositedAmount - ((depositDetail.depositedAmountInETH * 1 ether) / exchangeRate);

        // Update treasury data
        treasury.updateTotalVolumeOfBorrowersAmountinWei(depositDetail.depositedAmountInETH);
        treasury.updateTotalVolumeOfBorrowersAmountinUSD(depositDetail.depositedAmountUsdValue);
        treasury.updateDepositedCollateralAmountInWei(depositDetail.assetName, depositDetail.depositedAmountInETH);
        treasury.updateDepositedCollateralAmountInUsd(depositDetail.assetName, depositDetail.depositedAmountUsdValue);
        treasury.updateTotalInterestFromLiquidation(totalInterestFromLiquidation);
        treasury.updateYieldsFromLiquidatedLrts(yields);
        treasury.updateDepositDetails(user, index, depositDetail);

        globalVariables.updateCollateralData(depositDetail.assetName, collateralData);
        globalVariables.setOmniChainData(omniChainData);

        // If the liquidation amount to get from other is greater than zero,
        // Get the amount from other chain.
        if (liqAmountToGetFromOtherChain > 0) {
            // Call the oftOrCollateralReceiveFromOtherChains function in global variables
            globalVariables.oftOrCollateralReceiveFromOtherChains{value: msg.value}(
                IGlobalVariables.FunctionToDo(3),
                IGlobalVariables.USDaOftTransferData(address(treasury),liqAmountToGetFromOtherChain),
                // Since we don't need ETH, we have passed zero params
                IGlobalVariables.CollateralTokenTransferData(address(0),0,0,0),
                IGlobalVariables.CallingFunction.BORROW_LIQ,
                admin
            );
        }

        // If the collateral is ETH, withdraw the deposited ETH in external protocol
        if (depositDetail.assetName == IBorrowing.AssetName.ETH) {
            treasury.updateInterestFromExternalProtocol(treasury.withdrawFromExternalProtocolDuringLiq(user, index));
        }

        // Burn the borrow amount
        treasury.approveTokens(IBorrowing.AssetName.USDa, address(this), depositDetail.borrowedAmount);
        bool success = usda.contractBurnFrom(address(treasury), depositDetail.borrowedAmount);
        if (!success) revert BorrowLiquidation_LiquidateBurnFailed();
        if (liqAmountToGetFromOtherChain == 0) {
            (bool sent, ) = payable(user).call{value: msg.value}("");
            require(sent, "Failed to send Ether");
        }
        // Transfer ETH to CDS Pool
        emit Liquidate(
            index,
            liquidationAmountNeeded,
            cdsProfits,
            depositDetail.depositedAmountInETH,
            cds.totalAvailableLiquidationAmount()
        );
        return liquidationInfo;
    }

    /**
     * @dev Liquidate the position by taking short position in Synthetix
     * @param user Borrower's address
     * @param index Liquidating index
     * @param currentEthPrice current ETH price
     */

    function liquidationType2(
        address user,
        uint64 index,
        uint64 currentEthPrice
    ) internal {
        // Get the borrower and deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(user, index);
        ITreasury.DepositDetails memory depositDetail = getBorrowingResult.depositDetails;
        require(!depositDetail.liquidated, "Already Liquidated");

        // Check whether the position is eligible for liquidation
        uint128 ratio = BorrowLib.calculateEthPriceRatio(depositDetail.ethPriceAtDeposit, currentEthPrice);
        require(ratio <= 8000, "You cannot liquidate, ratio is greater than 0.8");

        uint256 amount = BorrowLib.calculateHalfValue(depositDetail.depositedAmountInETH);

        // Convert the ETH into WETH
        weth.deposit{value: amount}();
        // Approve it, to mint sETH
        bool approved = weth.approve(address(wrapper), amount);

        if (!approved) revert BorrowLiq_ApproveFailed();

        // Mint sETH
        wrapper.mint(amount);
        // Exchange sETH with sUSD
        synthetix.exchange(
            0x7345544800000000000000000000000000000000000000000000000000000000,
            amount,
            0x7355534400000000000000000000000000000000000000000000000000000000
        );

        // Calculate the margin
        int256 margin = int256((amount * currentEthPrice) / 100);
        // Transfer the margin to synthetix
        synthetixPerpsV2.transferMargin(margin);

        // Submit an offchain delayed order in synthetix for short position with 1X leverage
        synthetixPerpsV2.submitOffchainDelayedOrder(
            -int((uint(margin * 1 ether * 1e16) / currentEthPrice)),
            currentEthPrice * 1e16
        );
    }

    /**
     * @dev Submit the order in Synthetix for closing position, can only be called by Borrowing contract
     */
    function closeThePositionInSynthetix() external onlyBorrowingContract {
        (, uint128 ethPrice) = borrowing.getUSDValue(borrowing.assetAddress(IBorrowing.AssetName.ETH));
        // Submit an order to close all positions in synthetix
        synthetixPerpsV2.submitOffchainDelayedOrder(-synthetixPerpsV2.positions(address(this)).size, ethPrice * 1e16);
    }

    /**
     * @dev Execute the submitted order in Synthetix
     * @param priceUpdateData Bytes[] data to update price
     */
    function executeOrdersInSynthetix(
        bytes[] calldata priceUpdateData
    ) external onlyBorrowingContract {
        // Execute the submitted order
        synthetixPerpsV2.executeOffchainDelayedOrder{value: 1}(address(this), priceUpdateData);
    }
}
