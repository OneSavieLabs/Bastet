// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================== FraxlendPair ============================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author
// Drake Evans: https://github.com/DrakeEvans

// Reviewers
// Dennis: https://github.com/denett
// Sam Kazemian: https://github.com/samkazemian
// Travis Moore: https://github.com/FortisFortuna
// Jack Corddry: https://github.com/corddry
// Rich Gee: https://github.com/zer0blockchain

// ====================================================================

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FraxlendPairConstants} from "./FraxlendPairConstants.sol";
import {FraxlendPairCore} from "./FraxlendPairCore.sol";
import {Timelock2Step} from "./Timelock2Step.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {VaultAccount, VaultAccountingLibrary} from "./libraries/VaultAccount.sol";
import {IRateCalculatorV2} from "./interfaces/IRateCalculatorV2.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/// @title FraxlendPair
/// @author Drake Evans (Frax Finance) https://github.com/drakeevans
/// @notice  The FraxlendPair is a lending pair that allows users to engage in lending and borrowing activities
contract FraxlendPair is IERC20Metadata, FraxlendPairCore {
    using VaultAccountingLibrary for VaultAccount;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @param _configData abi.encode(address _asset, address _collateral, address _oracle, uint32 _maxOracleDeviation, address _rateContract, uint64 _fullUtilizationRate, uint256 _maxLTV, uint256 _cleanLiquidationFee, uint256 _dirtyLiquidationFee, uint256 _protocolLiquidationFee)
    /// @param _immutables abi.encode(address _circuitBreakerAddress, address _comptrollerAddress, address _timelockAddress)
    /// @param _customConfigData abi.encode(string memory _nameOfContract, string memory _symbolOfContract, uint8 _decimalsOfContract)
    constructor(bytes memory _configData, bytes memory _immutables, bytes memory _customConfigData)
        FraxlendPairCore(_configData, _immutables, _customConfigData)
    {}

    // ============================================================================================
    // ERC20 Metadata
    // ============================================================================================

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return nameOfContract;
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return symbolOfContract;
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return decimalsOfContract;
    }

    // totalSupply for fToken ERC20 compatibility
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return totalAsset.shares;
    }

    // ============================================================================================
    // Functions: Helpers
    // ============================================================================================

    function asset() external view returns (address) {
        return address(assetContract);
    }

    function getConstants()
        external
        pure
        returns (
            uint256 _LTV_PRECISION,
            uint256 _LIQ_PRECISION,
            uint256 _UTIL_PREC,
            uint256 _FEE_PRECISION,
            uint256 _EXCHANGE_PRECISION,
            uint256 _DEVIATION_PRECISION,
            uint256 _RATE_PRECISION,
            uint256 _MAX_PROTOCOL_FEE
        )
    {
        _LTV_PRECISION = LTV_PRECISION;
        _LIQ_PRECISION = LIQ_PRECISION;
        _UTIL_PREC = UTIL_PREC;
        _FEE_PRECISION = FEE_PRECISION;
        _EXCHANGE_PRECISION = EXCHANGE_PRECISION;
        _DEVIATION_PRECISION = DEVIATION_PRECISION;
        _RATE_PRECISION = RATE_PRECISION;
        _MAX_PROTOCOL_FEE = MAX_PROTOCOL_FEE;
    }

    /// @notice The ```getUserSnapshot``` function gets user level accounting data
    /// @param _address The user address
    /// @return _userAssetShares The user fToken balance
    /// @return _userBorrowShares The user borrow shares
    /// @return _userCollateralBalance The user collateral balance
    function getUserSnapshot(address _address)
        external
        view
        returns (uint256 _userAssetShares, uint256 _userBorrowShares, uint256 _userCollateralBalance)
    {
        _userAssetShares = balanceOf(_address);
        _userBorrowShares = userBorrowShares[_address];
        _userCollateralBalance = userCollateralBalance[_address];
    }

    /// @notice The ```getPairAccounting``` function gets all pair level accounting numbers
    /// @return _totalAssetAmount Total assets deposited and interest accrued, total claims
    /// @return _totalAssetShares Total fTokens
    /// @return _totalBorrowAmount Total borrows
    /// @return _totalBorrowShares Total borrow shares
    /// @return _totalCollateral Total collateral
    function getPairAccounting()
        external
        view
        returns (
            uint128 _totalAssetAmount,
            uint128 _totalAssetShares,
            uint128 _totalBorrowAmount,
            uint128 _totalBorrowShares,
            uint256 _totalCollateral
        )
    {
        (,,,, VaultAccount memory _totalAsset, VaultAccount memory _totalBorrow) = previewAddInterest();
        _totalAssetAmount = _totalAsset.totalAmount(address(address(0))).toUint128();
        _totalAssetShares = _totalAsset.shares;
        _totalBorrowAmount = _totalBorrow.amount;
        _totalBorrowShares = _totalBorrow.shares;
        _totalCollateral = totalCollateral;
    }

    /// @notice The ```toBorrowShares``` function converts a given amount of borrow debt into the number of shares
    /// @param _amount Amount of borrow
    /// @param _roundUp Whether to roundup during division
    /// @param _previewInterest Whether to simulate interest accrual
    /// @return _shares The number of shares
    function toBorrowShares(uint256 _amount, bool _roundUp, bool _previewInterest)
        external
        view
        returns (uint256 _shares)
    {
        if (_previewInterest) {
            (,,,,, VaultAccount memory _totalBorrow) = previewAddInterest();
            _shares = _totalBorrow.toShares(_amount, _roundUp);
        } else {
            _shares = totalBorrow.toShares(_amount, _roundUp);
        }
    }

    /// @notice The ```toBorrowAmount``` function converts a given amount of borrow debt into the number of shares
    /// @param _shares Shares of borrow
    /// @param _roundUp Whether to roundup during division
    /// @param _previewInterest Whether to simulate interest accrual
    /// @return _amount The amount of asset
    function toBorrowAmount(uint256 _shares, bool _roundUp, bool _previewInterest)
        external
        view
        returns (uint256 _amount)
    {
        if (_previewInterest) {
            (,,,,, VaultAccount memory _totalBorrow) = previewAddInterest();
            _amount = _totalBorrow.toAmount(_shares, _roundUp);
        } else {
            _amount = totalBorrow.toAmount(_shares, _roundUp);
        }
    }

    /// @notice The ```toAssetAmount``` function converts a given number of shares to an asset amount
    /// @param _shares Shares of asset (fToken)
    /// @param _roundUp Whether to round up after division
    /// @param _previewInterest Whether to preview interest accrual before calculation
    /// @return _amount The amount of asset
    function toAssetAmount(uint256 _shares, bool _roundUp, bool _previewInterest)
        public
        view
        returns (uint256 _amount)
    {
        if (_previewInterest) {
            (,,,, VaultAccount memory _totalAsset,) = previewAddInterest();
            _amount = _totalAsset.toAmount(_shares, _roundUp);
        } else {
            _amount = totalAsset.toAmount(_shares, _roundUp);
        }
    }

    /// @notice The ```toAssetShares``` function converts a given asset amount to a number of asset shares (fTokens)
    /// @param _amount The amount of asset
    /// @param _roundUp Whether to round up after division
    /// @param _previewInterest Whether to preview interest accrual before calculation
    /// @return _shares The number of shares (fTokens)
    function toAssetShares(uint256 _amount, bool _roundUp, bool _previewInterest)
        public
        view
        returns (uint256 _shares)
    {
        if (_previewInterest) {
            (,,,, VaultAccount memory _totalAsset,) = previewAddInterest();
            _shares = _totalAsset.toShares(_amount, _roundUp);
        } else {
            _shares = totalAsset.toShares(_amount, _roundUp);
        }
    }

    function convertToAssets(uint256 _shares) external view returns (uint256 _assets) {
        _assets = toAssetAmount(_shares, false, true);
    }

    function convertToShares(uint256 _assets) external view returns (uint256 _shares) {
        _shares = toAssetShares(_assets, false, true);
    }

    function pricePerShare() external view returns (uint256 _amount) {
        _amount = toAssetAmount(1e18, false, true);
    }

    function totalAssets() external view returns (uint256) {
        (,,,, VaultAccount memory _totalAsset,) = previewAddInterest();
        return _totalAsset.totalAmount(address(externalAssetVault));
    }

    function maxDeposit(address) public view returns (uint256 _maxAssets) {
        (,,,, VaultAccount memory _totalAsset,) = previewAddInterest();
        _maxAssets =
            _totalAsset.totalAmount(address(0)) >= depositLimit ? 0 : depositLimit - _totalAsset.totalAmount(address(0));
    }

    function maxMint(address) external view returns (uint256 _maxShares) {
        (,,,, VaultAccount memory _totalAsset,) = previewAddInterest();
        uint256 _maxDeposit =
            _totalAsset.totalAmount(address(0)) >= depositLimit ? 0 : depositLimit - _totalAsset.totalAmount(address(0));
        _maxShares = _totalAsset.toShares(_maxDeposit, false);
    }

    function maxWithdraw(address _owner) external view returns (uint256 _maxAssets) {
        if (isWithdrawPaused) return 0;
        (,, uint256 _feesShare,, VaultAccount memory _totalAsset, VaultAccount memory _totalBorrow) =
            previewAddInterest();
        // Get the owner balance and include the fees share if owner is this contract
        uint256 _ownerBalance = _owner == address(this) ? balanceOf(_owner) + _feesShare : balanceOf(_owner);

        // Return the lower of total assets in contract or total assets available to _owner
        uint256 _totalAssetsAvailable = _totalAssetAvailable(_totalAsset, _totalBorrow, true);
        uint256 _totalUserWithdraw = _totalAsset.toAmount(_ownerBalance, false);
        _maxAssets = _totalAssetsAvailable < _totalUserWithdraw ? _totalAssetsAvailable : _totalUserWithdraw;
    }

    function maxRedeem(address _owner) external view returns (uint256 _maxShares) {
        if (isWithdrawPaused) return 0;
        (,, uint256 _feesShare,, VaultAccount memory _totalAsset, VaultAccount memory _totalBorrow) =
            previewAddInterest();

        // Calculate the total shares available
        uint256 _totalAssetsAvailable = _totalAssetAvailable(_totalAsset, _totalBorrow, true);
        uint256 _totalSharesAvailable = _totalAsset.toShares(_totalAssetsAvailable, false);

        // Get the owner balance and include the fees share if owner is this contract
        uint256 _ownerBalance = _owner == address(this) ? balanceOf(_owner) + _feesShare : balanceOf(_owner);
        _maxShares = _totalSharesAvailable < _ownerBalance ? _totalSharesAvailable : _ownerBalance;
    }

    // ============================================================================================
    // Functions: Configuration
    // ============================================================================================

    bool public isOracleSetterRevoked;

    // /// @notice The ```RevokeOracleSetter``` event is emitted when the oracle setter is revoked
    // event RevokeOracleInfoSetter();

    // /// @notice The ```revokeOracleSetter``` function revokes the oracle setter
    // function revokeOracleInfoSetter() external {
    //     _requireTimelock();
    //     isOracleSetterRevoked = true;
    //     emit RevokeOracleInfoSetter();
    // }

    // /// @notice The ```SetOracleInfo``` event is emitted when the oracle info (address and max deviation) is set
    // /// @param oldOracle The old oracle address
    // /// @param oldMaxOracleDeviation The old max oracle deviation
    // /// @param newOracle The new oracle address
    // /// @param newMaxOracleDeviation The new max oracle deviation
    // event SetOracleInfo(
    //     address oldOracle, uint32 oldMaxOracleDeviation, address newOracle, uint32 newMaxOracleDeviation
    // );

    // /// @notice The ```setOracleInfo``` function sets the oracle data
    // /// @param _newOracle The new oracle address
    // /// @param _newMaxOracleDeviation The new max oracle deviation
    // function setOracle(address _newOracle, uint32 _newMaxOracleDeviation) external {
    //     _requireTimelock();
    //     if (isOracleSetterRevoked) revert SetterRevoked();
    //     ExchangeRateInfo memory _exchangeRateInfo = exchangeRateInfo;
    //     emit SetOracleInfo(
    //         _exchangeRateInfo.oracle, _exchangeRateInfo.maxOracleDeviation, _newOracle, _newMaxOracleDeviation
    //     );
    //     _exchangeRateInfo.oracle = _newOracle;
    //     _exchangeRateInfo.maxOracleDeviation = _newMaxOracleDeviation;
    //     exchangeRateInfo = _exchangeRateInfo;
    // }

    bool public isMaxLTVSetterRevoked;

    // /// @notice The ```RevokeMaxLTVSetter``` event is emitted when the max LTV setter is revoked
    // event RevokeMaxLTVSetter();

    // /// @notice The ```revokeMaxLTVSetter``` function revokes the max LTV setter
    // function revokeMaxLTVSetter() external {
    //     _requireTimelock();
    //     isMaxLTVSetterRevoked = true;
    //     emit RevokeMaxLTVSetter();
    // }

    /// @notice The ```SetMaxLTV``` event is emitted when the max LTV is set
    /// @param oldMaxLTV The old max LTV
    /// @param newMaxLTV The new max LTV
    event SetMaxLTV(uint256 oldMaxLTV, uint256 newMaxLTV);

    /// @notice The ```setMaxLTV``` function sets the max LTV
    /// @param _newMaxLTV The new max LTV
    function setMaxLTV(uint256 _newMaxLTV) external {
        _requireTimelock();
        if (isMaxLTVSetterRevoked) revert SetterRevoked();
        emit SetMaxLTV(maxLTV, _newMaxLTV);
        maxLTV = _newMaxLTV;
    }

    bool public isRateContractSetterRevoked;

    /// @notice The ```RevokeRateContractSetter``` event is emitted when the rate contract setter is revoked
    event RevokeRateContractSetter();

    /// @notice The ```revokeRateContractSetter``` function revokes the rate contract setter
    function revokeRateContractSetter() external {
        _requireTimelock();
        isRateContractSetterRevoked = true;
        emit RevokeRateContractSetter();
    }

    /// @notice The ```SetRateContract``` event is emitted when the rate contract is set
    /// @param oldRateContract The old rate contract
    /// @param newRateContract The new rate contract
    event SetRateContract(address oldRateContract, address newRateContract);

    /// @notice The ```setRateContract``` function sets the rate contract address
    /// @param _newRateContract The new rate contract address
    function setRateContract(address _newRateContract) external {
        _requireTimelock();
        if (isRateContractSetterRevoked) revert SetterRevoked();
        emit SetRateContract(address(rateContract), _newRateContract);
        rateContract = IRateCalculatorV2(_newRateContract);
    }

    bool public isLiquidationFeeSetterRevoked;

    // /// @notice The ```RevokeLiquidationFeeSetter``` event is emitted when the liquidation fee setter is revoked
    // event RevokeLiquidationFeeSetter();

    // /// @notice The ```revokeLiquidationFeeSetter``` function revokes the liquidation fee setter
    // function revokeLiquidationFeeSetter() external {
    //     _requireTimelock();
    //     isLiquidationFeeSetterRevoked = true;
    //     emit RevokeLiquidationFeeSetter();
    // }

    // /// @notice The ```SetLiquidationFees``` event is emitted when the liquidation fees are set
    // /// @param oldCleanLiquidationFee The old clean liquidation fee
    // /// @param oldDirtyLiquidationFee The old dirty liquidation fee
    // /// @param oldProtocolLiquidationFee The old protocol liquidation fee
    // /// @param newCleanLiquidationFee The new clean liquidation fee
    // /// @param newDirtyLiquidationFee The new dirty liquidation fee
    // /// @param newProtocolLiquidationFee The new protocol liquidation fee
    // event SetLiquidationFees(
    //     uint256 oldCleanLiquidationFee,
    //     uint256 oldDirtyLiquidationFee,
    //     uint256 oldProtocolLiquidationFee,
    //     uint256 newCleanLiquidationFee,
    //     uint256 newDirtyLiquidationFee,
    //     uint256 newProtocolLiquidationFee
    // );

    // /// @notice The ```setLiquidationFees``` function sets the liquidation fees
    // /// @param _newCleanLiquidationFee The new clean liquidation fee
    // /// @param _newDirtyLiquidationFee The new dirty liquidation fee
    // /// @param _newProtocolLiquidationFee The new protocol liquidation fee
    // /// @param _newMinCollateralRequiredOnDirtyLiquidation The new min collateral required to leave on dirty liquidation
    // function setLiquidationFees(
    //     uint256 _newCleanLiquidationFee,
    //     uint256 _newDirtyLiquidationFee,
    //     uint256 _newProtocolLiquidationFee,
    //     uint256 _newMinCollateralRequiredOnDirtyLiquidation
    // ) external {
    //     _requireTimelock();
    //     if (isLiquidationFeeSetterRevoked) revert SetterRevoked();
    //     emit SetLiquidationFees(
    //         cleanLiquidationFee,
    //         dirtyLiquidationFee,
    //         protocolLiquidationFee,
    //         _newCleanLiquidationFee,
    //         _newDirtyLiquidationFee,
    //         _newProtocolLiquidationFee
    //     );
    //     cleanLiquidationFee = _newCleanLiquidationFee;
    //     dirtyLiquidationFee = _newDirtyLiquidationFee;
    //     protocolLiquidationFee = _newProtocolLiquidationFee;
    //     minCollateralRequiredOnDirtyLiquidation = _newMinCollateralRequiredOnDirtyLiquidation;
    // }

    /// @notice The ```ChangeFee``` event first when the fee is changed
    /// @param newFee The new fee
    event ChangeFee(uint32 newFee);

    /// @notice The ```changeFee``` function changes the protocol fee, max 50%
    /// @param _newFee The new fee
    function changeFee(uint32 _newFee) external {
        _requireTimelock();
        if (isInterestPaused) revert InterestPaused();
        if (_newFee > MAX_PROTOCOL_FEE) {
            revert BadProtocolFee();
        }
        _addInterest();
        currentRateInfo.feeToProtocolRate = _newFee;
        emit ChangeFee(_newFee);
    }

    /// @notice The ```WithdrawFees``` event fires when the fees are withdrawn
    /// @param shares Number of shares (fTokens) redeemed
    /// @param recipient To whom the assets were sent
    /// @param amountToTransfer The amount of fees redeemed
    event WithdrawFees(uint128 shares, address recipient, uint256 amountToTransfer, uint256 collateralAmount);

    /// @notice The ```withdrawFees``` function withdraws fees accumulated
    /// @param _shares Number of fTokens to redeem
    /// @param _recipient Address to send the assets
    /// @return _amountToTransfer Amount of assets sent to recipient
    function withdrawFees(uint128 _shares, address _recipient) external onlyOwner returns (uint256 _amountToTransfer) {
        if (_recipient == address(0)) revert InvalidReceiver();

        // Grab some data from state to save gas
        VaultAccount memory _totalAsset = totalAsset;

        // Take all available if 0 value passed
        if (_shares == 0) _shares = balanceOf(address(this)).toUint128();

        // We must calculate this before we subtract from _totalAsset or invoke _burn
        _amountToTransfer = _totalAsset.toAmount(_shares, true);

        _approve(address(this), msg.sender, _shares);
        _redeem(_totalAsset, _amountToTransfer.toUint128(), _shares, _recipient, address(this), false);
        uint256 _collateralAmount = userCollateralBalance[address(this)];
        _removeCollateral(_collateralAmount, _recipient, address(this));
        emit WithdrawFees(_shares, _recipient, _amountToTransfer, _collateralAmount);
    }

    /// @notice The ```SetSwapper``` event fires whenever a swapper is black or whitelisted
    /// @param swapper The swapper address
    /// @param approval The approval
    event SetSwapper(address swapper, bool approval);

    /// @notice The ```setSwapper``` function is called to black or whitelist a given swapper address
    /// @dev
    /// @param _swapper The swapper address
    /// @param _approval The approval
    function setSwapper(address _swapper, bool _approval) external onlyOwner {
        swappers[_swapper] = _approval;
        emit SetSwapper(_swapper, _approval);
    }

    // ============================================================================================
    // Functions: Access Control
    // ============================================================================================

    /// @notice The ```pause``` function is called to pause all contract functionality
    function pause() external {
        _requireProtocolOrOwner();
        if (!isBorrowAccessControlRevoked) _setBorrowLimit(0);
        if (!isDepositAccessControlRevoked) _setDepositLimit(0);
        if (!isRepayAccessControlRevoked) _pauseRepay(true);
        if (!isWithdrawAccessControlRevoked) _pauseWithdraw(true);
        if (!isLiquidateAccessControlRevoked) _pauseLiquidate(true);
        if (!isInterestAccessControlRevoked) {
            _addInterest();
            _pauseInterest(true);
        }
    }

    /// @notice The ```unpause``` function is called to unpause all contract functionality
    function unpause() external {
        _requireTimelockOrOwner();
        if (!isBorrowAccessControlRevoked) _setBorrowLimit(type(uint256).max);
        if (!isDepositAccessControlRevoked) _setDepositLimit(type(uint256).max);
        if (!isRepayAccessControlRevoked) _pauseRepay(false);
        if (!isWithdrawAccessControlRevoked) _pauseWithdraw(false);
        if (!isLiquidateAccessControlRevoked) _pauseLiquidate(false);
        if (!isInterestAccessControlRevoked) {
            _addInterest();
            _pauseInterest(false);
            currentRateInfo.lastTimestamp = uint64(block.timestamp);
        }
    }

    event UpdatedMinURChange(uint256 newURChange);

    /// @notice The ```setMinURChangeForExternalAddInterest``` function sets the new minimum UR change for external add interest
    /// @param _newURChange The new rate change needed
    function setMinURChangeForExternalAddInterest(uint256 _newURChange) external {
        _requireTimelockOrOwner();
        if (_newURChange > UTIL_PREC) revert MinURChangeMax();
        minURChangeForExternalAddInterest = _newURChange;
        emit UpdatedMinURChange(_newURChange);
    }

    // /// @notice The ```pauseBorrow``` function sets borrow limit to 0
    // function pauseBorrow() external {
    //     _requireProtocolOrOwner();
    //     if (isBorrowAccessControlRevoked) revert AccessControlRevoked();
    //     _setBorrowLimit(0);
    // }

    // /// @notice The ```setBorrowLimit``` function sets the borrow limit
    // /// @param _limit The new borrow limit
    // function setBorrowLimit(uint256 _limit) external {
    //     _requireTimelockOrOwner();
    //     if (isBorrowAccessControlRevoked) revert AccessControlRevoked();
    //     _setBorrowLimit(_limit);
    // }

    // /// @notice The ```revokeBorrowLimitAccessControl``` function revokes borrow limit access control
    // /// @param _borrowLimit The new borrow limit
    // function revokeBorrowLimitAccessControl(uint256 _borrowLimit) external {
    //     _requireTimelock();
    //     _revokeBorrowAccessControl(_borrowLimit);
    // }

    // /// @notice The ```pauseDeposit``` function pauses deposit functionality
    // function pauseDeposit() external {
    //     _requireProtocolOrOwner();
    //     if (isDepositAccessControlRevoked) revert AccessControlRevoked();
    //     _setDepositLimit(0);
    // }

    // /// @notice The ```setDepositLimit``` function sets the deposit limit
    // /// @param _limit The new deposit limit
    // function setDepositLimit(uint256 _limit) external {
    //     _requireTimelockOrOwner();
    //     if (isDepositAccessControlRevoked) revert AccessControlRevoked();
    //     _setDepositLimit(_limit);
    // }

    // /// @notice The ```revokeDepositLimitAccessControl``` function revokes deposit limit access control
    // /// @param _depositLimit The new deposit limit
    // function revokeDepositLimitAccessControl(uint256 _depositLimit) external {
    //     _requireTimelock();
    //     _revokeDepositAccessControl(_depositLimit);
    // }

    // /// @notice The ```pauseRepay``` function pauses repay functionality
    // /// @param _isPaused The new pause state
    // function pauseRepay(bool _isPaused) external {
    //     if (_isPaused) {
    //         _requireProtocolOrOwner();
    //     } else {
    //         _requireTimelockOrOwner();
    //     }
    //     if (isRepayAccessControlRevoked) revert AccessControlRevoked();
    //     _pauseRepay(_isPaused);
    // }

    // /// @notice The ```revokeRepayAccessControl``` function revokes repay access control
    // function revokeRepayAccessControl() external {
    //     _requireTimelock();
    //     _revokeRepayAccessControl();
    // }

    // /// @notice The ```pauseWithdraw``` function pauses withdraw functionality
    // /// @param _isPaused The new pause state
    // function pauseWithdraw(bool _isPaused) external {
    //     if (_isPaused) {
    //         _requireProtocolOrOwner();
    //     } else {
    //         _requireTimelockOrOwner();
    //     }
    //     if (isWithdrawAccessControlRevoked) revert AccessControlRevoked();
    //     _pauseWithdraw(_isPaused);
    // }

    // /// @notice The ```revokeWithdrawAccessControl``` function revokes withdraw access control
    // function revokeWithdrawAccessControl() external {
    //     _requireTimelock();
    //     _revokeWithdrawAccessControl();
    // }

    // /// @notice The ```pauseLiquidate``` function pauses liquidate functionality
    // /// @param _isPaused The new pause state
    // function pauseLiquidate(bool _isPaused) external {
    //     if (_isPaused) {
    //         _requireProtocolOrOwner();
    //     } else {
    //         _requireTimelockOrOwner();
    //     }
    //     if (isLiquidateAccessControlRevoked) revert AccessControlRevoked();
    //     _pauseLiquidate(_isPaused);
    // }

    // /// @notice The ```revokeLiquidateAccessControl``` function revokes liquidate access control
    // function revokeLiquidateAccessControl() external {
    //     _requireTimelock();
    //     _revokeLiquidateAccessControl();
    // }

    // /// @notice The ```pauseInterest``` function pauses interest functionality
    // /// @param _isPaused The new pause state
    // function pauseInterest(bool _isPaused) external {
    //     if (_isPaused) {
    //         _requireProtocolOrOwner();
    //     } else {
    //         currentRateInfo.lastTimestamp = uint64(block.timestamp);
    //         _requireTimelockOrOwner();
    //     }
    //     if (isInterestAccessControlRevoked) revert AccessControlRevoked();
    //     // Resets the lastTimestamp which has the effect of no interest accruing over the pause period
    //     _addInterest();
    //     _pauseInterest(_isPaused);
    // }

    // /// @notice The ```revokeInterestAccessControl``` function revokes interest access control
    // function revokeInterestAccessControl() external {
    //     _requireTimelock();
    //     _revokeInterestAccessControl();
    // }
}