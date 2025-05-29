// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interfaces
import "../../../interfaces/ITellerV2Context.sol";
import "../../../interfaces/IProtocolFee.sol";
import "../../../interfaces/ITellerV2Storage.sol";
import "../../../interfaces/ITellerV2.sol";

import "../../../interfaces/IFlashRolloverLoan.sol";
import "../../../libraries/NumbersLib.sol";

import "../../../interfaces/uniswap/IUniswapV3Pool.sol";

import "../../../interfaces/uniswap/IUniswapV3Factory.sol";

import "../../../libraries/uniswap/TickMath.sol";
import "../../../libraries/uniswap/FixedPoint96.sol";
import "../../../libraries/uniswap/FullMath.sol";

import "./LenderCommitmentGroupShares.sol";

import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import { CommitmentCollateralType, ISmartCommitment } from "../../../interfaces/ISmartCommitment.sol";
import { ILoanRepaymentListener } from "../../../interfaces/ILoanRepaymentListener.sol";

import { ILoanRepaymentCallbacks } from "../../../interfaces/ILoanRepaymentCallbacks.sol";

import { ILenderCommitmentGroup } from "../../../interfaces/ILenderCommitmentGroup.sol";
import { Payment } from "../../../TellerV2Storage.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/*
 

 Each LenderCommitmentGroup SmartContract acts as its own Loan Commitment (for the SmartCommitmentForwarder) and acts as its own Lender in the Teller Protocol.

 Lender Users can deposit principal tokens in this contract and this will give them Share Tokens (LP tokens) representing their ownership in the liquidity pool of this contract.

 Borrower Users can borrow principal token funds from this contract (via the SCF contract) by providing collateral tokens in the proper amount as specified by the rules of this smart contract.
 These collateral tokens are then owned by this smart contract and are returned to the borrower via the Teller Protocol rules to the borrower if and only if the borrower repays principal and interest of the loan they took.

 If the borrower defaults on a loan, for 24 hours a liquidation auction is automatically conducted by this smart contract in order to incentivize a liquidator to take the collateral tokens in exchange for principal tokens.

  
 

*/

