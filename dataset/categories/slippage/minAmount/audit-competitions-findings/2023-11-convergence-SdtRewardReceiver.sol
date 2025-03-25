// SPDX-License-Identifier: MIT
/**
 _____
/  __ \
| /  \/ ___  _ ____   _____ _ __ __ _  ___ _ __   ___ ___
| |    / _ \| '_ \ \ / / _ \ '__/ _` |/ _ \ '_ \ / __/ _ \
| \__/\ (_) | | | \ V /  __/ | | (_| |  __/ | | | (_|  __/
 \____/\___/|_| |_|\_/ \___|_|  \__, |\___|_| |_|\___\___|
                                 __/ |
                                |___/
 */

/// @title  Cvg-Finance - SdtReceiver
/// @notice Receives all StakeDAO rewards from SdtBuffer & CvgSdtBuffer.
/// @dev Optimize gas cost on claim on several contract by limiting ERC20 transfers.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/ISdtStakingPositionService.sol";
import "../../interfaces/ISdtStakingPositionManager.sol";
import "../../interfaces/ISdAssets.sol";
import "../../interfaces/ICvgControlTower.sol";
import "../../interfaces/ICvg.sol";
import "../../interfaces/ICrvPoolPlain.sol";

/// @title Cvg-Finance - SdtRewardReceiver
/// @notice Contracts receiving StakeDao rewards from SdtBuffers & CvgSdtBuffer.
///
/// @dev
contract SdtRewardReceiver is Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Convergence Control Tower
    ICvgControlTower public cvgControlTower;

    /// @dev StakeDao token
    IERC20 public sdt;

    /// @dev StakeDao token
    ICvg public cvg;

    /// @notice CvgSdt token contract
    IERC20Mintable public cvgSdt;

    /// @notice CvgSdt/Sdt stable pool contract on Curve
    ICrvPoolPlain public poolCvgSDT;

    ISdtStakingPositionManager public sdtStakingPositionManager;

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        INITIALIZE
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        IERC20 _sdt = _cvgControlTower.sdt();
        address treasuryDao = _cvgControlTower.treasuryDao();
        ICvg _cvg = _cvgControlTower.cvgToken();
        IERC20Mintable _cvgSdt = _cvgControlTower.cvgSDT();
        ISdtStakingPositionManager _sdtStakingPositionManager = _cvgControlTower.sdtStakingPositionManager();

        require(address(_sdt) != address(0), "SDT_ZERO");
        sdt = _sdt;

        require(address(_cvg) != address(0), "CVG_ZERO");
        cvg = _cvg;

        require(address(_cvgSdt) != address(0), "CVG_SDT_ZERO");
        cvgSdt = _cvgSdt;

        require(address(_sdtStakingPositionManager) != address(0), "SDT_POSITION_MNGR_ZERO");
        sdtStakingPositionManager = _sdtStakingPositionManager;

        require(treasuryDao != address(0), "TREASURY_DAO_ZERO");
        _transferOwnership(treasuryDao);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Mint CVG & distribute StakeDao rewards for a receiver, owner of a Staking Position
     * @dev    Function used when only one Staking Position is involved for a claiming.
     * @param receiver List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param totalCvgClaimable List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param totalSdtRewardsClaimable List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param isConvert      If true, converts all SDT into CvgSDT.
     * @param isMint         If true, mints CvgSDT 1:1, else swap into stablePool
     */
    function claimCvgSdtSimple(
        address receiver,
        uint256 totalCvgClaimable,
        ICommonStruct.TokenAmount[] memory totalSdtRewardsClaimable,
        bool isConvert,
        bool isMint
    ) external {
        require(cvgControlTower.isStakingContract(msg.sender), "NOT_STAKING");
        _withdrawRewards(receiver, totalCvgClaimable, totalSdtRewardsClaimable, isConvert, isMint);
    }

    /**
     * @notice Claims rewards from StakeDao integration on several cycles for several tokenID on different SdtStakingPositionService.
     *         Allows the users to claim all the rewards from the StakeDao integration in 1 Tx.
     *         All CVG to mint are accumulated in one value.
     *         All StakeDao rewards are merged in one array.
     * @param claimContracts  List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param isConvert       If true, converts all SDT into CvgSDT.
     * @param isMint          If true, mints CvgSDT 1:1, else swap into stablePool
     * @param sdtRewardCount This parameter must be configured through the front-end.
     */
    function claimMultipleStaking(
        ISdtStakingPositionManager.ClaimSdtStakingContract[] calldata claimContracts,
        bool isConvert,
        bool isMint,
        uint256 sdtRewardCount
    ) external {
        /// @dev Checks for all positions input in data : Token ownership & verify positions are linked to the right staking service & verify timelocking
        sdtStakingPositionManager.checkMultipleClaimCompliance(claimContracts, msg.sender);

        /// @dev Accumulates amounts of CVG coming from all claims.
        uint256 _totalCvgClaimable;

        /// @dev Array merging & accumulating rewards coming from diferent claims.
        ICommonStruct.TokenAmount[] memory _totalSdtClaimable = new ICommonStruct.TokenAmount[](sdtRewardCount);

        /// @dev Iterate over all staking service
        for (uint256 stakingIndex; stakingIndex < claimContracts.length; ) {
            ISdtStakingPositionService sdtStaking = claimContracts[stakingIndex].stakingContract;
            uint256 tokensLength = claimContracts[stakingIndex].tokenIds.length;
            /// @dev Iterate over all tokens linked to the iterated cycle.
            for (uint256 tokenIdIndex; tokenIdIndex < tokensLength; ) {
                /** @dev Claims Cvg & Sdt
                 *       Returns the amount of CVG claimed on the position.
                 *       Returns the array of all SDT rewards claimed on the position.
                 */
                (uint256 cvgClaimable, ICommonStruct.TokenAmount[] memory _sdtRewards) = sdtStaking.claimCvgSdtMultiple(
                    claimContracts[stakingIndex].tokenIds[tokenIdIndex],
                    msg.sender
                );
                /// @dev increments the amount to mint at the end of function
                _totalCvgClaimable += cvgClaimable;

                uint256 sdtRewardsLength = _sdtRewards.length;
                /// @dev Iterate over all SDT rewards claimed on the iterated position
                for (uint256 positionRewardIndex; positionRewardIndex < sdtRewardsLength; ) {
                    /// @dev Is the claimable amount is 0 on this token
                    ///      We bypass the process to save gas
                    if (_sdtRewards[positionRewardIndex].amount != 0) {
                        /// @dev Iterate ower the final array to merge the iterated SdtRewards in the totalSdtClaimable
                        for (uint256 totalRewardIndex; totalRewardIndex < sdtRewardCount; ) {
                            address iteratedTotatClaimableToken = address(_totalSdtClaimable[totalRewardIndex].token);
                            /// @dev If the token is not already in the totalSdtClaimable.
                            if (iteratedTotatClaimableToken == address(0)) {
                                /// @dev Push the token in the totalClaimable array.
                                _totalSdtClaimable[totalRewardIndex] = ICommonStruct.TokenAmount({
                                    token: _sdtRewards[positionRewardIndex].token,
                                    amount: _sdtRewards[positionRewardIndex].amount
                                });
                                /// @dev Pass to the next token
                                break;
                            }
                            /// @dev If the token is already in the totalSdtClaimable.
                            if (iteratedTotatClaimableToken == address(_sdtRewards[positionRewardIndex].token)) {
                                /// @dev Increments the claimable amount.
                                _totalSdtClaimable[totalRewardIndex].amount += _sdtRewards[positionRewardIndex].amount;
                                /// @dev Pass to the next token
                                break;
                            }

                            /// @dev If the token is not found in the totalRewards and we are at the end of the array.
                            ///      it means the sdtRewardCount is not properly configured.
                            require(totalRewardIndex != sdtRewardCount - 1, "REWARD_COUNT_TOO_SMALL");

                            unchecked {
                                ++totalRewardIndex;
                            }
                        }
                    }

                    unchecked {
                        ++positionRewardIndex;
                    }
                }

                unchecked {
                    ++tokenIdIndex;
                }
            }
            unchecked {
                ++stakingIndex;
            }
        }

        _withdrawRewards(msg.sender, _totalCvgClaimable, _totalSdtClaimable, isConvert, isMint);
    }

    /** @dev Mint accumulated CVG & Transfers StakeDao rewards to the claimer of Stakings
     *  @param receiver                 Receiver of the claim
     *  @param totalCvgClaimable        Amount of CVG to mint to the receiver
     *  @param totalSdtRewardsClaimable Array of all StakeDao rewards to send to the receiver
     *  @param isConvert                If true, converts all SDT into CvgSDT.
     *  @param isMint                   If true, mints CvgSDT 1:1, else swap into stablePool
     *
     */
    function _withdrawRewards(
        address receiver,
        uint256 totalCvgClaimable,
        ICommonStruct.TokenAmount[] memory totalSdtRewardsClaimable,
        bool isConvert,
        bool isMint
    ) internal {
        /// @dev Mints accumulated CVG and claim StakeDao rewards
        IERC20 _sdt = sdt;
        if (totalCvgClaimable > 0) {
            cvg.mintStaking(receiver, totalCvgClaimable);
        }
        for (uint256 i; i < totalSdtRewardsClaimable.length; ) {
            uint256 rewardAmount = totalSdtRewardsClaimable[i].amount;
            if (rewardAmount > 0) {
                if (isConvert && totalSdtRewardsClaimable[i].token == _sdt) {
                    if (isMint) {
                        /// @dev Mint cvgSdt 1:1 via CvgToke contract
                        cvgSdt.mint(receiver, rewardAmount);
                    } else {
                        ICrvPoolPlain _poolCvgSDT = poolCvgSDT;
                        /// @dev Only swap if the returned amount in CvgSdt is gretear than the amount rewarded in SDT
                        _poolCvgSDT.exchange(0, 1, rewardAmount, _poolCvgSDT.get_dy(0, 1, rewardAmount), receiver);
                    }
                } else {
                    totalSdtRewardsClaimable[i].token.safeTransfer(receiver, rewardAmount);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     *  @notice Set the CvgSdt/Sdt stable pool. Approve SDT tokens to be transfered from the CvgSdt LP.
     *  @dev    The approval has to be done to perform swaps from SDT to CvgSdt during claims.
     *  @param _poolCvgSDT Address of the CvgSdt/Sdt stable pool to set
     *  @param amount      Amount of SDT to approve on the Stable pool
     */
    function setPoolCvgSdtAndApprove(ICrvPoolPlain _poolCvgSDT, uint256 amount) external onlyOwner {
        poolCvgSDT = _poolCvgSDT;
        sdt.approve(address(_poolCvgSDT), amount);
        sdt.approve(address(cvgSdt), amount);
    }
}