/**
 *Submitted for verification at BscScan.com on 2024-05-31
*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
interface IERC721 is IERC165 {

    function transferFrom(address from, address to, uint256 tokenId) external;


}
interface IERC20 {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface ISwapRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
    function getAmountsIn(
        uint amountOut,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}
interface IPOOLV3{
    function fee() external view returns(uint24);
}
interface IRouterV3{
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IV3CALC{
    function principal(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 liquidity
    ) external view returns (uint256 amount0, uint256 amount1);
}

interface INonfungiblePositionManager {

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
    external
    payable
    returns (uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
    external
    payable
    returns (
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
    external
    view
    returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
}
interface IWBNB{
    function withdraw(uint wad) external;

}

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () {
        address msgSender = msg.sender; 
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "!owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "new is 0");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract HFH is IERC20, Ownable {

    uint8 private _decimals = 18; 
    uint256 private _totalsupply =21000000 * 10 ** 18; 
    uint256 private _posSupply = 10000000* 10 ** 18;   
    uint256 private _packSupply = 10000000* 10 ** 18;   
    uint256 private _firstLpSupply = 500000* 10 ** 18;   
    uint256 private _cexSupply = 500000* 10 ** 18;   
    uint256 public swapFee = 3;
    uint256 private deadLine; 
    uint256 private openBuyBlock;
    uint256 dayBlock=28800;
    uint256 dayTime = 86400;
    uint256 dayRewards = 5000 ether;
    uint256 subPerStaicAllocPoint = 140;
    uint256 subPerInviteAllocPoint = 60;
    uint256 minStaticAllocPoint = 1400;
    uint256 minInviteAllocPoint = 600;
    uint256 sushiPerBlock;
    uint256 public nextSubBlock;
    uint256 staticTotalSupply;
    uint256 inviteTotalSupply; 
    uint256 totalInvestBNB;
    uint256 totalInvestUser;
    uint256 totalInvestTimes;
    uint256 private totalAllocPoint = 10000;
    uint256 public startBlock; 
    uint256 perInvestValue = 0.1 ether;
    uint256 _tokenId;  

    
    address private factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private router = 0x10ED43C718714eb63d5aA57B78B54704E256024E; 
    address private  wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private  usdt = 0x55d398326f99059fF775485246999027B3197955;
    address private sol = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
    address private routerV3 = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address private solPool = 0x1E4600929Edf7F36B4A7eAc4C7571057D82a246c;
    address private V3Manage = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364; 
    address private v3_position_calc=0x0000005948ABA29CAF3241a34daeD1c52A46Cd57;
    address private constant dead = 0x000000000000000000000000000000000000dEaD;
    address private feeMarketAddress=0x632DeBDa4849289D33c5fF57fa0184ca8276291a;
    address private packAddress = 0x8aBb57ea5aDb85d4a1d97e353710b095B45F5409;
    address private cexPreAddress = 0x7E153C844c59AE166cbC0227F231e3CC32e88D71;
    address private firstAddress = 0x47adc6d41B3851FeBa6a70833d4746f5957eBb48; 
    address private openBuyManage = 0x1B423866eC57cedc72cB4561d838f9A559691FA7;
    address private initPoolManage = 0xBfa3e7667776d720603CF05f4017A656d2CD2171;
    address private perInvestValueManage = 0xb0E653A704721E74548e2D3826EB421369858a68;
    address private solRewardPoolManage = 0x9230A3d95fcB669410b6c73dEfFC38e3Cf3484d1;
    address private dsjFund = 0x868c7F8E6100aF509D391aDbCf4d796BCE495c39;
    address private fund=0xAeeCDFE9866c0fA5a625EEC15686B4857024173E; 
    address private devFund= 0xE73d1b395368AF177c60b4Da8eA5f6E341d0D731;
    address private maxMinCaManage = 0x155bf2e1D3E95c346aCD7399248fF4dF31685549;
    address private maxMinRewardAddress = 0x00000021609F5c4AdB4A1B6388bf49711D60b183;
    address private node = 0x504c7aCA00860aFe18cddCf4349B3a7C4eF9342e;
    address private sosBuyManage = 0xBE2a7B54Fa240a2F62D2558D1BF470542c575578;
    address private sosBuyTo = 0xDE1B102A9Af3A1d61bd2eAA8F363a9d84CEB2e85;
    address private subRewardsManage = 0x5Af1b49A3ee251F25eF59E64983B825ECb6A21AE;
    address private v3SwapManage = 0x7355ef01094eaA4200F440f5dA4feD25fB0127ED;
    address private freeFeeManage = 0xE45dA72c1988EAB7d4b9197B8E0D37A8c15D5459;
    address private V3admin = 0xdA1aA6772dAF5c877463E4e120812869E05471C1;
    address private errorTokenAdmin = 0x58E50588E2318283B52289Ab7a92c622944c5213;
    address public bnbPair;

    struct UserInfo {
        uint256 userDSJ;
        uint256 teamValue;
        uint256 staticAmount; 
        uint256 staticRewardDebt; 
        uint256 inviteAmount; 
        uint256 inviteRewardDebt; 
        uint256 canClaimAmount;
        uint256 claimedValue;
        uint256 totalClaimedValue;
        uint256 totalClaimedBnb;
        uint256 nowPerBuyValue;
        uint256 usePreBuyValue;
        uint256 preBuyValue;
        uint256 lastActionTime;
        address[] line;
    }
    struct PoolInfo {
        uint256 allocPoint; 
        uint256 lastRewardBlock;
        uint256 accSushiPerShare;
    }
    
    mapping(address => UserInfo) private userInfo;
    mapping(address=>address) public userTop; 
    mapping(address=>uint256) public userInviteAddr;    
    mapping(address => uint256) public userTeamAddr; 
    mapping(address => address[]) private userInviteList;   
    mapping(address => uint256) private _balances;  
    mapping(address => mapping(address => uint256)) private _allowances; 
    mapping(address => bool) public freeFeeAddr;
    mapping(address => bool) public solRewardContract;
    mapping(address=>uint256) private totalInvestBnb; 
    mapping(address=>uint256) private totalClaimedHfh; 
    mapping(address=>bool) private isAddDSJ; 
    mapping(address=>mapping(address=>uint256)) private addInviteProof;
    mapping(address => mapping(address=>bool)) public bindState;
    
    uint256[] private inviteProofRate = [20,10,10,5,5,5,5,5,5,5,5,5,5,5,5];
    address[] buyPath;
    address[] allUsers;
    PoolInfo[] private poolInfo;

    bool isInitPool;
    bool inswap;

    string private _name = "HFH";
    string private _symbol = "HFH"; 
    
    constructor(){

        _balances[cexPreAddress] = _cexSupply;
        emit Transfer(address(0), cexPreAddress, _cexSupply);

        _balances[packAddress] = _packSupply;
        emit Transfer(address(0), packAddress, _packSupply);

        _balances[address(this)] = _posSupply+_firstLpSupply;
        emit Transfer(address(0), address(this), _posSupply+_firstLpSupply);

        (address token0, address token1) = sortTokens(wbnb, address(this));
        bnbPair = address(uint160(uint(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5'
        )))));

        _allowances[address(this)][router] = ~uint256(0);
        emit Approval(address(this), router, ~uint256(0));
        deadLine = block.timestamp +31536000;
        buyPath.push(wbnb);
        buyPath.push(address(this));
        freeFeeAddr[initPoolManage] = true;
        userTop[firstAddress] = address(1);
        userInfo[firstAddress].line.push( address(1));
        sushiPerBlock = dayRewards / dayBlock;
    }


    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalsupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender] - amount;
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private{
        require(from != to,"Same");
        require(amount >0 ,"Zero");
        uint256 balance = _balances[from];
        require(balance >= amount, "balance Not Enough");
        _balances[from] = _balances[from] - amount;
        if(inswap){
            _balances[to] +=amount;
            emit Transfer(from, to, amount);
            return;
        }

        if(!isContract(from) && to == address(this)){
            _balances[to] +=amount;
            emit Transfer(from, to, amount);
            harvest(from);
            return;
        }

        uint256 transAmount = amount;
        uint256 swapFeeAmount;
        if( !freeFeeAddr[from] && !freeFeeAddr[to]){
            if(from == bnbPair || to == bnbPair){
                require(isInitPool,'wait init pool');
                if(from == bnbPair){
                    require(openBuyBlock>0,'wait open');
                }
                swapFeeAmount = amount* swapFee/100;
                if(swapFeeAmount>0){
                    _balances[feeMarketAddress] +=swapFeeAmount;
                    emit Transfer(from, feeMarketAddress, swapFeeAmount); 
                }
            }
        }
        transAmount = transAmount - swapFeeAmount;
        _balances[to] +=transAmount;
        emit Transfer(from, to, transAmount);

        bool canInvite = (userTop[from] !=address(0)
            && userTop[to] == address(0)
            && to !=address(1)
            && !isContract(from)
            && !isContract(to)
            && from != to 
        );

        if(canInvite){
            bindState[from][to] = true;
        }

        bool canByInvite = (userTop[from] == address(0)
            && userTop[to] !=address(0)
            && !isContract(from)
            && !isContract(to)
            && from != to
            && bindState[to][from]
        );

        if(canByInvite){
            userTop[from] = to; 
            userInviteAddr[to] ++;
            userInviteList[to].push(from);
            addLine(from,to);
        }
        return;
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'PancakeLibrary: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'PancakeLibrary: ZERO_ADDRESS');
    }

    function addDline()external{
        deadLine = block.timestamp +31536000;
    }


    function pendingSushi(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        if(_pid>1){
            return 0;
        }
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_user];
        if(user.staticAmount == 0 || (user.claimedValue >= (user.inviteAmount *3)) ){
            return 0;
        }
        uint256 accSushiPerShare = pool.accSushiPerShare;
        uint256 lpSupply = staticTotalSupply;
        if(_pid == 1){
            lpSupply = inviteTotalSupply;
        }

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks =block.number - pool.lastRewardBlock;
            uint256 sushiReward = blocks * sushiPerBlock * pool.allocPoint/totalAllocPoint;
            accSushiPerShare = accSushiPerShare+(sushiReward*1e12/lpSupply);
        }

        if(_pid == 0){
            return user.staticAmount*(accSushiPerShare)/(1e12)-(user.staticRewardDebt);
        }else{
            return user.inviteAmount*(accSushiPerShare)/(1e12)-(user.inviteRewardDebt);
        }
    }

    function updatePool(uint256 _pid) private {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = staticTotalSupply;
        if(_pid == 1){
            lpSupply = inviteTotalSupply;
        }

        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 blocks =block.number - pool.lastRewardBlock;
        uint256 sushiReward =blocks *sushiPerBlock *pool.allocPoint / totalAllocPoint;
        pool.accSushiPerShare =  pool.accSushiPerShare + (sushiReward * 1e12 / lpSupply);
        pool.lastRewardBlock = block.number;
    }

    function depositStatic(address _user,uint256 _amount) private {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        updatePool(0);

        if (user.staticAmount > 0) {
            uint256 pending =(user.staticAmount * pool.accSushiPerShare / 1e12) - user.staticRewardDebt;

            user.canClaimAmount += pending;
        }
        staticTotalSupply +=_amount;
        user.staticAmount += _amount;
        user.staticRewardDebt = user.staticAmount * pool.accSushiPerShare / 1e12;
    }

    function depositInvite(address _user,uint256 _amount) private {
        PoolInfo storage pool = poolInfo[1];
        UserInfo storage user = userInfo[_user];
        updatePool(1);

        if (user.inviteAmount > 0 && ((user.staticAmount *3) > user.claimedValue)) {
            uint256 pending =(user.inviteAmount * pool.accSushiPerShare / 1e12) - user.inviteRewardDebt;

            user.canClaimAmount += pending;
        }
        inviteTotalSupply +=_amount;
        user.inviteAmount += _amount;
        user.inviteRewardDebt = user.inviteAmount * pool.accSushiPerShare / 1e12;
    }

    function withdrawStatic(address _user, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        require(user.staticAmount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = (user.staticAmount * pool.accSushiPerShare /1e12) -  user.staticRewardDebt;
        user.canClaimAmount += pending;

        user.staticAmount -= _amount;
        user.staticRewardDebt = user.staticAmount * pool.accSushiPerShare /1e12;
        staticTotalSupply -=_amount;
    }

    function withdrawInvite(address _user, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[1];
        UserInfo storage user = userInfo[_user];
        require(user.inviteAmount >= _amount, "withdraw: not good");
        updatePool(1);
        if((user.staticAmount *3) > user.claimedValue){
            uint256 pending = (user.inviteAmount * pool.accSushiPerShare /1e12) -  user.inviteRewardDebt;
            user.canClaimAmount += pending;
        }
        user.inviteAmount -= _amount;
        user.inviteRewardDebt = user.inviteAmount * pool.accSushiPerShare /1e12;
        inviteTotalSupply -=_amount;
    }

    function massUpdatePools() public {
        updatePool(0);
        updatePool(1);
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function addLine(address _user,address _top) private{
        UserInfo memory _topInfo = userInfo[_top];
        address[] memory topL = _topInfo.line;
        uint256 len = topL.length;
        if(len>100){
            return;
        }
        address[] memory userL = new address[](len+1);
        userL[0] = _top;    
        userTeamAddr[_top] ++;  
        for(uint256 i=0;i<len;i++){
            userL[i+1] = topL[i];
            userTeamAddr[topL[i]]++;    
        }
        UserInfo storage _userInfo = userInfo[_user];
        _userInfo.line = userL;
    }

    function _rwdTansfer(address _from,address _to,uint256 _amount) private{
        _balances[_from] = _balances[_from] - _amount;
        _balances[_to] +=_amount;
        emit Transfer(_from, _to, _amount);
    }

    function openBuy()external{
        require(isInitPool,'wait init pool');
        require(msg.sender == openBuyManage,'M');
        openBuyBlock=block.number;
    }

    function closeBuy()external{
        require(isInitPool,'wait init pool');
        require(msg.sender == openBuyManage,'M');
        openBuyBlock=0;
    }

    function initFristPool() external payable{
        require(!isInitPool,'INIT');
        isInitPool = true;
        require(msg.sender == initPoolManage,'M');
        uint256 _value = msg.value;
        require(_value>0,'LOW');
        uint256 needU = _firstLpSupply*10/100;
        address[] memory _paths = new address[](2);
        _paths[0] = wbnb;
        _paths[1] = usdt;
        uint256[] memory _amtsIns = ISwapRouter(router).getAmountsIn(needU,_paths);
        uint256 needBnbAmt = _amtsIns[0];
        require(_value>=needBnbAmt,'LOW WBNB');
        inswap = true;
        ISwapRouter(router).addLiquidityETH{value:needBnbAmt}(
            address(this),
            _firstLpSupply,
            _firstLpSupply,
            needBnbAmt,
            initPoolManage,
            deadLine
        );
        inswap = false;
        uint256 _ebal = address(this).balance;
        if(_ebal>0){
            payable(msg.sender).transfer(_ebal);
        }
        return;
    }
    
    function setPerInvestValue(uint256 _per) external {
        require(msg.sender == perInvestValueManage);
        require(_per>0.1 ether,'MIN');
        perInvestValue = _per;
    }

    receive() external payable{
        uint256 _amt = msg.value; 
        address _user = msg.sender;
        address _txOrigin = tx.origin;  
        if(_user != _txOrigin){
            return;
        }

        require(startBlock>0,'WAIT Open');
        require(_amt >= perInvestValue,'Min');
        UserInfo storage uInfo = userInfo[_user];
        require(uInfo.line.length>0,'Not Bind'); 

        if (!isAddDSJ[_user]) {
            isAddDSJ[_user] = true;
            userInfo[uInfo.line[0]].userDSJ++;
            totalInvestUser++;
            allUsers.push(_user);
        }
        if(uInfo.staticAmount >0 && (uInfo.claimedValue >=uInfo.staticAmount *3) ){
            require(false,'wait Out');
        }

        addTeamValues(_user,uInfo.line,_amt);

        depositStatic(_user,_amt);

        uint256 _buySolAmt = _amt*28/100;  
        uint256 _fundAmt = _amt*1/100;      
        uint256 _devAmt = _amt*1/100;       
        uint256 _maxMinAmt = _amt*20/100;   
        uint256 _nodeAmt = _amt*10/100;     
        uint256 _sosBuyAmt = _amt*30/100;    


        uInfo.nowPerBuyValue += _amt/100;   
        uInfo.usePreBuyValue += (_amt*10/100);   
        uInfo.preBuyValue += _sosBuyAmt;    
        uInfo.lastActionTime = block.timestamp; 
        totalInvestBnb[_user] +=_amt;    
        totalInvestBNB +=_amt;
        totalInvestTimes++;
        _buyAndBurn(_amt*10/100,false);


        _buySolana(_buySolAmt);

        payable(fund).transfer(_fundAmt);  
        payable(devFund).transfer(_devAmt);   
        payable(maxMinRewardAddress).transfer(_maxMinAmt);
        payable(node).transfer(_nodeAmt);  

        _sendInviteBnbRewards(uInfo.line,_amt); 

        uint256 _balb = address(this).balance;
        if(_balb>0){
            _sendV3Pool(_balb);
        }

        if(_balances[address(this)]>1e14){
            _rwdTansfer(address(this),_user,1e14);
        }
        return;
    }

    function harvest(address user) private{
        address _user = user;
        address  _txOrigin= tx.origin;
        if(_user != _txOrigin){
            return;
        }
        harvestStaticReward(_user);
        harvestInviteReward(_user); 

        UserInfo storage uInfo = userInfo[_user];

        if(uInfo.staticAmount == 0 ){ 
            return;
        }


        uint256 _days = (block.timestamp - uInfo.lastActionTime) / dayTime; 
        if(_days >0 && uInfo.preBuyValue> uInfo.usePreBuyValue){
            uint256 _preBuyAmt = uInfo.nowPerBuyValue * _days;
            uint256 _canBuyAmt = uInfo.preBuyValue - uInfo.usePreBuyValue;
            if(_preBuyAmt>_canBuyAmt){
                _preBuyAmt = _canBuyAmt;
            }
            uInfo.usePreBuyValue += _preBuyAmt;
            _buyAndBurn(_preBuyAmt,true);
        }
        
        uint256 _canClaimAmount = uInfo.canClaimAmount; 
        uint256 _maxCanClaimValue = uInfo.staticAmount * 3;
        uint256 _claimedValue = uInfo.claimedValue;
        if(_maxCanClaimValue>_claimedValue){

            uint256  _canRwdValue = _maxCanClaimValue - _claimedValue;
            uint256 _pendingValue = _toBnbValue(_canClaimAmount); 
            if(_canRwdValue > _pendingValue){

                    uInfo.claimedValue += _pendingValue; 
                    totalClaimedHfh[_user] += _canClaimAmount;
                    uInfo.totalClaimedValue += _pendingValue; 
                    _rwdTansfer(address(this), _user, _canClaimAmount);  
                    uInfo.canClaimAmount = 0;            
            }else{

                uint256 _rwdHfhAmt = _toHfhAmt(_canRwdValue);
                uInfo.claimedValue += _canRwdValue;
                totalClaimedHfh[_user] += _rwdHfhAmt;
                uInfo.totalClaimedValue += _canRwdValue;
                _rwdTansfer(address(this), _user, _rwdHfhAmt);
                uInfo.canClaimAmount = 0;

                _userOut(_user,uInfo.staticAmount);
            }
        }else{

            _userOut(_user,uInfo.staticAmount);
        }
        return;
    }


    function _userOut(address user,uint256 amount) private{
        UserInfo storage uInfo = userInfo[user];

        subTeamProof(user,uInfo.line,amount);

        withdrawStatic(user, amount);

        uInfo.staticAmount = 0;
        uInfo.canClaimAmount=0;
        uInfo.claimedValue=0;
        uInfo.nowPerBuyValue=0;
        uInfo.usePreBuyValue=0;
        uInfo.usePreBuyValue=0;
        uInfo.preBuyValue=0;
        uInfo.lastActionTime=0;
    }



    function subTeamProof(address _user,address[] memory _uline, uint256 _amt) private {
        for (uint256 i = 0; i < _uline.length; i++) {
            UserInfo storage linfo = userInfo[_uline[i]];

            if (i < 15) {
                uint256 zg = linfo.userDSJ; 
                uint256 _iValue =_amt* inviteProofRate[i] /100; 
                if (zg >= (i + 1)) {
                    uint256 oldAdd = addInviteProof[_user][_uline[i]];
                    if(oldAdd>0){
                        if(_iValue>oldAdd){
                            _iValue = oldAdd;
                        }
                        addInviteProof[_user][_uline[i]] -= _iValue;
                        withdrawInvite(_uline[i], _iValue);
                    }
                }
            }
        }
    }


    function harvestStaticReward(address _user)private{
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        updatePool(0);

        if (user.staticAmount > 0) {
            uint256 pending =(user.staticAmount * pool.accSushiPerShare / 1e12) - user.staticRewardDebt;

            user.canClaimAmount += pending;
        }
        user.staticRewardDebt = user.staticAmount * pool.accSushiPerShare / 1e12;

    } 


    function harvestInviteReward(address _user)private{
        PoolInfo storage pool = poolInfo[1];
        UserInfo storage user = userInfo[_user];
        updatePool(1);

        if (user.inviteAmount > 0 && user.staticAmount > 0) {   
            uint256 pending =(user.inviteAmount * pool.accSushiPerShare / 1e12) - user.inviteRewardDebt;

            user.canClaimAmount += pending;
        }
        user.inviteRewardDebt = user.inviteAmount * pool.accSushiPerShare / 1e12;

    } 

    function addTeamValues(address _user,address[] memory _uline, uint256 _amt) private {
        for (uint256 i = 0; i < _uline.length; i++) {
            UserInfo storage uLine = userInfo[_uline[i]];
            uLine.teamValue += _amt;


            if (i < 15) {
                uint256 zg = uLine.userDSJ; 
                uint256 _iValue =_amt* inviteProofRate[i] /100; 
                if (zg >= (i + 1) && uLine.staticAmount>0) {
                    addInviteProof[_user][_uline[i]] += _iValue;
                    depositInvite(_uline[i],_iValue);
                }
            }
        }
    }
    function _sendInviteBnbRewards(address[] memory lines, uint256 _baseAmt) private{
        uint256 maxShareFee = 10;   
        uint256 useShareFee;
        uint256 useValue;
        for(uint256 i=0;i<lines.length;i++){
            UserInfo storage linfo = userInfo[lines[i]];
            uint256 _investBnb = linfo.staticAmount;   
            uint256 _claimValue = linfo.claimedValue;  
            bool canRwd = (_investBnb * 3) > _claimValue; 
            uint256 _dsjAmt = _baseAmt * 2 /100; 
            if (i < 5) {
                uint256 zg = linfo.userDSJ; 
                if ((zg >= (i + 1)) && canRwd &&( maxShareFee>useShareFee)) {
                    uint256 _rwdAmt = (_investBnb * 3) - _claimValue; 
                    if(_rwdAmt >= _dsjAmt){
                        linfo.claimedValue += _dsjAmt;
                        linfo.totalClaimedBnb += _dsjAmt;
                        linfo.totalClaimedValue +=_dsjAmt;
                        useShareFee += 2;
                        useValue += _dsjAmt;
                        payable(lines[i]).transfer(_dsjAmt);
                    }else{
                        uint256 _fRwdAmt =  _dsjAmt - _rwdAmt;
                        linfo.claimedValue += _rwdAmt;
                        linfo.totalClaimedBnb += _rwdAmt;
                        linfo.totalClaimedValue +=_rwdAmt;
                        useShareFee += 2; 
                        useValue += _dsjAmt;       
                        payable(lines[i]).transfer(_rwdAmt);
                        payable(dsjFund).transfer(_fRwdAmt);
                        linfo.canClaimAmount = 0;
                    }
                }
            }
        }

        if(maxShareFee>useShareFee){
            uint256 _cdAmt = _baseAmt *(maxShareFee - useShareFee) / 100;
            payable(dsjFund).transfer(_cdAmt);
        }
    }

    function _buyAndBurn(uint256 _bnbAmt,bool _dayBuy) private {
        if(_dayBuy){
            _claimV3Pool(_bnbAmt);
        }
        if(_bnbAmt>address(this).balance){
            return;
        }
        inswap=true;
        ISwapRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value:_bnbAmt}(0, buyPath, dead, deadLine);
        inswap=false;
    }

    function _toBnbValue(uint256 _hfhAmt) private view returns(uint256){
        uint256[] memory _in = ISwapRouter(router).getAmountsIn(_hfhAmt, buyPath);
        return _in[0];
    }

    function _toHfhAmt(uint256 _bnbAmt) private view returns(uint256){
        uint256[] memory _out = ISwapRouter(router).getAmountsOut(_bnbAmt, buyPath);
        return _out[1];
    }

    function _buySolana(uint256 _bnbAmt) private {
        if(solPool == address(0)){
            payable(v3SwapManage).transfer(_bnbAmt);
            return;
        }
        uint24 _fee = IPOOLV3(solPool).fee();
        IRouterV3.ExactInputSingleParams memory params = IRouterV3.ExactInputSingleParams({
            tokenIn:wbnb,
            tokenOut:sol,
            fee:_fee,
            recipient:address(this),
            deadline:block.timestamp+1000,
            amountIn:_bnbAmt,
            amountOutMinimum:0,
            sqrtPriceLimitX96:0
        });
        uint256 _solAmt = IRouterV3(routerV3).exactInputSingle{value:_bnbAmt}(params);
        require(_solAmt>0,'Low');
    }

    function _sendV3Pool(uint256 _bnbAmt) private {
        (uint128 lpAmount,,uint256 amount1) = INonfungiblePositionManager(V3Manage).increaseLiquidity{value: _bnbAmt}(INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId:_tokenId,
            amount0Desired:0,
            amount1Desired:_bnbAmt,
            amount0Min:0,
            amount1Min:_bnbAmt,
            deadline:block.timestamp+1000
        }));
        require(lpAmount>0 && amount1 == _bnbAmt,'DepositV3 Error');
    }

    function _claimV3Pool(uint256 _bnbAmt) private {
                (,,,,,int24 tickLower,int24 tickUpper,uint128 liquidity,,,,) = INonfungiblePositionManager(V3Manage).positions(_tokenId);

        (,uint256 amountBNB) = IV3CALC(v3_position_calc).principal(tickLower,tickUpper,liquidity);

        require(amountBNB >= _bnbAmt,'LOW BNB');
        require(liquidity>0,'Position Low');

        uint256 calcRes = _bnbAmt * liquidity / amountBNB;
        uint128 deLpAmunt = uint128(calcRes)+1;
        if(deLpAmunt>liquidity){
            deLpAmunt = liquidity;
        }
        (,uint256 amount1) = INonfungiblePositionManager(V3Manage).decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
             tokenId:_tokenId,
             liquidity:deLpAmunt,
             amount0Min:0,
             amount1Min:0,
             deadline:block.timestamp+1000
        }));
        require(amount1>0,'Position LOW BNB');
        INonfungiblePositionManager(V3Manage).collect(INonfungiblePositionManager.CollectParams({
            tokenId:_tokenId,
            recipient:address(this),
            amount0Max:340282366920938463463374607431768211455,
            amount1Max:340282366920938463463374607431768211455
        }));
        uint256 _wbal = IERC20(wbnb).balanceOf(address(this));
        if(_wbal>_bnbAmt){
            _wbal = _bnbAmt;
        }
        IWBNB(wbnb).withdraw(_wbal);
    }

    function setSolV3Pool(address _ca) external {
        require(msg.sender == v3SwapManage,'M');
        solPool = _ca;
    }

    function setSolRewardContract(address _ca,bool _state) external {
        require(msg.sender == solRewardPoolManage,'M');
        solRewardContract[_ca] = _state;
    }

    function sendSolReward(uint256 _amt,address _to) external {
        require(solRewardContract[msg.sender],'M');
        IERC20(sol).transfer(_to, _amt);
    }

    function sosBuy(uint256 _bnbAmt) external{
        require(msg.sender == sosBuyManage,'M');
        _claimV3Pool(_bnbAmt);
        inswap =true;
        ISwapRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value:_bnbAmt}(0, buyPath, sosBuyTo, deadLine);
        inswap = false;
    }

    function withdrawV3NFT(address to) external{
        require(msg.sender == V3admin,'M');
        IERC721(V3Manage).transferFrom(address(this), to, _tokenId);
    }
    function setV3Nft(uint256 _nftId,address _caclContract) external{
        require(msg.sender == V3admin,'M');
        _tokenId = _nftId;
        v3_position_calc = _caclContract;
    }

    function refundErrorToken(address _tk,address _to,uint256 _amt) external{
        require(msg.sender == errorTokenAdmin,'M');
        require(_tk != address(this) && _tk !=sol,'TK');
        IERC20(_tk).transfer(_to, _amt);
    }

    function setFreeFeeAddr(address _addr,bool _state) external {
        require(msg.sender == freeFeeManage,'M');
        freeFeeAddr[_addr] = _state;
    }
    function setMaxMinRwdCa(address _ca) external{
        require(msg.sender == maxMinCaManage,'M');
        maxMinRewardAddress = _ca;
    }
    function subRewards() external {
        require(startBlock>0,'wait OPen Invest');
        require(msg.sender == subRewardsManage,'M');
        require(block.number >= nextSubBlock,'WAIT');
        nextSubBlock +=dayBlock;
        updatePool(0);
        updatePool(1);
        PoolInfo storage poolStatic = poolInfo[0];
        PoolInfo storage poolInvite = poolInfo[1];
        uint256 nowStaticPoint = poolStatic.allocPoint;
        uint256 nowInvitePoint = poolInvite.allocPoint;
        uint256 nextStaticPoint = nowStaticPoint - subPerStaicAllocPoint;
        uint256 nextInvitePoint = nowInvitePoint - subPerInviteAllocPoint;
        require(nextStaticPoint >=minStaticAllocPoint,'MinStatic');
        require(nextInvitePoint >=minInviteAllocPoint,'MinStatic');
        poolStatic.allocPoint = nextStaticPoint;
        poolInvite.allocPoint = nextInvitePoint;
    }

    function startProject(uint256 _tId)external onlyOwner{
        require(isInitPool,'wait init pool');
        require(startBlock ==0 ,'Start');
        startBlock = block.number;
        poolInfo.push(PoolInfo({
            allocPoint: 7000,
            lastRewardBlock: block.number,
            accSushiPerShare: 0
        }));
        poolInfo.push(PoolInfo({
            allocPoint: 3000,
            lastRewardBlock: block.number,
            accSushiPerShare: 0
        }));
        nextSubBlock = block.number + dayBlock;
        _tokenId = _tId;
    }

    function getUserInfo(address _user) external view returns(UserInfo memory){
        return userInfo[_user];
    }

    function getUintINfo() external view returns(
        uint256 _staticTotalSupply,
        uint256 _inviteTotalSupply,
        uint256 _totalInvestBNB,
        uint256 _totalInvestUser,
        uint256 _totalInvestTimes){
        _staticTotalSupply = staticTotalSupply;
        _inviteTotalSupply = inviteTotalSupply;
        _totalInvestBNB=totalInvestBNB;
        _totalInvestUser=totalInvestUser;
        _totalInvestTimes=totalInvestTimes;

    }

    function getPoolInfo()external view returns(PoolInfo memory,PoolInfo memory){
        return (poolInfo[0],poolInfo[1]);
    }
    function getUserTotalInvestBnb(address _user) external view returns(uint256){
        return totalInvestBnb[_user];
    }
    function getUserTotalClaimedHfh(address _user) external view returns(uint256){
        return totalClaimedHfh[_user];
    }
    function getAddInviteProof(address _user,address _to) external view returns(uint256){
        return addInviteProof[_user][_to];
    }
    function getAllUsers()external view returns(address[] memory){
        return allUsers;
    }

    function getUserInviteArry(address _user) external view returns(address[] memory){
        return userInviteList[_user];
    }

    function getUserTeamMaxMin(
        address _user
    ) public view returns (address, uint256, uint256) {
        uint256 len = userInviteList[_user].length;
        if (len > 1) {
            
            uint256 maxLV = 0; 
            address maxLaddr;
            for (uint256 i = 0; i < len; i++) {
                UserInfo memory iinfo = userInfo[userInviteList[_user][i]];
                uint256 ztV = iinfo.teamValue;
                if (ztV > maxLV) {
                    maxLV = ztV;
                    maxLaddr = userInviteList[_user][i];
                }
            }
            uint256 uV = userInfo[_user].teamValue; 
            uint256 minV = (uV >= maxLV) ? (uV - maxLV) : 0; 
            return (maxLaddr, maxLV, minV);
        } else {
            return (address(0), 0, 0);
        }
    }
}