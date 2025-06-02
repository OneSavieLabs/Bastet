// SPDX-License-Identifier: None
pragma solidity ^0.8.19;

import '../common/library/InitErrors.sol';
import '../common/library/UncheckedIncrement.sol';
import {IPosManager} from '../interfaces/core/IPosManager.sol';
import {ILendingPool} from '../interfaces/lending_pool/ILendingPool.sol';
import {IBaseWrapLp} from '../interfaces/wrapper/IBaseWrapLp.sol';
import {IERC20} from '@openzeppelin-contracts/token/ERC20/IERC20.sol';
import {SafeCast} from '@openzeppelin-contracts/utils/math/SafeCast.sol';
import {SafeERC20} from '@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol';
import {ERC721EnumerableUpgradeable} from
    '@openzeppelin-contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol';
import {ERC721HolderUpgradeable} from
    '@openzeppelin-contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol';
import {EnumerableSet} from '@openzeppelin-contracts/utils/structs/EnumerableSet.sol';
import {UnderACM} from '../common/UnderACM.sol';

contract PosManager is IPosManager, UnderACM, ERC721EnumerableUpgradeable, ERC721HolderUpgradeable {
    using SafeCast for uint;
    using SafeCast for int;
    using UncheckedIncrement for uint;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // constants
    bytes32 private constant GUARDIAN = keccak256('guardian');

    // storages
    mapping(address => uint) public nextNonces; // @inheritdoc IPosManager
    mapping(uint => PosInfo) private __posInfos;
    mapping(uint => PosCollInfo) private __posCollInfos;
    mapping(uint => PosBorrInfo) private __posBorrInfos;
    mapping(address => uint) private __collBalances;
    address public core;
    uint8 public maxCollCount; // limit number of collateral to avoid out of gas
    mapping(uint => mapping(address => uint)) public pendingRewards; // @inheritdoc IPosManager
    mapping(address => mapping(uint => bool)) public isCollateralized; // @inheritdoc IPosManager
    mapping(address => EnumerableSet.UintSet) private __viewerPosIds;

    // modifiers
    modifier onlyGuardian() {
        ACM.checkRole(GUARDIAN, msg.sender);
        _;
    }

    modifier onlyCore() {
        _require(msg.sender == core, Errors.NOT_INIT_CORE);
        _;
    }

    modifier onlyAuthorized(uint _posId) {
        _require(_isApprovedOrOwner(msg.sender, _posId), Errors.NOT_AUTHORIZED);
        _;
    }

    // constructor
    constructor(address _acm) UnderACM(_acm) {
        _disableInitializers();
    }

    // initializer
    /// @dev initialize the contract, set the ERC721's name and symbol, and set the init core address
    /// @param _name ERC721's name
    /// @param _symbol ERC721's symbol
    /// @param _core core address
    function initialize(string calldata _name, string calldata _symbol, address _core, uint8 _maxCollCount)
        external
        initializer
    {
        __ERC721_init(_name, _symbol);
        core = _core;
        maxCollCount = _maxCollCount;
        emit SetMaxCollCount(_maxCollCount);
    }

    // functions
    /// @inheritdoc IPosManager
    function getPosBorrInfo(uint _posId) external view returns (address[] memory pools, uint[] memory debtShares) {
        PosBorrInfo storage posBorrInfo = __posBorrInfos[_posId];
        pools = posBorrInfo.pools.values();
        debtShares = new uint[](pools.length);
        for (uint i; i < pools.length; i = i.uinc()) {
            debtShares[i] = posBorrInfo.debtShares[pools[i]];
        }
    }

    /// @inheritdoc IPosManager
    function getPosBorrExtraInfo(uint _posId, address _pool)
        external
        view
        returns (uint totalInterest, uint lastDebtAmt)
    {
        PosBorrExtraInfo memory borrExtraInfo = __posBorrInfos[_posId].borrExtraInfos[_pool];
        totalInterest = borrExtraInfo.totalInterest;
        lastDebtAmt = borrExtraInfo.lastDebtAmt;
    }

    /// @inheritdoc IPosManager
    function getPosCollInfo(uint _posId)
        external
        view
        returns (
            address[] memory pools,
            uint[] memory amts,
            address[] memory wLps,
            uint[][] memory ids,
            uint[][] memory wLpAmts
        )
    {
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        pools = posCollInfo.collTokens.values();
        amts = new uint[](pools.length);
        for (uint i; i < pools.length; i = i.uinc()) {
            amts[i] = posCollInfo.collAmts[pools[i]];
        }
        wLps = posCollInfo.wLps.values();
        ids = new uint[][](wLps.length);
        wLpAmts = new uint[][](wLps.length);
        for (uint i; i < wLps.length; i = i.uinc()) {
            ids[i] = posCollInfo.ids[wLps[i]].values();
            wLpAmts[i] = new uint[](ids[i].length);
            for (uint j; j < ids[i].length; j = j.uinc()) {
                wLpAmts[i][j] = IBaseWrapLp(wLps[i]).balanceOfLp(ids[i][j]);
            }
        }
    }

    /// @inheritdoc IPosManager
    function getCollAmt(uint _posId, address _pool) external view returns (uint amt) {
        amt = __posCollInfos[_posId].collAmts[_pool];
    }

    /// @inheritdoc IPosManager
    function getCollWLpAmt(uint _posId, address _wLp, uint _tokenId) external view returns (uint amt) {
        if (__posCollInfos[_posId].ids[_wLp].contains(_tokenId)) {
            amt = IBaseWrapLp(_wLp).balanceOfLp(_tokenId);
        }
    }

    /// @inheritdoc IPosManager
    function getPosInfo(uint _posId) external view returns (address viewer, uint16 mode) {
        PosInfo memory info = __posInfos[_posId];
        viewer = info.viewer;
        mode = info.mode;
    }

    /// @inheritdoc IPosManager
    function getPosMode(uint _posId) external view returns (uint16 mode) {
        mode = __posInfos[_posId].mode;
    }

    /// @inheritdoc IPosManager
    function getPosDebtShares(uint _posId, address _pool) external view returns (uint debtShares) {
        debtShares = __posBorrInfos[_posId].debtShares[_pool];
    }

    /// @inheritdoc IPosManager
    function getViewerPosIdsAt(address _viewer, uint _index) external view returns (uint posId) {
        posId = __viewerPosIds[_viewer].at(_index);
    }

    /// @inheritdoc IPosManager
    function getViewerPosIdsLength(address _viewer) external view returns (uint length) {
        length = __viewerPosIds[_viewer].length();
    }

    /// @inheritdoc IPosManager
    function updatePosDebtShares(uint _posId, address _pool, int _deltaShares) external onlyCore {
        uint currDebtShares = __posBorrInfos[_posId].debtShares[_pool];
        uint debtAmtCurrent = ILendingPool(_pool).debtShareToAmtCurrent(currDebtShares);
        PosBorrExtraInfo storage extraInfo = __posBorrInfos[_posId].borrExtraInfos[_pool];
        // update interest accrued since last update
        // NOTE: debtAmtCurrent is always >= lastDebtAmt
        extraInfo.totalInterest += (debtAmtCurrent - extraInfo.lastDebtAmt).toUint128();
        uint newDebtShares = (currDebtShares.toInt256() + _deltaShares).toUint256();
        // handle first borrower
        uint newDebtAmt = ILendingPool(_pool).totalDebtShares() > 0
            ? ILendingPool(_pool).debtShareToAmtStored(newDebtShares)
            : newDebtShares;
        __posBorrInfos[_posId].debtShares[_pool] = newDebtShares;
        // snapshot the current debt amount for next interest calculation
        extraInfo.lastDebtAmt = newDebtAmt.toUint128();
        if (newDebtShares > 0) __posBorrInfos[_posId].pools.add(_pool);
        else __posBorrInfos[_posId].pools.remove(_pool);
    }

    /// @inheritdoc IPosManager
    function updatePosMode(uint _posId, uint16 _mode) external onlyCore {
        __posInfos[_posId].mode = _mode;
    }

    /// @inheritdoc IPosManager
    function addCollateral(uint _posId, address _pool) external onlyCore returns (uint amtIn) {
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        uint newBalance = IERC20(_pool).balanceOf(address(this));
        amtIn = newBalance - __collBalances[_pool];
        _require(amtIn != 0, Errors.ZERO_VALUE);
        uint posBalance = posCollInfo.collAmts[_pool];
        if (posBalance == 0) {
            posCollInfo.collTokens.add(_pool);
            uint8 collCount = posCollInfo.collCount + 1;
            // NOTE: to avoid out of gas
            _require(collCount <= maxCollCount, Errors.MAX_COLLATERAL_COUNT_REACHED);
            posCollInfo.collCount = collCount;
        }
        posCollInfo.collAmts[_pool] = posBalance + amtIn;
        __collBalances[_pool] = newBalance;
    }

    /// @inheritdoc IPosManager
    function addCollateralWLp(uint _posId, address _wLp, uint _tokenId) external onlyCore returns (uint amtIn) {
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        _require(IBaseWrapLp(_wLp).ownerOf(_tokenId) == address(this), Errors.NOT_OWNER);
        _require(!isCollateralized[_wLp][_tokenId], Errors.ALREADY_COLLATERALIZED);
        _require(IBaseWrapLp(_wLp).balanceOfLp(_tokenId) != 0, Errors.ZERO_VALUE);
        posCollInfo.wLps.add(_wLp);
        // NOTE: will return true if add new id
        if (posCollInfo.ids[_wLp].add(_tokenId)) {
            uint8 collCount = posCollInfo.collCount + 1;
            _require(collCount <= maxCollCount, Errors.MAX_COLLATERAL_COUNT_REACHED);
            posCollInfo.collCount = collCount;
        }
        isCollateralized[_wLp][_tokenId] = true;
        amtIn = IBaseWrapLp(_wLp).balanceOfLp(_tokenId);
    }

    /// @inheritdoc IPosManager
    function removeCollateralTo(uint _posId, address _pool, uint _shares, address _receiver)
        external
        onlyCore
        returns (uint)
    {
        _require(_shares > 0, Errors.ZERO_VALUE);
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        uint newPosCollAmt = posCollInfo.collAmts[_pool] - _shares;
        if (newPosCollAmt == 0) {
            posCollInfo.collTokens.remove(_pool);
            posCollInfo.collCount -= 1;
        }
        posCollInfo.collAmts[_pool] = newPosCollAmt;
        IERC20(_pool).safeTransfer(_receiver, _shares);
        __collBalances[_pool] = IERC20(_pool).balanceOf(address(this));
        return _shares;
    }

    /// @inheritdoc IPosManager
    function removeCollateralWLpTo(uint _posId, address _wLp, uint _tokenId, uint _amt, address _receiver)
        external
        onlyCore
        returns (uint)
    {
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        // NOTE: balanceOfLp should be 1:1 with amt
        uint newWLpAmt = IBaseWrapLp(_wLp).balanceOfLp(_tokenId) - _amt;
        if (newWLpAmt == 0) {
            _require(posCollInfo.ids[_wLp].remove(_tokenId), Errors.NOT_CONTAIN);
            posCollInfo.collCount -= 1;
            if (posCollInfo.ids[_wLp].length() == 0) {
                posCollInfo.wLps.remove(_wLp);
            }
            isCollateralized[_wLp][_tokenId] = false;
        }
        _harvest(_posId, _wLp, _tokenId);
        IBaseWrapLp(_wLp).unwrap(_tokenId, _amt, _receiver);
        return _amt;
    }

    /// @inheritdoc IPosManager
    function createPos(address _owner, uint16 _mode, address _viewer) external onlyCore returns (uint posId) {
        uint nonce = nextNonces[_owner]++;
        posId = uint(keccak256(abi.encodePacked(_owner, nonce)));
        _updateViewerPosIds(posId, _viewer);
        __posInfos[posId].viewer = _viewer;
        __posInfos[posId].mode = _mode;
        _safeMint(_owner, posId);
    }

    /// @inheritdoc IPosManager
    function harvestTo(uint _posId, address _wlp, uint _tokenId, address _to)
        public
        onlyAuthorized(_posId)
        returns (address[] memory tokens, uint[] memory amts)
    {
        // check that pos hold wlp
        _require(__posCollInfos[_posId].ids[_wlp].contains(_tokenId), Errors.NOT_CONTAIN);
        (tokens, amts) = IBaseWrapLp(_wlp).harvest(_tokenId, _to);
    }

    /// @inheritdoc IPosManager
    function claimPendingRewards(uint _posId, address[] calldata _tokens, address _to)
        external
        onlyAuthorized(_posId)
        returns (uint[] memory amts)
    {
        amts = new uint[](_tokens.length);
        for (uint i; i < _tokens.length; i = i.uinc()) {
            amts[i] = pendingRewards[_posId][_tokens[i]];
            if (amts[i] != 0) {
                pendingRewards[_posId][_tokens[i]] = 0;
                IERC20(_tokens[i]).safeTransfer(_to, amts[i]);
            }
        }
    }

    /// @dev harvest reward tokens and update the pending rewards for the position
    function _harvest(uint _posId, address _wlp, uint _tokenId) internal {
        (address[] memory tokens, uint[] memory amts) = IBaseWrapLp(_wlp).harvest(_tokenId, address(this));
        for (uint i; i < tokens.length; i = i.uinc()) {
            pendingRewards[_posId][tokens[i]] += amts[i];
        }
    }

    /// @inheritdoc IPosManager
    function isAuthorized(address _account, uint _posId) external view returns (bool) {
        return _isApprovedOrOwner(_account, _posId);
    }

    /// @inheritdoc IPosManager
    function setMaxCollCount(uint8 _maxCollCount) external onlyGuardian {
        maxCollCount = _maxCollCount;
        emit SetMaxCollCount(_maxCollCount);
    }

    /// @inheritdoc IPosManager
    function setPosViewer(uint _posId, address _viewer) external onlyAuthorized(_posId) {
        _require(__posInfos[_posId].viewer != _viewer, Errors.ALREADY_SET);
        _updateViewerPosIds(_posId, _viewer);
        __posInfos[_posId].viewer = _viewer;
    }

    /// @dev update position viewer to ids mapping
    function _updateViewerPosIds(uint _posId, address _viewer) internal {
        address oldViewer = __posInfos[_posId].viewer;
        // remove pos id from old viewer
        if (oldViewer != address(0)) __viewerPosIds[oldViewer].remove(_posId);
        // add pos id to new viewer
        __viewerPosIds[_viewer].add(_posId);
    }
}