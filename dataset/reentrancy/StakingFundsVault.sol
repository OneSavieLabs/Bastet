// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { StakehouseAPI } from "@blockswaplab/stakehouse-solidity-api/contracts/StakehouseAPI.sol";
import { IDataStructures } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IDataStructures.sol";

import { ITransferHookProcessor } from "../interfaces/ITransferHookProcessor.sol";
import { Syndicate } from "../syndicate/Syndicate.sol";
import { ETHPoolLPFactory } from "./ETHPoolLPFactory.sol";
import { LiquidStakingManager } from "./LiquidStakingManager.sol";
import { LPTokenFactory } from "./LPTokenFactory.sol";
import { LPToken } from "./LPToken.sol";
import { SyndicateRewardsProcessor } from "./SyndicateRewardsProcessor.sol";

/// @title MEV and fees vault for a specified liquid staking network
contract StakingFundsVault is
    Initializable, ITransferHookProcessor, StakehouseAPI, ETHPoolLPFactory, SyndicateRewardsProcessor, ReentrancyGuard
{

    /// @notice signalize that the vault received ETH
    event ETHDeposited(address sender, uint256 amount);

    /// @notice signalize ETH withdrawal from the vault
    event ETHWithdrawn(address receiver, address admin, uint256 amount);

    /// @notice signalize ERC20 token recovery by the admin
    event ERC20Recovered(address admin, address recipient, uint256 amount);

    /// @notice signalize unwrapping of WETH in the vault
    event WETHUnwrapped(address admin, uint256 amount);

    /// @notice Address of the network manager
    LiquidStakingManager public liquidStakingNetworkManager;

    /// @notice Total number of LP tokens issued in WEI
    uint256 public totalShares;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @param _liquidStakingNetworkManager address of the liquid staking network manager
    function init(address _liquidStakingNetworkManager, LPTokenFactory _lpTokenFactory) external virtual initializer {
        _init(LiquidStakingManager(payable(_liquidStakingNetworkManager)), _lpTokenFactory);
    }

    modifier onlyManager() {
        require(msg.sender == address(liquidStakingNetworkManager), "Only network manager");
        _;
    }

    /// @notice Allows the liquid staking manager to notify funds vault about new derivatives minted to enable MEV claiming
    function updateDerivativesMinted() external onlyManager {
        // We know 4 ETH for the KNOT came from this vault so increase the shares to get a % of vault rewards
        totalShares += 4 ether;
    }

    /// @notice For knots that have minted derivatives, update accumulated ETH per LP
    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(totalShares);
    }

    /// @notice Batch deposit ETH for staking against multiple BLS public keys
    /// @param _blsPublicKeyOfKnots List of BLS public keys being staked
    /// @param _amounts Amounts of ETH being staked for each BLS public key
    function batchDepositETHForStaking(bytes[] calldata _blsPublicKeyOfKnots, uint256[] calldata _amounts) external payable {
        uint256 numOfValidators = _blsPublicKeyOfKnots.length;
        require(numOfValidators > 0, "Empty arrays");
        require(numOfValidators == _amounts.length, "Inconsistent array lengths");

        // Update accrued ETH to contract per LP
        updateAccumulatedETHPerLP();

        uint256 totalAmount;
        for (uint256 i; i < numOfValidators; ++i) {
            require(liquidStakingNetworkManager.isBLSPublicKeyBanned(_blsPublicKeyOfKnots[i]) == false, "BLS public key is not part of LSD network");
            require(
                getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKeyOfKnots[i]) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
                "Lifecycle status must be one"
            );

            LPToken tokenForKnot = lpTokenForKnot[_blsPublicKeyOfKnots[i]];
            if (address(tokenForKnot) != address(0)) {
                // Give anything owed to the user before making updates to user state
                _distributeETHRewardsToUserForToken(
                    msg.sender,
                    address(tokenForKnot),
                    tokenForKnot.balanceOf(msg.sender),
                    msg.sender
                );
            }

            uint256 amount = _amounts[i];
            totalAmount += amount;

            _depositETHForStaking(_blsPublicKeyOfKnots[i], amount, true);

            // Ensure user cannot get historical rewards
            tokenForKnot = lpTokenForKnot[_blsPublicKeyOfKnots[i]];
            claimed[msg.sender][address(tokenForKnot)] = (tokenForKnot.balanceOf(msg.sender) * accumulatedETHPerLPShare) / PRECISION;
        }

        // Ensure that the sum of LP tokens issued equals the ETH deposited into the contract
        require(msg.value == totalAmount, "Invalid ETH amount attached");
    }

    /// @notice Deposit ETH against a BLS public key for staking
    /// @param _blsPublicKeyOfKnot BLS public key of validator registered by a node runner
    /// @param _amount Amount of ETH being staked
    function depositETHForStaking(bytes calldata _blsPublicKeyOfKnot, uint256 _amount) public payable returns (uint256) {
        require(liquidStakingNetworkManager.isBLSPublicKeyBanned(_blsPublicKeyOfKnot) == false, "BLS public key is banned or not a part of LSD network");
        require(
            getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKeyOfKnot) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
            "Lifecycle status must be one"
        );

        require(msg.value == _amount, "Must provide correct amount of ETH");

        // Update accrued ETH to contract per LP
        updateAccumulatedETHPerLP();

        // Give anything owed to the user before making updates to user state
        LPToken tokenForKnot = lpTokenForKnot[_blsPublicKeyOfKnot];
        if (address(tokenForKnot) != address(0)) {
            _distributeETHRewardsToUserForToken(
                msg.sender,
                address(tokenForKnot),
                tokenForKnot.balanceOf(msg.sender),
                msg.sender
            );
        }

        _depositETHForStaking(_blsPublicKeyOfKnot, _amount, true);

        // Ensure user cannot get historical rewards
        tokenForKnot = lpTokenForKnot[_blsPublicKeyOfKnot];
        claimed[msg.sender][address(tokenForKnot)] = (tokenForKnot.balanceOf(msg.sender) * accumulatedETHPerLPShare) / PRECISION;

        return _amount;
    }

    /// @notice Burn a batch of LP tokens in order to get back ETH that has not been staked by BLS public key
    /// @param _blsPublicKeys List of BLS public keys that received ETH for staking
    /// @param _amounts List of amounts of LP tokens being burnt
    function burnLPTokensForETHByBLS(bytes[] calldata _blsPublicKeys, uint256[] calldata _amounts) external {
        uint256 numOfTokens = _blsPublicKeys.length;
        require(numOfTokens > 0, "Empty arrays");
        require(numOfTokens == _amounts.length, "Inconsistent array length");
        for (uint256 i; i < numOfTokens; ++i) {
            LPToken token = lpTokenForKnot[_blsPublicKeys[i]];
            require(address(token) != address(0), "No ETH staked for specified BLS key");
            burnLPForETH(token, _amounts[i]);
        }
    }

    /// @notice Burn a batch of LP tokens in order to get back ETH that has not been staked
    /// @param _lpTokens Address of LP tokens being burnt
    /// @param _amounts Amount of LP tokens being burnt
    function burnLPTokensForETH(LPToken[] calldata _lpTokens, uint256[] calldata _amounts) external {
        uint256 numOfTokens = _lpTokens.length;
        require(numOfTokens > 0, "Empty arrays");
        require(numOfTokens == _amounts.length, "Inconsistent array length");
        for (uint256 i; i < numOfTokens; ++i) {
            burnLPForETH(_lpTokens[i], _amounts[i]);
        }
    }

    /// @notice For a user that has deposited ETH that has not been staked, allow them to burn LP to get ETH back
    /// @param _lpToken Address of the LP token being burnt
    /// @param _amount Amount of LP token being burnt
    function burnLPForETH(LPToken _lpToken, uint256 _amount) public nonReentrant {
        require(_amount >= MIN_STAKING_AMOUNT, "Amount cannot be zero");
        require(_amount <= _lpToken.balanceOf(msg.sender), "Not enough balance");
        require(address(_lpToken) != address(0), "Zero address specified");

        bytes memory blsPublicKeyOfKnot = KnotAssociatedWithLPToken[_lpToken];
        require(
            getAccountManager().blsPublicKeyToLifecycleStatus(blsPublicKeyOfKnot) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
            "Cannot burn LP tokens"
        );
        require(_lpToken.lastInteractedTimestamp(msg.sender) + 30 minutes < block.timestamp, "Too new");

        updateAccumulatedETHPerLP();

        _lpToken.burn(msg.sender, _amount);

        (bool result,) = msg.sender.call{value: _amount}("");
        require(result, "Transfer failed");
        emit ETHWithdrawnByDepositor(msg.sender, _amount);

        emit LPTokenBurnt(blsPublicKeyOfKnot, address(_lpToken), msg.sender, _amount);
    }

    /// @notice Any LP tokens for BLS keys that have had their derivatives minted can claim ETH from the syndicate contract
    /// @param _blsPubKeys List of BLS public keys being processed
    function claimRewards(
        address _recipient,
        bytes[] calldata _blsPubKeys
    ) external nonReentrant {
        for (uint256 i; i < _blsPubKeys.length; ++i) {
            require(
                liquidStakingNetworkManager.isBLSPublicKeyBanned(_blsPubKeys[i]) == false,
                "Unknown BLS public key"
            );

            // Ensure that the BLS key has its derivatives minted
            require(
                getAccountManager().blsPublicKeyToLifecycleStatus(_blsPubKeys[i]) == IDataStructures.LifecycleStatus.TOKENS_MINTED,
                "Derivatives not minted"
            );

            if (i == 0 && !Syndicate(payable(liquidStakingNetworkManager.syndicate())).isNoLongerPartOfSyndicate(_blsPubKeys[i])) {
                // Withdraw any ETH accrued on free floating SLOT from syndicate to this contract
                // If a partial list of BLS keys that have free floating staked are supplied, then partial funds accrued will be fetched
                _claimFundsFromSyndicateForDistribution(
                    liquidStakingNetworkManager.syndicate(),
                    _blsPubKeys
                );

                // Distribute ETH per LP
                updateAccumulatedETHPerLP();
            }

            // If msg.sender has a balance for the LP token associated with the BLS key, then send them any accrued ETH
            LPToken token = lpTokenForKnot[_blsPubKeys[i]];
            require(address(token) != address(0), "Invalid BLS key");
            require(token.lastInteractedTimestamp(msg.sender) + 30 minutes < block.timestamp, "Last transfer too recent");
            _distributeETHRewardsToUserForToken(msg.sender, address(token), token.balanceOf(msg.sender), _recipient);
        }
    }

    /// @notice function to allow admins to withdraw ETH from the vault for staking purpose
    /// @param _wallet address of the smart wallet that receives ETH
    /// @param _amount number of ETH withdrawn
    /// @return number of ETH withdrawn
    function withdrawETH(address _wallet, uint256 _amount) public onlyManager nonReentrant returns (uint256) {
        require(_amount >= 4 ether, "Amount cannot be less than 4 ether");
        require(_amount <= address(this).balance, "Not enough ETH to withdraw");
        require(_wallet != address(0), "Zero address");

        (bool result,) = _wallet.call{value: _amount}("");
        require(result, "Transfer failed");

        emit ETHWithdrawn(_wallet, msg.sender, _amount);

        return _amount;
    }

    /// @notice For any knots that are no longer part of syndicate facilitate unstaking so that knot can rage quit
    /// @param _blsPublicKeys List of BLS public keys being processed (assuming DAO only has BLS pub keys from correct smart wallet)
    /// @param _amounts Amounts of free floating sETH that will be unstaked
    function unstakeSyndicateSharesForRageQuit(
        address _sETHRecipient,
        bytes[] calldata _blsPublicKeys,
        uint256[] calldata _amounts
    ) external onlyManager nonReentrant {
        Syndicate syndicate = Syndicate(payable(liquidStakingNetworkManager.syndicate()));

        _claimFundsFromSyndicateForDistribution(address(syndicate), _blsPublicKeys);

        updateAccumulatedETHPerLP();

        for (uint256 i; i < _blsPublicKeys.length; ++i) {
            require(syndicate.isNoLongerPartOfSyndicate(_blsPublicKeys[i]), "Knot is still active in syndicate");
        }

        syndicate.unstake(address(this), _sETHRecipient, _blsPublicKeys, _amounts);
    }

    /// @notice Preview total ETH accumulated by a staking funds LP token holder associated with many KNOTs that have minted derivatives
    function batchPreviewAccumulatedETHByBLSKeys(address _user, bytes[] calldata _blsPubKeys) external view returns (uint256) {
        uint256 totalAccumulated;
        for (uint256 i; i < _blsPubKeys.length; ++i) {
            LPToken token = lpTokenForKnot[_blsPubKeys[i]];
            totalAccumulated += previewAccumulatedETH(_user, token);
        }
        return totalAccumulated;
    }

    /// @notice Preview total ETH accumulated by a staking funds LP token holder associated with many KNOTs that have minted derivatives
    function batchPreviewAccumulatedETH(address _user, LPToken[] calldata _token) external view returns (uint256) {
        uint256 totalAccumulated;
        for (uint256 i; i < _token.length; ++i) {
            totalAccumulated += previewAccumulatedETH(_user, _token[i]);
        }
        return totalAccumulated;
    }

    /// @notice Preview total ETH accumulated by a staking funds LP token holder associated with a KNOT that has minted derivatives
    function previewAccumulatedETH(address _user, LPToken _token) public view returns (uint256) {
        // if token maps to BLS public key that has not been minted derivatives then return zero as it's not eligible
        bytes memory associatedBLSPublicKeyOfLpToken = KnotAssociatedWithLPToken[_token];
        if (getAccountManager().blsPublicKeyToLifecycleStatus(associatedBLSPublicKeyOfLpToken) != IDataStructures.LifecycleStatus.TOKENS_MINTED) {
            return 0;
        }

        // Looking at this contract balance and the ETH that is yet to be transferred from the syndicate, then tell the user how much ETH they have earned
        address payable syndicate = payable(liquidStakingNetworkManager.syndicate());
        return _previewAccumulatedETH(
            _user,
            address(_token),
            _token.balanceOf(_user),
            totalShares,
            Syndicate(syndicate).previewUnclaimedETHAsFreeFloatingStaker(
                address(this),
                associatedBLSPublicKeyOfLpToken
            )
        );
    }

    /// @notice before an LP token is transferred, pay the user any unclaimed ETH rewards
    function beforeTokenTransfer(address _from, address _to, uint256) external override {
        address syndicate = liquidStakingNetworkManager.syndicate();
        if (syndicate != address(0)) {
            LPToken token = LPToken(msg.sender);
            bytes memory blsPubKey = KnotAssociatedWithLPToken[token];
            require(blsPubKey.length > 0, "Invalid token");

            if (getAccountManager().blsPublicKeyToLifecycleStatus(blsPubKey) == IDataStructures.LifecycleStatus.TOKENS_MINTED) {
                // Claim any ETH for the BLS key mapped to this token
                bytes[] memory keys = new bytes[](1);
                keys[0] = blsPubKey;
                _claimFundsFromSyndicateForDistribution(syndicate, keys);

                // Update the accumulated ETH per minted derivative LP share
                updateAccumulatedETHPerLP();

                // distribute any due rewards for the `from` user
                if (_from != address(0)) {
                    _distributeETHRewardsToUserForToken(_from, address(token), token.balanceOf(_from), _from);
                }

                // in case the new user has existing rewards - give it to them so that the after transfer hook does not wipe pending rewards
                _distributeETHRewardsToUserForToken(_to, address(token), token.balanceOf(_to), _to);
            }
        }
    }

    /// @notice After an LP token is transferred, ensure that the new account cannot claim historical rewards
    function afterTokenTransfer(address, address _to, uint256) external override {
        if (LiquidStakingManager(payable(liquidStakingNetworkManager)).syndicate() != address(0)) {
            LPToken token = LPToken(msg.sender);
            require(KnotAssociatedWithLPToken[token].length > 0, "Invalid token");

            // claim is calculated on full balance not amount being transferred so that double claims are not possible
            claimed[_to][address(token)] = (token.balanceOf(_to) * accumulatedETHPerLPShare) / PRECISION;
        }
    }

    /// @notice Claim ETH to this contract from the syndicate that was accrued by a list of actively staked validators
    /// @param _blsPubKeys List of BLS public key identifiers of validators that have sETH staked in the syndicate for the vault
    function claimFundsFromSyndicateForDistribution(bytes[] memory _blsPubKeys) external {
        _claimFundsFromSyndicateForDistribution(liquidStakingNetworkManager.syndicate(), _blsPubKeys);
    }

    /// @dev Claim ETH from syndicate for a list of BLS public keys for later distribution amongst LPs
    function _claimFundsFromSyndicateForDistribution(address _syndicate, bytes[] memory _blsPubKeys) internal {
        require(_syndicate != address(0), "Invalid configuration");

        // Claim all of the ETH due from the syndicate for the auto-staked sETH
        Syndicate syndicateContract = Syndicate(payable(_syndicate));
        syndicateContract.claimAsStaker(address(this), _blsPubKeys);

        updateAccumulatedETHPerLP();
    }

    /// @dev Initialization logic
    function _init(LiquidStakingManager _liquidStakingNetworkManager, LPTokenFactory _lpTokenFactory) internal virtual {
        require(address(_liquidStakingNetworkManager) != address(0), "Zero Address");
        require(address(_lpTokenFactory) != address(0), "Zero Address");

        liquidStakingNetworkManager = _liquidStakingNetworkManager;
        lpTokenFactory = _lpTokenFactory;

        baseLPTokenName = "ETHLPToken_";
        baseLPTokenSymbol = "ETHLP_";
        maxStakingAmountPerValidator = 4 ether;
    }
}