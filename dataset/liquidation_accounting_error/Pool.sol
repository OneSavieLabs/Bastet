// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.21;

import "@solmate/tokens/ERC4626.sol";
import "@solmate/utils/FixedPointMathLib.sol";
import "@solmate/utils/ReentrancyGuard.sol";
import "@solmate/utils/SafeTransferLib.sol";

import "../../interfaces/pools/IBaseInterestAllocator.sol";
import "../../interfaces/pools/IFeeManager.sol";
import "../../interfaces/pools/IPool.sol";
import "../../interfaces/pools/IPoolWithWithdrawalQueues.sol";
import "../../interfaces/pools/IPoolOfferHandler.sol";
import "../loans/LoanManager.sol";
import "../utils/Interest.sol";
import "./WithdrawalQueue.sol";

/// @title Pool
/// @author Florida St
/// @notice A pool is an implementation of an ERC4626 that allows LPs to deposit capital that will
///         be used to fund loans (the underwriting rules are handled by the `PoolUnderwriter`). Idle
///         capital is managed by a BaseInterestAllocator to make sure that the majority of the
///         assets are earning some yield. This BaseInterestAllocator is meant to take a base yield
///         with low risk/high liquidity.
///         Withdrawals happen in two steps. First the users calls `withdraw`/`reedeem` which will give them,
///         an NFT that will represent a fraction of the value of the pool at the moment of the activation
///         of the following `WithdrawalQueue`. When a `WithdrawalQueue` is deployed, it will represent a fraction
///         of the pool's value given by ratio between the total amount of shares pending withdrawal and the total number
///         of shares. The value of the pool is defined by the amount of idle assets, the outstanding value of loans issued
///         after the deployment of the previous WithdrawalQueue, and a fraction of the outstanding value of all loans
///         belonging to previous WithdrawalQueues.
///         Capital available for withdrawal is managed through a claim process to keep the cost of repayments/refinances
///         to a minimum. The burden of it is put on the user deploying the queues as well as claiming later.
contract Pool is ERC4626, InputChecker, IPool, IPoolWithWithdrawalQueues, LoanManager, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPointMathLib for uint128;
    using FixedPointMathLib for uint256;
    using Interest for uint256;
    using SafeTransferLib for ERC20;

    /// @dev Precision used for principal accounting.
    uint80 public constant PRINCIPAL_PRECISION = 1e20;

    uint256 private constant _SECONDS_PER_YEAR = 31536000;

    /// @dev 10000 BPS = 100%
    uint16 private constant _BPS = 10000;

    /// @dev Max bonus for reallocating.
    uint16 private _MAX_BONUS = 500;

    /// @dev Fees accumulated by the vault.
    uint256 public getCollectedFees;

    /// @notice Cached values of outstanding loans for accounting.
    /// @param principalAmount Total outstanding principal
    /// @param accruedInterest Accrued interest so far
    /// @param sumApr SumApr across loans (can't keep blended because of cumulative rounding errors...)
    /// @param lastTs Last time we computed the cache.
    struct OutstandingValues {
        uint128 principalAmount;
        uint128 accruedInterest;
        uint128 sumApr;
        uint128 lastTs;
    }

    /// @param thisQueueFraction Fraction of this queue in `PRINCIPAL_PRECISION`
    /// @param netPoolFraction Fraction that still goes to the pool on repayments/liquidations in bps.
    struct QueueAccounting {
        uint128 thisQueueFraction;
        uint128 netPoolFraction;
    }

    /// @dev Used in case loans might have a liquidation, then the extension is upper bounded by maxDuration + liq time.
    uint256 private constant _LOAN_BUFFER_TIME = 7 days;

    /// @dev Fee Manager handles the fees for the pool. Moved to a separate contract because of contract size.
    address public immutable getFeeManager;
    /// @inheritdoc IPool
    uint256 public immutable getMaxTotalWithdrawalQueues;
    /// @inheritdoc IPool
    uint256 public immutable getMinTimeBetweenWithdrawalQueues;

    /// @notice Bonus for reallocating
    uint256 public getReallocationBonus;

    /// @inheritdoc IPool
    address public getPendingBaseInterestAllocator;
    /// @inheritdoc IPool
    address public getBaseInterestAllocator;
    /// @inheritdoc IPool
    uint256 public getPendingBaseInterestAllocatorSetTime;
    /// @inheritdoc IPool
    bool public isActive;
    /// @notice Optimal Idle Range
    OptimalIdleRange public getOptimalIdleRange;
    /// @notice Last ids for deployed queue per contract
    mapping(uint256 queueIndex => mapping(address loanContract => uint256 loanId)) public getLastLoanId;
    /// @notice Get total received for this queue and future ones.
    mapping(uint256 queueIndex => uint256 totalReceived) public getTotalReceived;
    /// @notice Total capital pending withdrawal
    uint256 public getAvailableToWithdraw;

    /// @notice Array of deployed queues
    DeployedQueue[] private _deployedQueues;
    /// @dev Current cache
    OutstandingValues private _outstandingValues;
    /// @dev Where to deploy the next queue
    uint256 private _pendingQueueIndex;
    /// @notice Outstanding Values for each queue
    OutstandingValues[] private _queueOutstandingValues;
    /// @notice Accounting for each queue
    QueueAccounting[] private _queueAccounting;

    error PoolStatusError();
    error InsufficientAssetsError();
    error AllocationAlreadyOptimalError();
    error CannotDeployQueueTooSoonError();
    error NoSharesPendingWithdrawalError();

    event ReallocationBonusUpdated(uint256 newReallocationBonus);
    event PendingBaseInterestAllocatorSet(address newBaseInterestAllocator);
    event BaseInterestAllocatorSet(address newBaseInterestAllocator);
    event OptimalIdleRangeSet(OptimalIdleRange optimalIdleRange);
    event QueueClaimed(address queue, uint256 amount);
    event Reallocated(uint256 delta, uint256 bonusShares);

    /// @param _feeManager Fee manager contract.
    /// @param _offerHandler Capital handler contract address.
    /// @param _waitingTimeBetweenUpdates Time to wait before setting a new underwriter/base interest allocator.
    /// @param _optimalIdleRange Optimal idle range.
    /// @param _reallocationBonus Bonus for reallocating.
    /// @param _maxTotalWithdrawalQueues Maximum number of withdrawal queues at any given point in time.
    /// @param _asset Asset contract address.
    /// @param _name Pool name.
    /// @param _symbol Pool symbol.
    constructor(
        address _feeManager,
        address _offerHandler,
        uint256 _waitingTimeBetweenUpdates,
        OptimalIdleRange memory _optimalIdleRange,
        uint256 _maxTotalWithdrawalQueues,
        uint256 _reallocationBonus,
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset, _name, _symbol) LoanManager(tx.origin, _offerHandler, _waitingTimeBetweenUpdates) {
        getFeeManager = _feeManager;
        isActive = true;

        /// @dev Base Interest Allocator vars
        _optimalIdleRange.mid = (_optimalIdleRange.min + _optimalIdleRange.max) / 2;
        getOptimalIdleRange = _optimalIdleRange;
        getPendingBaseInterestAllocatorSetTime = type(uint256).max;
        if (_reallocationBonus > _MAX_BONUS) {
            revert InvalidInputError();
        }
        getReallocationBonus = _reallocationBonus;

        /// @dev WithdrawalQueue vars
        getMaxTotalWithdrawalQueues = _maxTotalWithdrawalQueues;
        /// @dev using muldivup to get ceil of the div
        getMinTimeBetweenWithdrawalQueues = (IPoolOfferHandler(_offerHandler).getMaxDuration() + _LOAN_BUFFER_TIME)
            .mulDivUp(1, _maxTotalWithdrawalQueues);
        /// @dev Extra is the next one that is not active yet
        _deployedQueues = new DeployedQueue[](_maxTotalWithdrawalQueues + 1);
        DeployedQueue memory deployedQueue = _deployQueue(_asset);
        /// @dev _pendingQueueIndex = 0
        _deployedQueues[_pendingQueueIndex] = deployedQueue;
        _queueOutstandingValues = new OutstandingValues[](_maxTotalWithdrawalQueues + 1);
        _queueAccounting = new QueueAccounting[](_maxTotalWithdrawalQueues + 1);

        _asset.approve(address(_feeManager), type(uint256).max);
    }

    /// @inheritdoc IPool
    function pausePool() external onlyOwner {
        isActive = !isActive;

        emit PoolPaused(isActive);
    }

    /// @inheritdoc IPool
    function setOptimalIdleRange(OptimalIdleRange memory _optimalIdleRange) external onlyOwner {
        _optimalIdleRange.mid = (_optimalIdleRange.min + _optimalIdleRange.max) / 2;
        getOptimalIdleRange = _optimalIdleRange;

        emit OptimalIdleRangeSet(_optimalIdleRange);
    }

    /// @inheritdoc IPool
    function setBaseInterestAllocator(address _newBaseInterestAllocator) external onlyOwner {
        _checkAddressNotZero(_newBaseInterestAllocator);

        getPendingBaseInterestAllocator = _newBaseInterestAllocator;
        getPendingBaseInterestAllocatorSetTime = block.timestamp;

        emit PendingBaseInterestAllocatorSet(_newBaseInterestAllocator);
    }

    /// @inheritdoc IPool
    function confirmBaseInterestAllocator(address _newBaseInterestAllocator) external {
        address cachedAllocator = getBaseInterestAllocator;
        if (cachedAllocator != address(0)) {
            if (getPendingBaseInterestAllocatorSetTime + UPDATE_WAITING_TIME > block.timestamp) {
                revert TooSoonError();
            }
            if (getPendingBaseInterestAllocator != _newBaseInterestAllocator) {
                revert InvalidInputError();
            }
            IBaseInterestAllocator(cachedAllocator).transferAll();
            asset.approve(cachedAllocator, 0);
        }
        asset.approve(_newBaseInterestAllocator, type(uint256).max);

        getBaseInterestAllocator = _newBaseInterestAllocator;
        getPendingBaseInterestAllocator = address(0);
        getPendingBaseInterestAllocatorSetTime = type(uint256).max;

        emit BaseInterestAllocatorSet(_newBaseInterestAllocator);
    }

    /// @inheritdoc IPool
    function setReallocationBonus(uint256 _newReallocationBonus) external onlyOwner {
        if (_newReallocationBonus > _MAX_BONUS) {
            revert InvalidInputError();
        }
        getReallocationBonus = _newReallocationBonus;

        emit ReallocationBonusUpdated(_newReallocationBonus);
    }

    /// @inheritdoc LoanManager
    function afterCallerAdded(address _caller) internal override onlyOwner {
        asset.approve(_caller, type(uint256).max);
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        return _getUndeployedAssets() + _getTotalOutstandingValue();
    }

    /// @notice Return cached variables to calculate outstanding value.
    /// @return OutstandingValues struct.
    function getOutstandingValues() external view returns (OutstandingValues memory) {
        return _outstandingValues;
    }

    /// @inheritdoc IPoolWithWithdrawalQueues
    function getDeployedQueue(uint256 _idx) external view returns (DeployedQueue memory) {
        return _deployedQueues[_idx];
    }

    /// @notice Return cached variables to calculate outstanding value for queue at index `_idx`.
    /// @param _idx Index of the queue.
    /// @return OutstandingValues struct.
    function getOutstandingValuesForQueue(uint256 _idx) external view returns (OutstandingValues memory) {
        return _queueOutstandingValues[_idx];
    }

    /// @inheritdoc IPoolWithWithdrawalQueues
    function getPendingQueueIndex() external view returns (uint256) {
        return _pendingQueueIndex;
    }

    /// @notice Return cached variables to calculate values a given queue at index `_idx`.
    /// @param _idx Index of the queue.
    /// @return QueueAccounting struct.
    function getAccountingValuesForQueue(uint256 _idx) external view returns (QueueAccounting memory) {
        return _queueAccounting[_idx];
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        _withdraw(owner, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        _withdraw(owner, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _preDeposit();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _preDeposit();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc IPoolWithWithdrawalQueues
    function queueClaimAll() external nonReentrant {
        /// @dev Transfer capital to queues.
        _queueClaimAll(getAvailableToWithdraw, _pendingQueueIndex);
    }

    /// @inheritdoc IPoolWithWithdrawalQueues
    function deployWithdrawalQueue() external nonReentrant {
        /// @dev cache storage var and update
        uint256 pendingQueueIndex = _pendingQueueIndex;
        DeployedQueue memory queue = _deployedQueues[pendingQueueIndex];

        /// @dev Check if we can deploy a new queue.
        if (block.timestamp - queue.deployedTime < getMinTimeBetweenWithdrawalQueues) {
            revert TooSoonError();
        }

        uint256 sharesPendingWithdrawal = WithdrawalQueue(queue.contractAddress).getTotalShares();
        if (sharesPendingWithdrawal == 0) {
            revert NoSharesPendingWithdrawalError();
        }

        uint256 totalQueues = _deployedQueues.length;
        /// @dev It's a circular array so last one is the one after pending.
        uint256 lastQueueIndex = (pendingQueueIndex + 1) % totalQueues;

        /// @dev bring var to mem
        uint256 totalSupplyCached = totalSupply;
        /// @dev Liquid = balance of base asset + base rate asset (eg: WETH / STETH, USDC / aUSDC).
        uint256 proRataLiquid = _getUndeployedAssets().mulDivDown(sharesPendingWithdrawal, totalSupplyCached);
        uint128 poolFraction =
            uint128((totalSupplyCached - sharesPendingWithdrawal).mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached));
        _queueAccounting[pendingQueueIndex] = QueueAccounting(
            uint128(sharesPendingWithdrawal.mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached)), poolFraction
        );

        /// @dev transfer all claims
        _queueClaimAll(proRataLiquid + getAvailableToWithdraw, pendingQueueIndex);
        /// @dev transfer the proRataLiquid to the queue that was pending and is now active.
        asset.safeTransfer(queue.contractAddress, proRataLiquid);

        /// @dev Deploy the next pending queue.
        _deployedQueues[lastQueueIndex] = _deployQueue(asset);

        /// @dev we add totalQueues to avoid an underflow
        uint256 baseIdx = pendingQueueIndex + totalQueues;
        /// @dev Going from newest to oldest, from right to left (on a circular array).
        /// Newest is the one we just deployed at pendingQueueIndex. The queue that has just been
        /// activate represents a fraction of the current pool. The value for each queue that should
        /// go back to the pool is updated accordingly.
        for (uint256 i = 1; i < totalQueues - 1;) {
            uint256 idx = (baseIdx - i) % totalQueues;
            if (_deployedQueues[idx].contractAddress == address(0)) {
                break;
            }
            QueueAccounting memory thisQueueAccounting = _queueAccounting[idx];
            uint128 newQueueFraction =
                uint128(thisQueueAccounting.netPoolFraction.mulDivDown(sharesPendingWithdrawal, totalSupplyCached));
            _queueAccounting[idx].netPoolFraction -= newQueueFraction;

            unchecked {
                ++i;
            }
        }

        /// @dev We move outstaning values from the pool to the queue that was just deployed.
        _queueOutstandingValues[pendingQueueIndex] = _outstandingValues;
        /// @dev We clear values of the new pending queue.
        delete _queueOutstandingValues[lastQueueIndex];
        delete _outstandingValues;

        _updateLoanLastIds();

        _pendingQueueIndex = lastQueueIndex;

        // Cannot underflow because the sum of all withdrawals is never larger than totalSupply.
        unchecked {
            totalSupply -= sharesPendingWithdrawal;
        }
    }

    /// @inheritdoc LoanManager
    function validateOffer(bytes calldata _offer, uint256 _protocolFee) external override onlyAcceptedCallers {
        if (!isActive) {
            revert PoolStatusError();
        }
        uint256 currentBalance = asset.balanceOf(address(this)) - getAvailableToWithdraw;
        uint256 baseRateBalance = IBaseInterestAllocator(getBaseInterestAllocator).getAssetsAllocated();
        uint256 undeployedAssets = currentBalance + baseRateBalance;
        (uint256 principalAmount, uint256 apr) = IPoolOfferHandler(getUnderwriter).validateOffer(
            IBaseInterestAllocator(getBaseInterestAllocator).getBaseAprWithUpdate(), _offer
        );

        /// @dev Since the balance of the pool includes capital that is waiting to be claimed by the queues,
        ///      we need to check if the pool has enough capital to fund the loan.
        ///      If that's not the case, and the principal is larger than the currentBalance, the we need to reallocate
        ///      part of it.
        if (principalAmount > undeployedAssets) {
            revert InsufficientAssetsError();
        } else if (principalAmount > currentBalance) {
            IBaseInterestAllocator(getBaseInterestAllocator).reallocate(
                currentBalance, principalAmount - currentBalance, true
            );
        }
        /// @dev If the txn doesn't revert, we can assume the loan was executed.
        _outstandingValues = _getNewLoanAccounting(principalAmount, _netApr(apr, _protocolFee));
    }

    /// @inheritdoc IPool
    function reallocate() external nonReentrant returns (uint256) {
        (uint256 currentBalance, uint256 targetIdle) = _reallocate();
        uint256 delta = currentBalance > targetIdle ? currentBalance - targetIdle : targetIdle - currentBalance;
        uint256 shares = delta.mulDivDown(totalSupply * getReallocationBonus, totalAssets() * _BPS);

        _mint(msg.sender, shares);

        emit Reallocated(delta, shares);

        return shares;
    }

    /// @inheritdoc LoanManager
    function loanRepayment(
        uint256 _loanId,
        uint256 _principalAmount,
        uint256 _apr,
        uint256,
        uint256 _protocolFee,
        uint256 _startTime
    ) external override onlyAcceptedCallers {
        uint256 netApr = _netApr(_apr, _protocolFee);
        uint256 interestEarned = _principalAmount.getInterest(netApr, block.timestamp - _startTime);
        uint256 received = _principalAmount + interestEarned;
        uint256 fees = IFeeManager(getFeeManager).processFees(_principalAmount, interestEarned);
        getCollectedFees += fees;
        _loanTermination(msg.sender, _loanId, _principalAmount, netApr, interestEarned, received - fees);
    }

    /// @inheritdoc LoanManager
    function loanLiquidation(
        uint256 _loanId,
        uint256 _principalAmount,
        uint256 _apr,
        uint256,
        uint256 _protocolFee,
        uint256 _received,
        uint256 _startTime
    ) external override onlyAcceptedCallers {
        uint256 netApr = _netApr(_apr, _protocolFee);
        uint256 interestEarned = _principalAmount.getInterest(netApr, block.timestamp - _startTime);
        uint256 fees = IFeeManager(getFeeManager).processFees(_received, 0);
        getCollectedFees += fees;
        _loanTermination(msg.sender, _loanId, _principalAmount, netApr, interestEarned, _received - fees);
    }

    /// @dev Get the total outstanding value for the pool. Loans that were issued after the last
    ///      queue belong 100% to the pool. Loans for any given queue contribute a fraction equal to `netPoolFraction`
    ///      for each given queue.
    function _getTotalOutstandingValue() private view returns (uint256) {
        uint256 totalOutstandingValue = _getOutstandingValue(_outstandingValues);
        uint256 totalQueues = _queueOutstandingValues.length;
        uint256 newest = (_pendingQueueIndex + totalQueues - 1) % totalQueues;
        for (uint256 i; i < totalQueues - 1;) {
            uint256 idx = (newest + totalQueues - i) % totalQueues;
            OutstandingValues memory queueOutstandingValues = _queueOutstandingValues[idx];

            totalOutstandingValue += _getOutstandingValue(queueOutstandingValues).mulDivDown(
                _queueAccounting[idx].netPoolFraction, PRINCIPAL_PRECISION
            );
            unchecked {
                ++i;
            }
        }
        return totalOutstandingValue;
    }

    /// @dev It assumes all loans will be repaid so the value so each one is given by principal + accrued interest.
    function _getOutstandingValue(OutstandingValues memory __outstandingValues) private view returns (uint256) {
        uint256 principal = uint256(__outstandingValues.principalAmount);
        return principal + uint256(__outstandingValues.accruedInterest)
            + principal.getInterest(
                uint256(_outstandingApr(__outstandingValues)), block.timestamp - uint256(__outstandingValues.lastTs)
            );
    }

    /// @dev Update the outstanding values when a loan is initiated.
    /// @param _principalAmount Principal amount of the loan.
    /// @param _apr APR of the loan.
    function _getNewLoanAccounting(uint256 _principalAmount, uint256 _apr)
        private
        view
        returns (OutstandingValues memory outstandingValues)
    {
        outstandingValues = _outstandingValues;
        outstandingValues.accruedInterest += uint128(
            uint256(outstandingValues.principalAmount).getInterest(
                uint256(_outstandingApr(outstandingValues)), block.timestamp - uint256(outstandingValues.lastTs)
            )
        );
        outstandingValues.sumApr += uint128(_apr * _principalAmount);
        outstandingValues.principalAmount += uint128(_principalAmount);
        outstandingValues.lastTs = uint128(block.timestamp);
    }

    /// @dev If the loan was issued after the last queue, it belongs 100% to the pool and it updates `_outstandingValues`.
    ///     Otherwise, it updates the queue accounting and the queue outstanding values & `getTotalReceived & getAvailableToWithdraw`.
    function _loanTermination(
        address _loanContract,
        uint256 _loanId,
        uint256 _principalAmount,
        uint256 _apr,
        uint256 _interestEarned,
        uint256 _received
    ) private {
        uint256 pendingIndex = _pendingQueueIndex;
        uint256 totalQueues = getMaxTotalWithdrawalQueues + 1;
        uint256 idx;
        /// @dev oldest queue is the one after pendingIndex
        uint256 i;
        for (i = 1; i < totalQueues;) {
            idx = (pendingIndex + i) % totalQueues;
            if (getLastLoanId[idx][_loanContract] >= _loanId) {
                break;
            }
            unchecked {
                ++i;
            }
        }
        /// @dev We iterated through all queues and never broke, meaning it was issued after the newest one.
        if (i == totalQueues) {
            _outstandingValues =
                _updateOutstandingValuesOnTermination(_outstandingValues, _principalAmount, _apr, _interestEarned);
            return;
        } else {
            uint256 pendingToQueue =
                _received.mulDivDown(PRINCIPAL_PRECISION - _queueAccounting[idx].netPoolFraction, PRINCIPAL_PRECISION);
            getTotalReceived[idx] += _received;
            getAvailableToWithdraw += pendingToQueue;
            _queueOutstandingValues[idx] = _updateOutstandingValuesOnTermination(
                _queueOutstandingValues[idx], _principalAmount, _apr, _interestEarned
            );
        }
    }

    /// @dev Checks before a deposit/mint.
    function _preDeposit() private view {
        if (!isActive) {
            revert PoolStatusError();
        }
    }

    /// We subtract aviailable to withdraw since this corresponds to the fraction of loans repaid that are for previous
    /// queues.
    function _getUndeployedAssets() private view returns (uint256) {
        return asset.balanceOf(address(this)) + IBaseInterestAllocator(getBaseInterestAllocator).getAssetsAllocated()
            - getAvailableToWithdraw - getCollectedFees;
    }

    /// @dev Check if the current amount of assets allocated to the base rate is outside of the optimal range. If so,
    ///      call the allocator.
    function _reallocate() private returns (uint256, uint256) {
        /// @dev Balance that is idle and belongs to the pool (not waiting to be claimed)
        uint256 currentBalance = asset.balanceOf(address(this)) - getAvailableToWithdraw;
        if (currentBalance == 0) {
            revert AllocationAlreadyOptimalError();
        }
        uint256 baseRateBalance = IBaseInterestAllocator(getBaseInterestAllocator).getAssetsAllocated();
        uint256 total = currentBalance + baseRateBalance;
        uint256 fraction = currentBalance.mulDivDown(PRINCIPAL_PRECISION, total);
        /// @dev bring to memory
        OptimalIdleRange memory optimalIdleRange = getOptimalIdleRange;
        if (fraction >= optimalIdleRange.min && fraction < optimalIdleRange.max) {
            revert AllocationAlreadyOptimalError();
        }
        uint256 targetIdle = total.mulDivDown(optimalIdleRange.mid, PRINCIPAL_PRECISION);
        IBaseInterestAllocator(getBaseInterestAllocator).reallocate(currentBalance, targetIdle, false);
        return (currentBalance, targetIdle);
    }

    /// @dev Check if the amount of assets liquid are enough to fulfill withdrawals. If not reallocate and leave
    ///      at optimal.
    function _reallocateOnWithdrawal(uint256 _withdrawn) private {
        /// @dev getAvailableToWithdraw is 0.
        uint256 currentBalance = asset.balanceOf(address(this));
        if (currentBalance > _withdrawn) {
            return;
        }
        uint256 baseRateBalance = IBaseInterestAllocator(getBaseInterestAllocator).getAssetsAllocated();
        uint256 finalBalance = currentBalance + baseRateBalance - _withdrawn;
        uint256 targetIdle = finalBalance.mulDivDown(getOptimalIdleRange.mid, PRINCIPAL_PRECISION);
        IBaseInterestAllocator(getBaseInterestAllocator).reallocate(currentBalance, _withdrawn + targetIdle, true);
    }

    /// @dev Calculate the net APR after the protocol fee.
    function _netApr(uint256 _apr, uint256 _protocolFee) private pure returns (uint256) {
        return _apr.mulDivDown(_BPS - _protocolFee, _BPS);
    }

    /// @dev Deploy a new queue
    function _deployQueue(ERC20 _asset) private returns (DeployedQueue memory) {
        address deployed = address(new WithdrawalQueue(_asset));

        return DeployedQueue(deployed, uint96(block.timestamp));
    }

    /// @dev Override method since we don't want to change the `totalSupply`
    function _burn(address from, uint256 amount) internal override {
        /// @dev We don't subtract the totalSupply yet since it's used for accounting purposes.
        /// Capital is not really withdrawn proportionally until the new queue is deployed.
        balanceOf[from] -= amount;

        emit Transfer(from, address(0), amount);
    }

    /// @dev Update loan ids for the queue that is about to be deployed for each loan contract.
    ///      We need these values to know which loans belong to the queue. IDs are serial.
    function _updateLoanLastIds() private {
        for (uint256 i; i < _acceptedCallers.length();) {
            address caller = _acceptedCallers.at(i);
            if (_isLoanContract[caller]) {
                getLastLoanId[_pendingQueueIndex][caller] = IBaseLoan(caller).getTotalLoansIssued();
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Given an array, it updates the pending withdrawal for each queue.
    /// @param _idx Index of the queue that we are getting the values for.
    /// @param _cachedPendingQueueIndex Index of the pending queue.
    /// @param _pendingWithdrawal Array of pending withdrawals.
    /// @return Updated array of pending withdrawals.
    function _updatePendingWithdrawalWithQueue(
        uint256 _idx,
        uint256 _cachedPendingQueueIndex,
        uint256[] memory _pendingWithdrawal
    ) private returns (uint256[] memory) {
        uint256 totalReceived = getTotalReceived[_idx];
        uint256 totalQueues = getMaxTotalWithdrawalQueues + 1;
        /// @dev Nothing to be returned
        if (totalReceived == 0) {
            return _pendingWithdrawal;
        }
        getTotalReceived[_idx] = 0;

        /// @dev We go from idx to newer queues. Each getTotalReceived is the total
        /// returned from loans for that queue. All future queues/pool also have a piece of it.
        /// X_i: Total received for queue `i`
        /// X_1  = Received * shares_1 / totalShares_1
        /// X_2 = (Received - (X_1)) * shares_2 / totalShares_2 ...
        /// Remainder goes to the pool.
        for (uint256 i; i < totalQueues;) {
            uint256 secondIdx = (_idx + i) % totalQueues;
            QueueAccounting memory queueAccounting = _queueAccounting[secondIdx];
            if (queueAccounting.thisQueueFraction == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            /// @dev We looped around.
            if (secondIdx == _cachedPendingQueueIndex + 1) {
                break;
            }
            uint256 pendingForQueue = totalReceived.mulDivDown(queueAccounting.thisQueueFraction, PRINCIPAL_PRECISION);
            totalReceived -= pendingForQueue;

            _pendingWithdrawal[secondIdx] = pendingForQueue;
            unchecked {
                ++i;
            }
        }
        return _pendingWithdrawal;
    }

    /// @dev Claim all pending withdrawals for each queue.
    function _queueClaimAll(uint256 _totalToBeWithdrawn, uint256 _cachedPendingQueueIndex) private {
        _reallocateOnWithdrawal(_totalToBeWithdrawn);
        uint256 totalQueues = (getMaxTotalWithdrawalQueues + 1);
        uint256 oldestQueueIdx = (_cachedPendingQueueIndex + 1) % totalQueues;
        uint256[] memory pendingWithdrawal = new uint256[](totalQueues);
        for (uint256 i; i < pendingWithdrawal.length;) {
            uint256 idx = (oldestQueueIdx + i) % totalQueues;
            _updatePendingWithdrawalWithQueue(idx, _cachedPendingQueueIndex, pendingWithdrawal);
            unchecked {
                ++i;
            }
        }
        getAvailableToWithdraw = 0;

        for (uint256 i; i < pendingWithdrawal.length;) {
            if (pendingWithdrawal[i] == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address queueAddr = _deployedQueues[i].contractAddress;
            uint256 amount = pendingWithdrawal[i];

            asset.safeTransfer(queueAddr, amount);
            emit QueueClaimed(queueAddr, amount);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Calculate the outstanding APR for a given set of values.
    function _outstandingApr(OutstandingValues memory __outstandingValues) private pure returns (uint128) {
        if (__outstandingValues.principalAmount == 0) {
            return 0;
        }
        return __outstandingValues.sumApr / __outstandingValues.principalAmount;
    }

    /// @dev Update the outstanding values when a loan is terminated (either repaid or liquidated)
    /// @param __outstandingValues Cached values of outstanding loans for accounting.
    /// @param _principalAmount Principal amount of the loan.
    /// @param _apr APR of the loan.
    /// @param _interestEarned Interest earned from the loan.
    /// @return Updated OutstandingValues struct.
    function _updateOutstandingValuesOnTermination(
        OutstandingValues memory __outstandingValues,
        uint256 _principalAmount,
        uint256 _apr,
        uint256 _interestEarned
    ) private view returns (OutstandingValues memory) {
        /// @dev Manually get interest here because of rounding.
        uint256 newlyAccrued = uint256(__outstandingValues.sumApr).mulDivUp(
            block.timestamp - uint256(__outstandingValues.lastTs), _SECONDS_PER_YEAR * _BPS
        );
        uint256 total = __outstandingValues.accruedInterest + newlyAccrued;

        /// @dev we might be off by a small amount here because of rounding issues.
        if (total < _interestEarned) {
            __outstandingValues.accruedInterest = 0;
        } else {
            __outstandingValues.accruedInterest = uint128(total - _interestEarned);
        }
        __outstandingValues.sumApr -= uint128(_apr * _principalAmount);
        __outstandingValues.principalAmount -= uint128(_principalAmount);
        __outstandingValues.lastTs = uint128(block.timestamp);
        return __outstandingValues;
    }

    function _withdraw(address owner, address receiver, uint256 assets, uint256 shares) private {
        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        WithdrawalQueue(_deployedQueues[_pendingQueueIndex].contractAddress).mint(receiver, shares);
    }
}
