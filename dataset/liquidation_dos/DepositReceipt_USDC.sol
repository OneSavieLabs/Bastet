pragma solidity =0.8.9;

import "./DepositReceipt_Base.sol";

contract DepositReceipt_USDC is  DepositReceipt_Base {

    uint256 private constant SCALE_SHIFT = 1e12; //brings USDC 6.d.p up to 18d.p. standard
    uint256 private constant USDC_BASE = 1e6; //used for division in USDC 6.d.p scale
    uint256 private constant ALLOWED_DEVIATION = 5e16; //5% in 1e18 / ETH scale
    address private constant USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607; 

    //Chainlink oracle source
    IAggregatorV3 public priceFeed;
    // ten to the power of the number of decimals given by the price feed
    uint256 private immutable oracleBase;

    /**
    *    @notice Zero address checks done in Templater that generates DepositReceipt and so not needed here.
    **/
    constructor(string memory _name, 
                string memory _symbol, 
                address _router, 
                address _token0,
                address _token1,
                bool _stable,
                address _priceFeed) 
                ERC721(_name, _symbol){

        //we dont want the `DEFAULT_ADMIN_ROLE` to exist as this doesn't require a 
        // time delay to add/remove any role and so is dangerous. 
        //So we ignore it and set our weaker admin role.
        _setupRole(ADMIN_ROLE, msg.sender);
        currentLastId = 1; //avoid id 0
        //set up details for underlying tokens
        router = IRouter(_router);

        //here we check one token is USDC and that the other token has 18d.p.
        //this prevents pricing mistakes and is defensive design against dev oversight.
        //Obvious this is not a full check, a malicious ERC20 can set it's own symbol as USDC too 
        //but in practice as only the multi-sig should be deploying via Templater this is not a concern 
        
        bytes memory USDCSymbol = abi.encodePacked("USDC");
        bytes memory token0Symbol = abi.encodePacked(IERC20Metadata(_token0).symbol());
        //equality cannot be checked for strings so we hash them first.
        if (keccak256(token0Symbol) == keccak256(USDCSymbol)){
            require( IERC20Metadata(_token1).decimals() == 18, "Token does not have 18dp");
        }
        else
        {   
            bytes memory token1Symbol = abi.encodePacked(IERC20Metadata(_token1).symbol());
            
            require( keccak256(token1Symbol) == keccak256(USDCSymbol), "One token must be USDC");
            require( IERC20Metadata(_token0).decimals() == 18, "Token does not have 18dp");
            
        }

        token0 = _token0;
        token1 = _token1;
        stable = _stable;
        priceFeed = IAggregatorV3(_priceFeed);
        IAccessControlledOffchainAggregator  aggregator = IAccessControlledOffchainAggregator(priceFeed.aggregator());
        //fetch the pricefeeds hard limits so we can be aware if these have been reached.
        tokenMinPrice = aggregator.minAnswer();
        tokenMaxPrice = aggregator.maxAnswer();
        oracleBase = 10 ** priceFeed.decimals();  //Chainlink USD oracles have 8d.p.
    }

   /**
    *  @notice this is used to price pooled Tokens by determining their underlying assets and then pricing these
    *  @notice the two ways to do this are to price to USDC as  a dollar equivalent or to ETH then use Chainlink price feeds
    *  @dev each DepositReceipt has a bespoke valuation method, make sure it fits the tokens
    *  @dev each DepositReceipt's valuation method is sensitive to available liquidity keep this in mind as liquidating a pooled token by using the same pool will reduce overall liquidity

    */
    function priceLiquidity(uint256 _liquidity) external override view returns(uint256){
        uint256 token0Amount;
        uint256 token1Amount;
        (token0Amount, token1Amount) = viewQuoteRemoveLiquidity(_liquidity);
        //USDC route 
        uint256 value0;
        uint256 value1;
        if (token0 == USDC){
            //hardcode value of USDC at $1
            //check swap value of 100tokens to USDC to protect against flash loan attacks
            uint256 amountOut; //amount received by trade
            bool stablePool; //if the traded pool is stable or volatile.
            (amountOut, stablePool) = router.getAmountOut(HUNDRED_TOKENS, token1, USDC);
            require(stablePool == stable, "pricing occuring through wrong pool" );

            uint256 oraclePrice = getOraclePrice(priceFeed, tokenMaxPrice, tokenMinPrice);
            amountOut = (amountOut * oracleBase) / USDC_BASE / HUNDRED; //shift USDC amount to same scale as oracle

            //calculate acceptable deviations from oracle price
            uint256 lowerBound = (oraclePrice * (BASE - ALLOWED_DEVIATION)) / BASE;
            uint256 upperBound = (oraclePrice * (BASE + ALLOWED_DEVIATION)) / BASE;
            //because 1 USDC = $1 we can compare its amount directly to bounds
            require(lowerBound < amountOut, "Price shift low detected");
            require(upperBound > amountOut, "Price shift high detected");

            value0 = token0Amount * SCALE_SHIFT;
            
            value1 = (token1Amount * oraclePrice) / oracleBase;
        }
        //token1 must be USDC 
        else {
            //hardcode value of USDC at $1
            //check swap value of 100tokens to USDC to protect against flash loan attacks
            uint256 amountOut; //amount received by trade
            bool stablePool; //if the traded pool is stable or volatile.
            (amountOut, stablePool) = router.getAmountOut(HUNDRED_TOKENS, token0, USDC);
            require(stablePool == stable, "pricing occuring through wrong pool" );

            uint256 oraclePrice = getOraclePrice(priceFeed, tokenMaxPrice, tokenMinPrice);
            amountOut = (amountOut * oracleBase) / USDC_BASE / HUNDRED; //shift USDC amount to same scale as oracle

            //calculate acceptable deviations from oracle price
            uint256 lowerBound = (oraclePrice * (BASE - ALLOWED_DEVIATION)) / BASE;
            uint256 upperBound = (oraclePrice * (BASE + ALLOWED_DEVIATION)) / BASE;
            //because 1 USDC = $1 we can compare its amount directly to bounds
            require(lowerBound < amountOut, "Price shift low detected");
            require(upperBound > amountOut, "Price shift high detected");

            value1 = token1Amount * SCALE_SHIFT;
           
            value0 = (token0Amount * oraclePrice) / oracleBase;
        }
        //Invariant: both value0 and value1 are in ETH scale 18.d.p now
        //USDC has only 6 decimals so we bring it up to the same scale as other 18d.p ERC20s
        return(value0 + value1);
    }
}