contract LenderCommitmentGroup_Smart is
    ILenderCommitmentGroup,
    ISmartCommitment,
    ILoanRepaymentListener,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using AddressUpgradeable for address;
    using NumbersLib for uint256;

    uint256 public immutable STANDARD_EXPANSION_FACTOR = 1e18;

    uint256 public immutable UNISWAP_EXPANSION_FACTOR = 2**96;

    uint256 public immutable EXCHANGE_RATE_EXPANSION_FACTOR = 1e36;  

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable TELLER_V2;
    address public immutable SMART_COMMITMENT_FORWARDER;
    address public immutable UNISWAP_V3_FACTORY;
    address public UNISWAP_V3_POOL;
 
    LenderCommitmentGroupShares public poolSharesToken;

    IERC20 public principalToken;
    IERC20 public collateralToken;

    uint256 marketId;

 
    uint256 public totalPrincipalTokensCommitted; 
    uint256 public totalPrincipalTokensWithdrawn;

    uint256 public totalPrincipalTokensLended;
    uint256 public totalPrincipalTokensRepaid; //subtract this and the above to find total principal tokens outstanding for loans

    
 
    uint256 public totalInterestCollected;

    uint16 public liquidityThresholdPercent; //5000 is 50 pct  // enforce max of 10000
    uint16 public collateralRatio; //the overcollateralization ratio, typically 80 pct

    uint32 public twapInterval;
    uint32 public maxLoanDuration;
    uint16 public interestRateLowerBound;
    uint16 public interestRateUpperBound;


    //mapping(address => uint256) public principalTokensCommittedByLender;
    mapping(uint256 => bool) public activeBids;

    //this excludes interest
    // maybe it is possible to get rid of this storage slot and calculate it from totalPrincipalTokensRepaid, totalPrincipalTokensLended
    int256 tokenDifferenceFromLiquidations;


   

    modifier onlySmartCommitmentForwarder() {
        require(
            msg.sender == address(SMART_COMMITMENT_FORWARDER),
            "Can only be called by Smart Commitment Forwarder"
        );
        _;
    }

    modifier onlyTellerV2() {
        require(
            msg.sender == address(TELLER_V2),
            "Can only be called by TellerV2"
        );
        _;
    }

    modifier bidIsActiveForGroup(uint256 _bidId) {
        require(activeBids[_bidId] == true, "Bid is not active for group");

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _tellerV2,
        address _smartCommitmentForwarder,
        address _uniswapV3Factory
    ) {
        TELLER_V2 = _tellerV2;
        SMART_COMMITMENT_FORWARDER = _smartCommitmentForwarder;
        UNISWAP_V3_FACTORY = _uniswapV3Factory;
    }

    /*


        
    */
    function initialize(
        address _principalTokenAddress,
        address _collateralTokenAddress,
        uint256 _marketId,
        uint32 _maxLoanDuration,
        uint16 _interestRateLowerBound,
        uint16 _interestRateUpperBound,
        uint16 _liquidityThresholdPercent, // When 100% , the entire pool can be drawn for lending.  When 80%, only 80% of the pool can be drawn for lending. 
        uint16 _collateralRatio, //the required overcollateralization ratio.  10000 is 1:1 baseline , typically this is above 10000
        uint24 _uniswapPoolFee,
        uint32 _twapInterval
    ) external initializer returns (address poolSharesToken_) {
        // require(!_initialized,"already initialized");
        // _initialized = true;

        __Pausable_init();

        principalToken = IERC20(_principalTokenAddress);
        collateralToken = IERC20(_collateralTokenAddress);

        UNISWAP_V3_POOL = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(
            _principalTokenAddress,
            _collateralTokenAddress,
            _uniswapPoolFee
        );

        require(UNISWAP_V3_POOL != address(0), "Invalid uniswap pool address");

        marketId = _marketId;

        //in order for this to succeed, first, that SmartCommitmentForwarder needs to be THE trusted forwarder for the market

         
        ITellerV2Context(TELLER_V2).approveMarketForwarder(
            _marketId,
            SMART_COMMITMENT_FORWARDER
        );

        maxLoanDuration = _maxLoanDuration;
        interestRateLowerBound = _interestRateLowerBound;
        interestRateUpperBound = _interestRateUpperBound;


        
        
        require(interestRateLowerBound <= interestRateUpperBound, "invalid _interestRateLowerBound");

        require(_liquidityThresholdPercent <= 10000, "invalid _liquidityThresholdPercent"); 

        liquidityThresholdPercent = _liquidityThresholdPercent;
        collateralRatio = _collateralRatio;
        twapInterval = _twapInterval;

        
        poolSharesToken_ = _deployPoolSharesToken();
    }

    function _deployPoolSharesToken()
        internal
        onlyInitializing
        returns (address poolSharesToken_)
    {
      
        require(
            address(poolSharesToken) == address(0),
            "Pool shares already deployed"
        );


        (string memory name, string memory symbol ) = _generateTokenNameAndSymbol(
            address(principalToken),
            address(collateralToken)
        );

        poolSharesToken = new LenderCommitmentGroupShares(
            name,
            symbol,
            18  
        );

        return address(poolSharesToken);
    }

    function _generateTokenNameAndSymbol(address principalToken, address collateralToken) 
    internal view 
    returns (string memory name, string memory symbol) {
        // Read the symbol of the principal token
        string memory principalSymbol = ERC20(principalToken).symbol();
        
        // Read the symbol of the collateral token
        string memory collateralSymbol = ERC20(collateralToken).symbol();
        
        // Combine the symbols to create the name
        name = string(abi.encodePacked("GroupShares-", principalSymbol, "-", collateralSymbol));
        
        // Combine the symbols to create the symbol
        symbol = string(abi.encodePacked("SHR-", principalSymbol, "-", collateralSymbol));
    }

    /**
     * @notice This determines the number of shares you get for depositing principal tokens and the number of principal tokens you receive for burning shares
     * @return rate_ The current exchange rate, scaled by the EXCHANGE_RATE_FACTOR.
     */

    function sharesExchangeRate() public view virtual returns (uint256 rate_) {
        

        uint256 poolTotalEstimatedValue = getPoolTotalEstimatedValue();

        if (poolSharesToken.totalSupply() == 0) {
            return EXCHANGE_RATE_EXPANSION_FACTOR; // 1 to 1 for first swap
        }

        rate_ =
            (poolTotalEstimatedValue  *
                EXCHANGE_RATE_EXPANSION_FACTOR) /
            poolSharesToken.totalSupply();
    }

    function sharesExchangeRateInverse()
        public
        view
        virtual
        returns (uint256 rate_)
    {
        return
            (EXCHANGE_RATE_EXPANSION_FACTOR * EXCHANGE_RATE_EXPANSION_FACTOR) /
            sharesExchangeRate();
    }

    function getPoolTotalEstimatedValue()
        public
        view
        returns (uint256 poolTotalEstimatedValue_)
    {
       
         int256 poolTotalEstimatedValueSigned = int256(totalPrincipalTokensCommitted) 
         + int256(totalInterestCollected)  + int256(tokenDifferenceFromLiquidations) 
         - int256(totalPrincipalTokensWithdrawn);

        //if the poolTotalEstimatedValue_ is less than 0, we treat it as 0.  
        poolTotalEstimatedValue_ = poolTotalEstimatedValueSigned > int256(0)
            ? uint256(poolTotalEstimatedValueSigned)
            : 0;
    }

    /*
    must be initialized for this to work ! 
    */
    function addPrincipalToCommitmentGroup(
        uint256 _amount,
        address _sharesRecipient
    ) external returns (uint256 sharesAmount_) {
        //transfers the primary principal token from msg.sender into this contract escrow
        
        principalToken.transferFrom(msg.sender, address(this), _amount);

        sharesAmount_ = _valueOfUnderlying(_amount, sharesExchangeRate());

        totalPrincipalTokensCommitted += _amount;
        //principalTokensCommittedByLender[msg.sender] += _amount;

        //mint shares equal to _amount and give them to the shares recipient !!!
        poolSharesToken.mint(_sharesRecipient, sharesAmount_);
    }

    function _valueOfUnderlying(uint256 amount, uint256 rate)
        internal
        pure
        returns (uint256 value_)
    {
        if (rate == 0) {
            return 0;
        }

        value_ = (amount * EXCHANGE_RATE_EXPANSION_FACTOR) / rate;
    }

    function acceptFundsForAcceptBid(
        address _borrower,
        uint256 _bidId,
        uint256 _principalAmount,
        uint256 _collateralAmount,
        address _collateralTokenAddress,
        uint256 _collateralTokenId, 
        uint32 _loanDuration,
        uint16 _interestRate
    ) external onlySmartCommitmentForwarder whenNotPaused {
        
        require(
            _collateralTokenAddress == address(collateralToken),
            "Mismatching collateral token"
        );
        //the interest rate must be at least as high has the commitment demands. The borrower can use a higher interest rate although that would not be beneficial to the borrower.
        require(_interestRate >= getMinInterestRate(), "Invalid interest rate");
        //the loan duration must be less than the commitment max loan duration. The lender who made the commitment expects the money to be returned before this window.
        require(_loanDuration <= maxLoanDuration, "Invalid loan max duration");

        require(
            getPrincipalAmountAvailableToBorrow() >= _principalAmount,
            "Invalid loan max principal"
        );
 

        //this is expanded by 10**18
        uint256 requiredCollateral = getCollateralRequiredForPrincipalAmount(
            _principalAmount
        );

        require(
            (_collateralAmount * STANDARD_EXPANSION_FACTOR) >=
                requiredCollateral,
            "Insufficient Borrower Collateral"
        );
 
        principalToken.approve(address(TELLER_V2), _principalAmount);

        //do not have to spoof/forward as this contract is the lender !
        _acceptBidWithRepaymentListener(_bidId);

        totalPrincipalTokensLended += _principalAmount;

        activeBids[_bidId] = true; //bool for now
        //emit event
    }

    function _acceptBidWithRepaymentListener(uint256 _bidId) internal {
        ITellerV2(TELLER_V2).lenderAcceptBid(_bidId); //this gives out the funds to the borrower

        ILoanRepaymentCallbacks(TELLER_V2).setRepaymentListenerForBid(
            _bidId,
            address(this)
        );
    }

    /*
       
    */
    function burnSharesToWithdrawEarnings(
        uint256 _amountPoolSharesTokens,
        address _recipient
    ) external returns (uint256) {
       

        
        poolSharesToken.burn(msg.sender, _amountPoolSharesTokens);

        uint256 principalTokenValueToWithdraw = _valueOfUnderlying(
            _amountPoolSharesTokens,
            sharesExchangeRateInverse()
        );

        totalPrincipalTokensWithdrawn += principalTokenValueToWithdraw;

        principalToken.transfer(_recipient, principalTokenValueToWithdraw);

        return principalTokenValueToWithdraw;
    }

    /*


    */

    function liquidateDefaultedLoanWithIncentive(
        uint256 _bidId,
        int256 _tokenAmountDifference
    ) public bidIsActiveForGroup(_bidId) {
        uint256 amountDue = getAmountOwedForBid(_bidId, false);

        uint256 loanDefaultedTimeStamp = ITellerV2(TELLER_V2)
            .getLoanDefaultTimestamp(_bidId);

        int256 minAmountDifference = getMinimumAmountDifferenceToCloseDefaultedLoan(
                amountDue,
                loanDefaultedTimeStamp
            );

        require(
            _tokenAmountDifference >= minAmountDifference,
            "Insufficient tokenAmountDifference"
        );

        if (_tokenAmountDifference > 0) {
            //this is used when the collateral value is higher than the principal (rare)
            //the loan will be completely made whole and our contract gets extra funds too
            uint256 tokensToTakeFromSender = abs(_tokenAmountDifference);

            IERC20(principalToken).transferFrom(
                msg.sender,
                address(this),
                amountDue + tokensToTakeFromSender
            );

            tokenDifferenceFromLiquidations += int256(tokensToTakeFromSender);

            totalPrincipalTokensRepaid += amountDue;
        } else {
           
            uint256 tokensToGiveToSender = abs(_tokenAmountDifference);

            IERC20(principalToken).transferFrom(
                msg.sender,
                address(this),
                amountDue - tokensToGiveToSender
            );

            tokenDifferenceFromLiquidations -= int256(tokensToGiveToSender);

            totalPrincipalTokensRepaid += amountDue;
        }

        //this will give collateral to the caller
        ITellerV2(TELLER_V2).lenderCloseLoanWithRecipient(_bidId, msg.sender);
    }

    function getAmountOwedForBid(uint256 _bidId, bool _includeInterest)
        public
        view
        virtual
        returns (uint256 amountOwed_)
    {
        Payment memory amountOwedPayment = ITellerV2(TELLER_V2)
            .calculateAmountOwed(_bidId, block.timestamp);

        amountOwed_ = _includeInterest
            ? amountOwedPayment.principal + amountOwedPayment.interest
            : amountOwedPayment.principal;
    }

    /*
        This function will calculate the incentive amount (using a uniswap bonus plus a timer)
        of principal tokens that will be given to incentivize liquidating a loan 
 
    */
    function getMinimumAmountDifferenceToCloseDefaultedLoan(
        uint256 _amountOwed,
        uint256 _loanDefaultedTimestamp
    ) public view virtual returns (int256 amountDifference_) {
        require(
            _loanDefaultedTimestamp > 0,
            "Loan defaulted timestamp must be greater than zero"
        );
        require(
            block.timestamp > _loanDefaultedTimestamp,
            "Loan defaulted timestamp must be in the past"
        );

        uint256 secondsSinceDefaulted = block.timestamp -
            _loanDefaultedTimestamp;
 
        int256 incentiveMultiplier = int256(86400) -
            int256(secondsSinceDefaulted);

        if (incentiveMultiplier < -10000) {
            incentiveMultiplier = -10000;
        }

        amountDifference_ =
            (int256(_amountOwed) * incentiveMultiplier) /
            int256(10000);
    }

    function abs(int x) private pure returns (uint) {
        return x >= 0 ? uint(x) : uint(-x);
    }
 
    function getCollateralRequiredForPrincipalAmount(uint256 _principalAmount)
        public
        view
        returns (uint256)
    {
        uint256 baseAmount = _calculateCollateralTokensAmountEquivalentToPrincipalTokens(
                _principalAmount
            );

        //this is an amount of collateral
        return baseAmount.percent(collateralRatio);
    }

    //this result is expanded by UNISWAP_EXPANSION_FACTOR
    function _getUniswapV3TokenPairPrice(uint32 _twapInterval)
        internal
        view
        returns (uint256)
    {
        // represents the square root of the price of token1 in terms of token0

        uint160 sqrtPriceX96 = getSqrtTwapX96(_twapInterval);

        //this output is the price ratio expanded by 1e18
        return _getPriceFromSqrtX96(sqrtPriceX96);
    }

    //this result is expanded by UNISWAP_EXPANSION_FACTOR
    function _getPriceFromSqrtX96(uint160 _sqrtPriceX96)
        internal
        pure
        returns (uint256 price_)
    {
       
        uint256 priceX96 = (uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96)) /
            (2**96);

        // sqrtPrice is in X96 format so we scale it down to get the price
        // Also note that this price is a relative price between the two tokens in the pool
        // It's not a USD price
        price_ = priceX96;
    }

    // ---- TWAP

    function getSqrtTwapX96(uint32 twapInterval)
        public
        view
        returns (uint160 sqrtPriceX96)
    {
        if (twapInterval == 0) {
            // return the current price if twapInterval == 0
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(UNISWAP_V3_POOL)
                .slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval; // from (before)
            secondsAgos[1] = 0; // to (now)

            (int56[] memory tickCumulatives, ) = IUniswapV3Pool(UNISWAP_V3_POOL)
                .observe(secondsAgos);

            // tick(imprecise as it's an integer) to price
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24(
                    (tickCumulatives[1] - tickCumulatives[0]) /
                        int32(twapInterval)
                )
            );
        }
    }

    function _getPoolTokens()
        internal
        view
        virtual
        returns (address token0, address token1)
    {
        token0 = IUniswapV3Pool(UNISWAP_V3_POOL).token0();
        token1 = IUniswapV3Pool(UNISWAP_V3_POOL).token1();
    }

    // -----

    //this is expanded by 10e18
    function _calculateCollateralTokensAmountEquivalentToPrincipalTokens(
        uint256 principalTokenAmountValue
    ) internal view returns (uint256 collateralTokensAmountToMatchValue) {
        //same concept as zeroforone
        (address token0, ) = _getPoolTokens();

        bool principalTokenIsToken0 = (address(principalToken) == token0);

        uint256 pairPriceWithTwap = _getUniswapV3TokenPairPrice(twapInterval);
        uint256 pairPriceImmediate = _getUniswapV3TokenPairPrice(0);

        return
            _getCollateralTokensAmountEquivalentToPrincipalTokens(
                principalTokenAmountValue,
                pairPriceWithTwap,
                pairPriceImmediate,
                principalTokenIsToken0
            );
    }

    /*
        Dev Note: pairPriceWithTwap and pairPriceImmediate are expanded by UNISWAP_EXPANSION_FACTOR

    */
    function _getCollateralTokensAmountEquivalentToPrincipalTokens(
        uint256 principalTokenAmountValue,
        uint256 pairPriceWithTwap,
        uint256 pairPriceImmediate,
        bool principalTokenIsToken0
    ) internal pure returns (uint256 collateralTokensAmountToMatchValue) {
        if (principalTokenIsToken0) {
            //token 1 to token 0 ?
            uint256 worstCasePairPrice = Math.min(
                pairPriceWithTwap,
                pairPriceImmediate
            );

            collateralTokensAmountToMatchValue = token1ToToken0(
                principalTokenAmountValue,
                worstCasePairPrice //if this is lower, collateral tokens amt will be higher
            );
        } else {
            //token 0 to token 1 ?
            uint256 worstCasePairPrice = Math.max(
                pairPriceWithTwap,
                pairPriceImmediate
            );

            collateralTokensAmountToMatchValue = token0ToToken1(
                principalTokenAmountValue,
                worstCasePairPrice //if this is lower, collateral tokens amt will be higher
            );
        }
    }

    //note: the price is still expanded by UNISWAP_EXPANSION_FACTOR
    function token0ToToken1(uint256 amountToken0, uint256 priceToken1PerToken0)
        internal
        pure
        returns (uint256)
    {
        return
            MathUpgradeable.mulDiv(
                amountToken0,
                UNISWAP_EXPANSION_FACTOR,
                priceToken1PerToken0,
                MathUpgradeable.Rounding.Up
            );
    }

    //note: the price is still expanded by UNISWAP_EXPANSION_FACTOR
    function token1ToToken0(uint256 amountToken1, uint256 priceToken1PerToken0)
        internal
        pure
        returns (uint256)
    {
        return
            MathUpgradeable.mulDiv(
                amountToken1,
                priceToken1PerToken0,
                UNISWAP_EXPANSION_FACTOR,
                MathUpgradeable.Rounding.Up
            );
    }

    /*
    This  callback occurs when a TellerV2 repayment happens or when a TellerV2 liquidate happens 

    lenderCloseLoan does not trigger a repayLoanCallback 
    */
    function repayLoanCallback(
        uint256 _bidId,
        address repayer,
        uint256 principalAmount,
        uint256 interestAmount
    ) external onlyTellerV2 {
        //can use principal amt to increment amt paid back!! nice for math .
        totalPrincipalTokensRepaid += principalAmount;
        totalInterestCollected += interestAmount;
    }

  
    function getTotalPrincipalTokensOutstandingInActiveLoans()
        public
        view
        returns (uint256)
    {
        return totalPrincipalTokensLended - totalPrincipalTokensRepaid;
    }

    function getCollateralTokenAddress() external view returns (address) {
        return address(collateralToken);
    }

    function getCollateralTokenId() external view returns (uint256) {
        return 0;
    }

    function getCollateralTokenType()
        external
        view
        returns (CommitmentCollateralType)
    {
        return CommitmentCollateralType.ERC20;
    }

    //this is expanded by 1e18
    //this only exists to comply with the interface
    function getRequiredCollateral(uint256 _principalAmount)
        public
        view
        returns (uint256 requiredCollateral_)
    {
        requiredCollateral_ = getCollateralRequiredForPrincipalAmount(
            _principalAmount
        );
    }

    function getMarketId() external view returns (uint256) {
        return marketId;
    }

    function getMaxLoanDuration() external view returns (uint32) {
        return maxLoanDuration;
    }

    //this is always between 0 and 10000
    function getPoolUtilizationRatio() public view returns (uint16) {

        if (getPoolTotalEstimatedValue() == 0) {
            return 0;
        }

        return uint16(  Math.min(   
           getTotalPrincipalTokensOutstandingInActiveLoans()  * 10000  / 
           getPoolTotalEstimatedValue() , 10000  ));
    }   

 
    function getMinInterestRate() public view returns (uint16) {
        return interestRateLowerBound + uint16( uint256(interestRateUpperBound-interestRateLowerBound).percent(getPoolUtilizationRatio()) );
    }

    function getPrincipalTokenAddress() external view returns (address) {
        return address(principalToken);
    }

   

    function getPrincipalAmountAvailableToBorrow()
        public
        view
        returns (uint256)
    {     

            return  ( uint256( getPoolTotalEstimatedValue() )).percent(liquidityThresholdPercent) -
            getTotalPrincipalTokensOutstandingInActiveLoans() ;
     
    }

    /**
     * @notice Lets the DAO/owner of the protocol implement an emergency stop mechanism.
     */
    function pauseBorrowing() public virtual onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @notice Lets the DAO/owner of the protocol undo a previously implemented emergency stop.
     */
    function unpauseBorrowing() public virtual onlyOwner whenPaused {
        _unpause();
    }
}
