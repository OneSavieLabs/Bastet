// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.13;

import './Interfaces.sol';
import './ERC5095.sol';
import './Safe.sol';

/// @title MarketPlace
/// @author Sourabh Marathe, Julian Traversa, Rob Robbins
/// @notice This contract is in charge of managing the avaialable principals for each loan market.
/// @notice In addition, this contract routes swap orders between metaprincipal tokens and their respective underlying to YieldSpace pools.
contract MarketPlace {
    /// @notice the available principals
    /// @dev the order of this enum is used to select principals from the markets
    /// mapping (e.g. Illuminate => 0, Swivel => 1, and so on)
    enum Principals {
        Illuminate,
        Swivel,
        Yield,
        Element,
        Pendle,
        Tempus,
        Sense,
        Apwine,
        Notional
    }

    error Exists(string);
    error Unauthorized();
    error Invalid(string);

    /// @notice markets are defined by a market pair which point to a fixed length array of principal token addresses. 
    /// @notice The principal tokens those addresses represent correspond to their Principals enum value, thus the array should be ordered in that way
    mapping(address => mapping(uint256 => address[9])) public markets;

    /// @notice pools map markets to their respective YieldSpace pools for the MetaPrincipal token
    mapping(address => mapping(uint256 => address)) public pools;

    /// @notice address that is allowed to create markets, set fees, etc. It is commonly used in the authorized modifier.
    address public admin;
    /// @notice address of the deployed redeemer contract
    address public immutable redeemer;
    /// @notice address of the deployed lender contract
    address public immutable lender;

    /// @notice emitted upon the creation of a new market
    event CreateMarket(address indexed underlying, uint256 indexed maturity);

    /// @notice intializes the MarketPlace contract
    /// @param r address of the deployed redeemer contract
    /// @param l address of the deployed lender contract
    constructor(address r, address l) {
        admin = msg.sender;
        redeemer = r;
        lender = l;
    }

    /// @notice creates a new market for the given underlying token and maturity
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param t principal token addresses for this market minus the illuminate principal (which is added here)
    /// @param n name for the illuminate token
    /// @param s symbol for the illuminate token
    /// @param d decimals for the illuminate token
    /// @return bool true if successful
    function createMarket(
        address u,
        uint256 m,
        address[8] memory t,
        string calldata n,
        string calldata s,
        uint8 d
    ) external authorized(admin) returns (bool) {
        if (markets[u][m][uint256(Principals.Illuminate)] != address(0)) {
            revert Exists('market already exists');
        }

        // deploy an illuminate token with this new market
        address iToken = address(new ERC5095(u, m, redeemer, lender, n, s, d));

        // the market will have the illuminate principal as its zeroth item, thus t should have Principals[1] as [0]
        address[9] memory market = [iToken, t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7]];

        // set the market
        markets[u][m] = market;

        emit CreateMarket(u, m);
        return true;
    }

    /// @notice allows the admin to set an individual market
    /// @param p enum value of the principal token
    /// @param u underlying token address
    /// @param m maturity timestamp for the market
    /// @param a address of the new market
    /// @return bool true if successful
    function setPrincipal(uint8 p, address u, uint256 m, address a) external authorized(admin) returns (bool) {
        if (markets[u][m][p] != address(0)) {
            revert Exists('Market already exists');
        }
        markets[u][m][p] = a;
        return true;
    }

    /// @notice sets the admin address
    /// @param a Address of a new admin
    /// @return bool true if successful
    function setAdmin(address a) external authorized(admin) returns (bool) {
        admin = a;
        return true;
    }

    /// @notice sets the address for a pool
    /// @param u address of the underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param a address of the pool
    /// @return bool true if successful
    function setPool(
        address u,
        uint256 m,
        address a
    ) external authorized(admin) returns (bool) {
        if (pools[u][m] != address(0)) {
            revert Exists('pool already exists');
        }
        pools[u][m] = a;
        return true;
    }

    /// @notice sells the PT for the PT via the pool
    /// @param u address of the underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param a amount of PT to swap
    /// @return uint128 amount of PT bought
    function sellPrincipalToken(
        address u,
        uint256 m,
        uint128 a
    ) external returns (uint128) {
        IPool pool = IPool(pools[u][m]);
        Safe.transfer(IERC20(address(pool.fyToken())), address(pool), a);
        return pool.sellFYToken(msg.sender, pool.sellFYTokenPreview(a));
    }

    /// @notice buys the underlying for the PT via the pool
    /// @param u address of the underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param a amount of underlying tokens to sell
    /// @return uint128 amount of PT received
    function buyPrincipalToken(
        address u,
        uint256 m,
        uint128 a
    ) external returns (uint128) {
        IPool pool = IPool(pools[u][m]);
        Safe.transfer(IERC20(address(pool.base())), address(pool), a);
        return pool.buyFYToken(msg.sender, pool.buyFYTokenPreview(a), a);
    }

    /// @notice sells the underlying for the PT via the pool
    /// @param u address of the underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param a amount of underlying to swap
    /// @return uint128 amount of underlying sold
    function sellUnderlying(
        address u,
        uint256 m,
        uint128 a
    ) external returns (uint128) {
        IPool pool = IPool(pools[u][m]);
        Safe.transfer(IERC20(address(pool.base())), address(pool), a);
        return pool.sellBase(msg.sender, pool.sellBasePreview(a));
    }

    /// @notice buys the underlying for the PT via the pool
    /// @param u address of the underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param a amount of PT to swap
    /// @return uint128 amount of underlying bought
    function buyUnderlying(
        address u,
        uint256 m,
        uint128 a
    ) external returns (uint128) {
        IPool pool = IPool(pools[u][m]);
        Safe.transfer(IERC20(address(pool.fyToken())), address(pool), a);
        return pool.buyBase(msg.sender, pool.buyBasePreview(a), a);
    }

    /// @notice mint liquidity tokens in exchange for adding underlying and PT
    /// @dev amount of liquidity tokens to mint is calculated from the amount of unaccounted for PT in this contract.
    /// @dev A proportional amount of underlying tokens need to be present in this contract, also unaccounted for.
    /// @param u the address of the underlying token
    /// @param m the maturity of the principal token
    /// @param uA the underlying amount being sent
    /// @param ptA the principal token amount being sent
    /// @param minRatio minimum ratio of underlying to PT in the pool.
    /// @param maxRatio maximum ratio of underlying to PT in the pool.
    /// @return uint256 the amount of liquidity tokens minted.
    function mint(address u, uint256 m, uint256 uA, uint256 ptA, uint256 minRatio, uint256 maxRatio) external returns (uint256, uint256, uint256) {
        IPool pool = IPool(pools[u][m]);
        Safe.transferFrom(ERC20(address(pool.base())), msg.sender, address(pool), uA);  
        Safe.transferFrom(ERC20(address(pool.fyToken())), msg.sender, address(pool), ptA);
        return pool.mint(msg.sender, msg.sender, minRatio, maxRatio);
    }

    /// @notice Mint liquidity tokens in exchange for adding only underlying
    /// @dev amount of liquidity tokens is calculated from the amount of PT to buy from the pool,
    /// plus the amount of unaccounted for PT in this contract.
    /// @param u the address of the underlying token
    /// @param m the maturity of the principal token
    /// @param a the underlying amount being sent
    /// @param ptBought amount of `PT` being bought in the Pool, from this we calculate how much underlying it will be taken in.
    /// @param minRatio minimum ratio of underlying to PT in the pool.
    /// @param maxRatio maximum ratio of underlying to PT in the pool.
    /// @return uint256 the amount of liquidity tokens minted
    function mintWithUnderlying(address u, uint256 m, uint256 a, uint256 ptBought, uint256 minRatio, uint256 maxRatio) external returns (uint256, uint256, uint256) {
        IPool pool = IPool(pools[u][m]);
        Safe.transferFrom(ERC20(address(pool.base())), msg.sender, address(pool), a);
        return pool.mintWithBase(msg.sender, msg.sender, ptBought, minRatio, maxRatio);
    }

    /// @notice burn liquidity tokens in exchange for underlying and PT.
    /// @param u the address of the underlying token
    /// @param m the maturity of the principal token
    /// @param minRatio minimum ratio of underlying to PT in the pool.
    /// @param maxRatio maximum ratio of underlying to PT in the pool.
    /// @return uint256 amount of tokens burned and returned (tokensBurned, underlyings, PTs).
    function burn(address u, uint256 m, uint256 minRatio, uint256 maxRatio) external returns (uint256, uint256, uint256) {
        return IPool(pools[u][m]).burn(msg.sender, msg.sender, minRatio, maxRatio);
    }

    /// @notice burn liquidity tokens in exchange for underlying.
    /// @param u the address of the underlying token
    /// @param m the maturity of the principal token
    /// @param minRatio minimum ratio of underlying to PT in the pool.
    /// @param maxRatio minimum ratio of underlying to PT in the pool.
    /// @return uint256 amount of underlying tokens returned
    /// @return uint256 amount of PT tokens sent to the pool
    function burnForUnderlying(address u, uint256 m, uint256 minRatio, uint256 maxRatio) external returns (uint256, uint256) {
        return IPool(pools[u][m]).burnForBase(msg.sender, minRatio, maxRatio);
    }

    /// @notice ensures that only a certain address can call the function
    /// @param a address that msg.sender must be to be authorized
    modifier authorized(address a) {
        if (msg.sender != a) {
            revert Unauthorized();
        }
        _;
    }
}