// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./UniswapV3StaticOracle.sol";

import "../interfaces/IStableOracle.sol";
import "../interfaces/IStaticOracle.sol";

/*
    Oracle for DAI using WETH/DAI UniV3 pools (this could also use several DEX pools)
    
    curve DAI 3pool 0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7 (400m TVL) -- to other stables
    curve tricrypto2 0xd51a44d3fae010294c616388b506acda1bfaae46 (200m TVL) -- to ETH, to BTC
    uniswap DAI/ETH 0x60594a405d53811d3bc4766596efd80fd545a270 (200m TVL) -- to ETH
    0x773616e4d11a78f511299002da57a0a94577f1f4 Chainlink DAI/ETH feed
*/
contract StableOracleDAI is IStableOracle {
    AggregatorV3Interface priceFeedDAIETH;
    IStaticOracle DAIEthOracle;
    IStableOracle ethOracle;

    constructor() {
        priceFeedDAIETH = AggregatorV3Interface(0x773616E4d11A78F511299002da57A0a94577F1f4);
        DAIEthOracle = IStaticOracle(0x982152A6C7f732Ec7C9EA998dDD9Ebde00Dfa16e);
        ethOracle = IStableOracle(0x0000000000000000000000000000000000000000); // TODO: WETH oracle price
    }

    function getPriceUSD() external view override returns (uint256) {
        address[] memory pools = new address[](1);
        pools[0] = 0x60594a405d53811d3BC4766596EFD80fd545A270;
        uint256 DAIWethPrice = DAIEthOracle.quoteSpecificPoolsWithTimePeriod(
            1000000000000000000, // 1 Eth
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH (base token)
            0x6B175474E89094C44Da98b954EedeAC495271d0F, // DAI (quote token)
            pools, // DAI/WETH pool uni v3
            600 // period
        );

        uint256 wethPriceUSD = ethOracle.getPriceUSD();

        // chainlink price data is 8 decimals for WETH/USD, so multiply by 10 decimals to get 18 decimal fractional
        //(uint80 roundID, int256 price, uint256 startedAt, uint256 timeStamp, uint80 answeredInRound) = priceFeedDAIETH.latestRoundData();
        (, int256 price,,,) = priceFeedDAIETH.latestRoundData();

        return (wethPriceUSD * 1e18) / ((DAIWethPrice + uint256(price) * 1e10) / 2);
    }
}
