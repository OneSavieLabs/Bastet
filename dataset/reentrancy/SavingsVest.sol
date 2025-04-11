// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.19;

import { ITransmuter } from "interfaces/ITransmuter.sol";

import "./BaseSavings.sol";

/// @title SavingsVest
/// @author Angle Labs, Inc.
/// @notice In this implementation, yield is distributed to stablecoin holders whenever the Transmuter starts to
/// get over-collateralized
/// @dev This implementation is typically applicable to an ETH stablecoin backed by liquid staking tokens and
/// where the yield of the LST is distributed to stablecoin holders
contract SavingsVest is BaseSavings {
    using SafeERC20 for IERC20;
    using MathUpgradeable for uint256;

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                PARAMETERS / REFERENCES                                             
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Address handling protocol surplus
    address public surplusManager;

    /// @notice Amount of profit that needs to be vested
    uint256 public vestingProfit;

    /// @notice Reference to the Transmuter contract
    ITransmuter public transmuter;

    /// @notice Last time rewards were accrued
    uint64 public lastUpdate;

    /// @notice Share of the surplus going to the protocol
    uint64 public protocolSafetyFee;

    /// @notice The period in seconds over which locked profit is unlocked
    /// @dev Cannot be 0 as it opens the system to sandwich attacks
    uint32 public vestingPeriod;

    /// @notice Minimum time between two calls to the `accrue` function
    uint32 public updateDelay;

    /// @notice Whether the contract is paused or not
    uint8 public paused;

    uint256[46] private __gap;

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                        EVENTS                                                      
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    event FiledUint64(uint64 param, bytes32 what);

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                    INITIALIZATION                                                  
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice Initializes the contract
    /// @param _accessControlManager Reference to the `AccessControlManager` contract
    /// @param name_ Name of the savings contract
    /// @param symbol_ Symbol of the savings contract
    /// @param divizer Quantifies the first initial deposit (should be typically 1 for tokens like agEUR)
    /// @dev A first deposit is done at initialization to protect for the classical issue of ERC4626 contracts
    /// where the the first user of the contract tries to steal everyone else's tokens
    function initialize(
        IAccessControlManager _accessControlManager,
        IERC20MetadataUpgradeable asset_,
        ITransmuter _transmuter,
        string memory name_,
        string memory symbol_,
        uint256 divizer
    ) public initializer {
        if (address(_accessControlManager) == address(0) || address(_transmuter) == address(0)) revert ZeroAddress();
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        transmuter = _transmuter;
        accessControlManager = _accessControlManager;
        uint8 numDecimals = asset_.decimals();
        _deposit(msg.sender, address(this), 10 ** numDecimals / divizer, BASE_18 / divizer);
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                       MODIFIER                                                     
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC20Upgradeable
    function _beforeTokenTransfer(address from, address to, uint256) internal virtual override {
        // Lets transfer freely even when paused but no mint or burn
        if ((from == address(0) || to == address(0)) && paused > 0) revert Paused();
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                    CONTRACT LOGIC                                                  
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Accrues interest to this contract by minting agTokens if the protocol is over-collateralized
    /// or burning some if it is not collateralized
    function accrue() external returns (uint256 minted) {
        if (block.timestamp - lastUpdate < updateDelay && !accessControlManager.isGovernorOrGuardian(msg.sender))
            revert NotAllowed();
        ITransmuter _transmuter = transmuter;
        IAgToken _agToken = IAgToken(asset());
        (uint64 collatRatio, uint256 stablecoinsIssued) = _transmuter.getCollateralRatio();
        // It needs to deviate significantly (>0.1%) from the target in order to accrue
        if (collatRatio > BASE_9 + BASE_6) {
            // The surplus of profit minus a fee is distributed through this contract
            minted = (collatRatio * stablecoinsIssued) / BASE_9 - stablecoinsIssued;
            // Updating normalizer in order not to double count profits
            _transmuter.updateNormalizer(minted, true);
            uint256 surplusForProtocol = (minted * protocolSafetyFee) / BASE_9;
            address _surplusManager = surplusManager;
            _surplusManager = _surplusManager == address(0) ? address(_transmuter) : _surplusManager;
            _agToken.mint(_surplusManager, surplusForProtocol);
            uint256 surplus = minted - surplusForProtocol;
            if (surplus != 0) {
                // Adding new profits relaunches to zero the vesting period for the profits that were
                // previously being vested
                vestingProfit = (lockedProfit() + surplus);
                lastUpdate = uint64(block.timestamp);
                _agToken.mint(address(this), surplus);
            }
        } else if (collatRatio < BASE_9 - BASE_6) {
            // If the protocol is under-collateralized, slashing the profits that are still being vested
            uint256 missing = stablecoinsIssued - (collatRatio * stablecoinsIssued) / BASE_9;
            uint256 currentLockedProfit = lockedProfit();
            if (missing > currentLockedProfit) {
                vestingProfit = 0;
                missing = currentLockedProfit;
            } else {
                vestingProfit = currentLockedProfit - missing;
                lastUpdate = uint64(block.timestamp);
            }
            if (missing > 0) {
                _agToken.burnSelf(missing, address(this));
                _transmuter.updateNormalizer(missing, false);
            }
        }
    }

    /// @notice Amount of profit that are still vesting
    function lockedProfit() public view virtual returns (uint256) {
        // Get the last update and vesting delay.
        uint256 _lastUpdate = lastUpdate;
        uint256 _vestingPeriod = vestingPeriod;

        unchecked {
            // If the vesting period has passed, there is no locked profit.
            // This cannot overflow on human timescales
            if (block.timestamp >= _lastUpdate + _vestingPeriod) return 0;

            // Get the maximum amount we could return.
            uint256 currentlyVestingProfit = vestingProfit;

            // Compute how much profit remains locked based on the last time a profit was acknowledged
            // and the vesting period. It's impossible for an update to be in the future, so this will never underflow.
            return currentlyVestingProfit - (currentlyVestingProfit * (block.timestamp - _lastUpdate)) / _vestingPeriod;
        }
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                ERC4626 VIEW FUNCTIONS                                              
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - lockedProfit();
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                        HELPER                                                      
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Provides an estimated Annual Percentage Rate for base depositors on this contract
    function estimatedAPR() external view returns (uint256 apr) {
        uint256 currentlyVestingProfit = vestingProfit;
        uint256 weightedAssets = vestingPeriod * totalAssets();
        if (currentlyVestingProfit != 0 && weightedAssets != 0)
            apr = (currentlyVestingProfit * 3600 * 24 * 365 * BASE_18) / weightedAssets;
    }

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                      GOVERNANCE                                                    
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Sets the `surplusManager` address which handles protocol fees
    function setSurplusManager(address _surplusManager) external onlyGuardian {
        surplusManager = _surplusManager;
    }

    /// @notice Changes the contract parameters
    function setParams(bytes32 what, uint64 param) external onlyGuardian {
        if (param > BASE_9) revert InvalidParam();
        else if (what == "PF") protocolSafetyFee = param;
        else if (what == "VP") vestingPeriod = uint32(param);
        else if (what == "UD") updateDelay = uint32(param);
        else if (what == "P") paused = uint8(param);
        else revert InvalidParam();
        emit FiledUint64(param, what);
    }
}
