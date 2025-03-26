// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../interfaces/badger/ICurveZap.sol";
import {IBadgerSettPeak} from "../interfaces/badger/IPeak.sol";
import "../interfaces/badger/ISett.sol";
import "../interfaces/curve/ICurveFi.sol";

contract IbbtcVaultZap is PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    address public guardian;
    address public governance;

    address public constant CURVE_IBBTC_METAPOOL =
        0xFbdCA68601f835b27790D98bbb8eC7f05FDEaA9B; // Ibbtc crv metapool
    ICurveZap public constant CURVE_IBBTC_DEPOSIT_ZAP =
        ICurveZap(0xbba4b444FD10302251d9F5797E763b0d912286A1); // Ibbtc crv deposit zap

    // For zap to ibBTC
    ICurveFi public constant CURVE_REN_POOL =
        ICurveFi(0x93054188d876f558f4a66B2EF1d97d16eDf0895B);
    IERC20Upgradeable public constant RENCRV_TOKEN =
        IERC20Upgradeable(0x49849C98ae39Fff122806C06791Fa73784FB3675);
    ISett public constant RENCRV_VAULT =
        ISett(0x6dEf55d2e18486B9dDfaA075bc4e4EE0B28c1545);
    IBadgerSettPeak public constant SETT_PEAK =
        IBadgerSettPeak(0x41671BA1abcbA387b9b2B752c205e22e916BE6e3);

    ISett public constant IBBTC_VAULT =
        ISett(0xaE96fF08771a109dc6650a1BdCa62F2d558E40af); // Ibbtc crv lp badger vault

    IERC20Upgradeable[] public ASSETS = [
        IERC20Upgradeable(0xc4E15973E6fF2A35cC804c2CF9D2a1b817a8b40F), // ibbtc
        IERC20Upgradeable(0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D), // renbtc
        IERC20Upgradeable(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599), // wbtc
        IERC20Upgradeable(0xfE18be6b3Bd88A2D2A7f928d00292E7a9963CfC6) // sbtc
    ];

    function initialize(address _guardian, address _governance)
        public
        initializer
        whenNotPaused
    {
        require(_guardian != address(0)); // dev: 0 address
        require(_governance != address(0)); // dev: 0 address

        guardian = _guardian;
        governance = _governance;

        // renbtc and wbtc approvals for curve pool
        ASSETS[1].safeApprove(address(CURVE_REN_POOL), type(uint256).max);
        ASSETS[2].safeApprove(address(CURVE_REN_POOL), type(uint256).max);
        // renCrv approval for sett
        RENCRV_TOKEN.safeApprove(address(RENCRV_VAULT), type(uint256).max);
        // bToken approval for peak
        IERC20Upgradeable(address(RENCRV_VAULT)).safeApprove(
            address(SETT_PEAK),
            type(uint256).max
        );

        // ibbtc and sbtc approvals for zap
        ASSETS[0].safeApprove(
            address(CURVE_IBBTC_DEPOSIT_ZAP),
            type(uint256).max
        );
        ASSETS[3].safeApprove(
            address(CURVE_IBBTC_DEPOSIT_ZAP),
            type(uint256).max
        );

        /// @dev approve the metapool tokens for vault to use
        /// @notice the address of metapool token is same as metapool address
        IERC20Upgradeable(CURVE_IBBTC_METAPOOL).safeApprove(
            address(IBBTC_VAULT),
            type(uint256).max
        );
    }

    /// ===== Modifiers =====

    function _onlyGovernance() internal view {
        require(msg.sender == governance, "onlyGovernance");
    }

    function _onlyGovernanceOrGuardian() internal view {
        require(
            msg.sender == governance || msg.sender == guardian,
            "onlyGovernanceOrGuardian"
        );
    }

    /// ===== Permissioned Actions: Guardian =====

    function pause() external {
        _onlyGovernanceOrGuardian();
        _pause();
    }

    /// ===== Permissioned Actions: Governance =====

    function unpause() external {
        _onlyGovernance();
        _unpause();
    }

    function setGuardian(address _guardian) external {
        _onlyGovernance();
        governance = _guardian;
    }

    function setGovernance(address _governance) external {
        _onlyGovernance();
        governance = _governance;
    }

    /// ===== Internal Implementations =====

    function _renZapToIbbtc(uint256[2] memory _amounts)
        internal
        returns (uint256)
    {
        CURVE_REN_POOL.add_liquidity(_amounts, 0);
        RENCRV_VAULT.deposit(RENCRV_TOKEN.balanceOf(address(this)));
        return
            SETT_PEAK.mint(
                0,
                RENCRV_VAULT.balanceOf(address(this)),
                new bytes32[](0)
            );
    }

    /// ===== Public Functions =====

    function deposit(uint256[4] calldata _amounts) public whenNotPaused {
        // TODO: Revert early on blockLock

        uint256[4] memory depositAmounts;

        for (uint256 i = 0; i < 4; i++) {
            if (_amounts[i] > 0) {
                ASSETS[i].safeTransferFrom(
                    msg.sender,
                    address(this),
                    _amounts[i]
                );
                if (i == 0 || i == 3) {
                    // ibbtc and sbtc
                    depositAmounts[i] += _amounts[i];
                }
            }
        }

        if (_amounts[1] > 0 || _amounts[2] > 0) {
            // renbtc and wbtc
            // NOTE: Can change to external zap if implemented
            depositAmounts[0] += _renZapToIbbtc([_amounts[1], _amounts[2]]);
        }

        // deposit into the crv by using ibbtc curve deposit zap
        uint256 vaultDepositAmount = ICurveZap(CURVE_IBBTC_DEPOSIT_ZAP)
            .add_liquidity(
                CURVE_IBBTC_METAPOOL,
                depositAmounts,
                0,
                address(this)
            );

        // deposit crv lp tokens into vault
        ISett(IBBTC_VAULT).depositFor(msg.sender, vaultDepositAmount);
    }
}