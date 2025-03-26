// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "./WithdrawQueueStorage.sol";
import "../Errors/Errors.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WithdrawQueue is
    Initializable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    WithdrawQueueStorageV1
{
    using SafeERC20 for IERC20;

    event WithdrawBufferTargetUpdated(uint256 oldBufferTarget, uint256 newBufferTarget);

    event CoolDownPeriodUpdated(uint256 oldCoolDownPeriod, uint256 newCoolDownPeriod);

    event EthBufferFilled(uint256 amount);

    event ERC20BufferFilled(address asset, uint256 amount);

    event WithdrawRequestCreated(
        uint256 indexed withdrawRequestID,
        address user,
        address claimToken,
        uint256 amountToRedeem,
        uint256 ezETHAmountLocked,
        uint256 withdrawRequestIndex
    );

    event WithdrawRequestClaimed(WithdrawRequest withdrawRequest);

    /// @dev Allows only Withdraw Queue Admin to configure the contract
    modifier onlyWithdrawQueueAdmin() {
        if (!roleManager.isWithdrawQueueAdmin(msg.sender)) revert NotWithdrawQueueAdmin();
        _;
    }

    /// @dev Allows only RestakeManager to call the functions
    modifier onlyRestakeManager() {
        if (msg.sender != address(restakeManager)) revert NotRestakeManager();
        _;
    }

    modifier onlyDepositQueue() {
        if (msg.sender != address(restakeManager.depositQueue())) revert NotDepositQueue();
        _;
    }

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice  Initializes the contract with initial vars
     */
    function initialize(
        IRoleManager _roleManager,
        IRestakeManager _restakeManager,
        IEzEthToken _ezETH,
        IRenzoOracle _renzoOracle,
        uint256 _coolDownPeriod,
        TokenWithdrawBuffer[] calldata _withdrawalBufferTarget
    ) external initializer {
        if (
            address(_roleManager) == address(0) ||
            address(_ezETH) == address(0) ||
            address(_renzoOracle) == address(0) ||
            address(_restakeManager) == address(0) ||
            _withdrawalBufferTarget.length == 0 ||
            _coolDownPeriod == 0
        ) revert InvalidZeroInput();

        __Pausable_init();

        roleManager = _roleManager;
        restakeManager = _restakeManager;
        ezETH = _ezETH;
        renzoOracle = _renzoOracle;
        coolDownPeriod = _coolDownPeriod;
        for (uint256 i = 0; i < _withdrawalBufferTarget.length; ) {
            if (
                _withdrawalBufferTarget[i].asset == address(0) ||
                _withdrawalBufferTarget[i].bufferAmount == 0
            ) revert InvalidZeroInput();
            withdrawalBufferTarget[_withdrawalBufferTarget[i].asset] = _withdrawalBufferTarget[i]
                .bufferAmount;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  Updates the WithdrawBufferTarget for max withdraw available
     * @dev     Permissioned call (onlyWithdrawQueueAdmin)
     * @param   _newBufferTarget  new max buffer target available to withdraw
     */
    function updateWithdrawBufferTarget(
        TokenWithdrawBuffer[] calldata _newBufferTarget
    ) external onlyWithdrawQueueAdmin {
        if (_newBufferTarget.length == 0) revert InvalidZeroInput();
        for (uint256 i = 0; i < _newBufferTarget.length; ) {
            if (_newBufferTarget[i].asset == address(0) || _newBufferTarget[i].bufferAmount == 0)
                revert InvalidZeroInput();
            emit WithdrawBufferTargetUpdated(
                withdrawalBufferTarget[_newBufferTarget[i].asset],
                _newBufferTarget[i].bufferAmount
            );
            withdrawalBufferTarget[_newBufferTarget[i].asset] = _newBufferTarget[i].bufferAmount;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Updates the coolDownPeriod for withdrawal requests
     * @dev    It is a permissioned call (onlyWithdrawQueueAdmin)
     * @param   _newCoolDownPeriod  new coolDownPeriod in seconds
     */
    function updateCoolDownPeriod(uint256 _newCoolDownPeriod) external onlyWithdrawQueueAdmin {
        if (_newCoolDownPeriod == 0) revert InvalidZeroInput();
        emit CoolDownPeriodUpdated(coolDownPeriod, _newCoolDownPeriod);
        coolDownPeriod = _newCoolDownPeriod;
    }

    /**
     * @notice  Pause the contract
     * @dev     Permissioned call (onlyWithdrawQueueAdmin)
     */
    function pause() external onlyWithdrawQueueAdmin {
        _pause();
    }

    /**
     * @notice  Unpause the contract
     * @dev     Permissioned call (onlyWithdrawQueueAdmin)
     */
    function unpause() external onlyWithdrawQueueAdmin {
        _unpause();
    }

    /**
     * @notice  returns available to withdraw for particular asset
     * @param   _asset  address of asset. for ETH _asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
     * @return  uint256  amount available to withdraw from buffer
     */
    function getAvailableToWithdraw(address _asset) public view returns (uint256) {
        if (_asset != IS_NATIVE) {
            return IERC20(_asset).balanceOf(address(this)) - claimReserve[_asset];
        } else {
            return address(this).balance - claimReserve[_asset];
        }
    }

    /**
     * @notice  returns empty withdraw buffer for particular asset
     * @dev     returns 0 is buffer is full
     * @param   _asset  address of asset. for ETH _asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
     * @return  uint256  amount of buffer to be filled
     */
    function getBufferDeficit(address _asset) public view returns (uint256) {
        uint256 availableToWithdraw = getAvailableToWithdraw(_asset);
        return
            withdrawalBufferTarget[_asset] > availableToWithdraw
                ? withdrawalBufferTarget[_asset] - availableToWithdraw
                : 0;
    }

    /**
     * @notice  fill Eth WithdrawBuffer from RestakeManager deposits
     * @dev     permissioned call (onlyRestakeManager)
     */
    function fillEthWithdrawBuffer() external payable nonReentrant onlyDepositQueue {
        emit EthBufferFilled(msg.value);
    }

    /**
     * @notice  Fill ERC20 token withdraw buffer from RestakeManager deposits
     * @dev     permissioned call (onlyDepositQueue)
     * @param   _asset  address of ERC20 asset to fill up the buffer
     * @param   _amount  amount of ERC20 asset to fill up the buffer
     */
    function fillERC20WithdrawBuffer(
        address _asset,
        uint256 _amount
    ) external nonReentrant onlyDepositQueue {
        if (_asset == address(0) || _amount == 0) revert InvalidZeroInput();
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        emit ERC20BufferFilled(_asset, _amount);
    }

    /**
     * @notice  Creates a withdraw request for user
     * @param   _amount  amount of ezETH to withdraw
     * @param   _assetOut  output token to receive on claim
     */
    function withdraw(uint256 _amount, address _assetOut) external nonReentrant {
        // check for 0 values
        if (_amount == 0 || _assetOut == address(0)) revert InvalidZeroInput();

        // check if provided assetOut is supported
        if (withdrawalBufferTarget[_assetOut] == 0) revert UnsupportedWithdrawAsset();

        // transfer ezETH tokens to this address
        IERC20(address(ezETH)).safeTransferFrom(msg.sender, address(this), _amount);

        // calculate totalTVL
        (, , uint256 totalTVL) = restakeManager.calculateTVLs();

        // Calculate amount to Redeem in ETH
        uint256 amountToRedeem = renzoOracle.calculateRedeemAmount(
            _amount,
            ezETH.totalSupply(),
            totalTVL
        );

        // update amount in claim asset, if claim asset is not ETH
        if (_assetOut != IS_NATIVE) {
            // Get ERC20 asset equivalent amount
            amountToRedeem = renzoOracle.lookupTokenAmountFromValue(
                IERC20(_assetOut),
                amountToRedeem
            );
        }

        // revert if amount to redeem is greater than withdrawBufferTarget
        if (amountToRedeem > getAvailableToWithdraw(_assetOut)) revert NotEnoughWithdrawBuffer();

        // increment the withdrawRequestNonce
        withdrawRequestNonce++;

        // add withdraw request for msg.sender
        withdrawRequests[msg.sender].push(
            WithdrawRequest(
                _assetOut,
                withdrawRequestNonce,
                amountToRedeem,
                _amount,
                block.timestamp
            )
        );

        // add redeem amount to claimReserve of claim asset
        claimReserve[_assetOut] += amountToRedeem;

        emit WithdrawRequestCreated(
            withdrawRequestNonce,
            msg.sender,
            _assetOut,
            amountToRedeem,
            _amount,
            withdrawRequests[msg.sender].length - 1
        );
    }

    /**
     * @notice  Returns the number of outstanding withdrawal requests of the specified user
     * @param   user  address of the user
     * @return  uint256  number of outstanding withdrawal requests
     */
    function getOutstandingWithdrawRequests(address user) public view returns (uint256) {
        return withdrawRequests[user].length;
    }

    /**
     * @notice  Claim user withdraw request
     * @dev     revert on claim before cooldown period
     * @param   withdrawRequestIndex  Index of the Withdraw Request user wants to claim
     */
    function claim(uint256 withdrawRequestIndex) external nonReentrant {
        // check if provided withdrawRequest Index is valid
        if (withdrawRequestIndex >= withdrawRequests[msg.sender].length)
            revert InvalidWithdrawIndex();

        WithdrawRequest memory _withdrawRequest = withdrawRequests[msg.sender][
            withdrawRequestIndex
        ];
        if (block.timestamp - _withdrawRequest.createdAt < coolDownPeriod) revert EarlyClaim();

        // subtract value from claim reserve for claim asset
        claimReserve[_withdrawRequest.collateralToken] -= _withdrawRequest.amountToRedeem;

        // delete the withdraw request
        withdrawRequests[msg.sender][withdrawRequestIndex] = withdrawRequests[msg.sender][
            withdrawRequests[msg.sender].length - 1
        ];
        withdrawRequests[msg.sender].pop();

        // burn ezETH locked for withdraw request
        ezETH.burn(address(this), _withdrawRequest.ezETHLocked);

        // send selected redeem asset to user
        if (_withdrawRequest.collateralToken == IS_NATIVE) {
            payable(msg.sender).transfer(_withdrawRequest.amountToRedeem);
        } else {
            IERC20(_withdrawRequest.collateralToken).transfer(
                msg.sender,
                _withdrawRequest.amountToRedeem
            );
        }
        // emit the event
        emit WithdrawRequestClaimed(_withdrawRequest);
    }
}