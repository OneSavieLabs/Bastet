// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interface/IToken.sol";

interface IUniswapV3Router is ISwapRouter {
    function factory() external pure returns (address);
}

contract LendsToken is ERC20, Ownable, IToken {
    using SafeMath for uint256;

    /* ///////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////
    */
    address public constant ZERO_ADDRESS = address(0);
    address public constant DEAD_ADDRESS = address(0xdead);

    /* ///////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////
    */
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV3Router public immutable uniswapV3Router;
    address public immutable uniswapUniversalRouter;

    address public uniswapV2Pair;
    address public uniswapV3Pair;

    address public taxWallet;

    bool private _swapping;
    bool private _v3LPProtectionEnabled;

    bool public swapEnabled;
    bool public taxesEnabled;
    bool public launched;

    uint256 public launchBlock;
    uint256 public launchTime;

    uint256 public buyTax;
    uint256 public sellTax;

    uint256 public swapBackTreshold;

    mapping(address => bool) private _isExcludedFromTaxes;
    mapping(address => bool) private _ammPairs;

    /* ///////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////
    */
    modifier lockSwapping() {
        _swapping = true;
        _;
        _swapping = false;
    }

    /* ///////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////
    */
    constructor() ERC20("Lends", "LENDS") {
        uint256 totalSupply = 625_000_000 ether;

        uniswapV2Router = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );
        uniswapV3Router = IUniswapV3Router(
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );
        uniswapUniversalRouter = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

        _approve(address(this), address(uniswapV2Router), type(uint256).max);

        buyTax = 10;
        sellTax = 10;
        swapBackTreshold = 1000 ether;

        taxWallet = owner();

        _v3LPProtectionEnabled = true;

        _excludeFromTaxes(address(this), true);
        _excludeFromTaxes(DEAD_ADDRESS, true);
        _excludeFromTaxes(taxWallet, true);

        _mint(0x93eeDD7bD39AE01Ca70DBE1c83Becb4edb183F19, totalSupply.mul(672).div(10000));
        _mint(0xd3E3fea8aB5b15D7518Aae04E4011b5eCd9fc102, totalSupply.mul(672).div(10000));
        _mint(0x29D82FE41C0bED5EC6194bD2a1c0e7E10f99e08A, totalSupply.mul(672).div(10000));
        _mint(0x3d48F3c2428E203C49127059A1FA1F0ce176910c, totalSupply.mul(672).div(10000));
        _mint(0x7e88F13F8B83e8574109675e02e59c9A9937f377, totalSupply.mul(672).div(10000));
        _mint(0x0919f02BE673B261A0bb496C9d546B76EF86A8Da, totalSupply.mul(672).div(10000));
        _mint(0x6d6e242e51F5285332fCD25F7F367E44AF9BAa23, totalSupply.mul(672).div(10000));
        _mint(0x3fbC174Eb1Dbc409CA2C3645BA6495C64102d42c, totalSupply.mul(672).div(10000));
        _mint(0x5396037E85184aE7F05D5d2238132316be375997, totalSupply.mul(267).div(10000));
        _mint(0xd663a350E661bb17A7cF6A2062B0c72a6a073FfD, totalSupply.mul(267).div(10000));
        _mint(0x56D60F732949E4592c016C9271883d2779eF385F, totalSupply.mul(267).div(10000));
        _mint(0x26B39d684c0d50c8eFA9B8B1Cdf518E96fFbf339, totalSupply.mul(160).div(10000));
        _mint(0xf1112CE591A22e54199Ff9e0Ac3ed130a7Cac083, totalSupply.mul(863).div(10000));
        _mint(0xc93a8Ea37FE474C4e0885FE498382E79D48cecA3, totalSupply.mul(160).div(10000));
        _mint(0xD4482C319101f76BbFb84668385f5D008cA25c3d, totalSupply.mul(250).div(10000));
        _mint(0x4F746C1844B15D8B31B9156c08A67d6970149EC9, totalSupply.mul(250).div(10000));
        _mint(0x56a54c59Bb09715b51E692D50536c2751eFcF9F4, totalSupply.mul(10).div(10000));
        _mint(0x5Eb9e728DEf0b9aA7ADf14d58E920FDeA72fACe0, totalSupply.mul(142).div(10000));
        _mint(0x4D64CEB8B90Ab76F103663f2bDDa403E47106838, totalSupply.mul(142).div(10000));
        _mint(0x90cdbD2e17B25E346046689e493efd887400bfff, totalSupply.mul(142).div(10000));
        _mint(0x5882e509b64eA399F7F5aF603e918B11bF46dDC8, totalSupply.mul(142).div(10000));
        _mint(0x5D7040CFf7FB596405192c4d934821e789Af900A, totalSupply.mul(142).div(10000));
        _mint(0x6B24fc2B374e0D6D54c84E30b938de5d0241b091, totalSupply.mul(142).div(10000));
        _mint(0xd55f2253805999f28a6B2BA5860e8CA4eA41e5d6, totalSupply.mul(142).div(10000));
        _mint(0xf791f5B16e39903a9f9E1261E5D65C856B5068f2, totalSupply.mul(142).div(10000));
        _mint(0x9124b3E632761c9f9E2Cd320315633D9C1439EB7, totalSupply.mul(142).div(10000));
        _mint(0xA6D35D849Eb053B9F9e165Cc46c74eF3cb7781Ad, totalSupply.mul(142).div(10000));
        _mint(0x566E0D8dC3BCD83508b59a2D4A7Bf069d709420E, totalSupply.mul(142).div(10000));
        _mint(0x7bB8427897B2237C9d1FF9dDbe443A65a2D123DE, totalSupply.mul(142).div(10000));
        _mint(0x1b0853Ee67Ca33206B55BB30B8111E6519Ca6079, totalSupply.mul(142).div(10000));
        _mint(0x92B963e84c586993f624e489f0c0aa0820Ead859, totalSupply.mul(142).div(10000));
        _mint(0x1aaE81943aAd50527913070ABd86C3a64DE2D774, totalSupply.mul(142).div(10000));
    }

    /* ///////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////
    */
    function launch() public onlyOwner {
        require(!launched, "ERC20: Already launched.");

        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(
            address(this),
            uniswapV2Router.WETH()
        );

        if (uniswapV2Pair == ZERO_ADDRESS) {
            uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                .createPair(address(this), uniswapV2Router.WETH());
        }

        uniswapV3Pair = IUniswapV3Factory(uniswapV3Router.factory()).createPool(
                address(this),
                uniswapV2Router.WETH(),
                10000
            );

        _approve(address(this), address(uniswapV2Pair), type(uint256).max);
        _approve(address(this), address(uniswapV3Pair), type(uint256).max);

        IERC20(uniswapV2Pair).approve(
            address(uniswapV2Router),
            type(uint256).max
        );

        _setAMMPair(address(uniswapV2Pair), true);
        _setAMMPair(address(uniswapV3Pair), true);

        uniswapV2Router.addLiquidityETH{value: address(this).balance}(
            address(this),
            balanceOf(address(this)),
            0,
            0,
            owner(),
            block.timestamp
        );

        swapEnabled = true;
        taxesEnabled = true;
        launched = true;

        launchBlock = block.number;
        launchTime = block.timestamp;

        emit Launch(launchBlock, launchTime);
    }

    function prepareForMigration() public onlyOwner {
        swapEnabled = false;
        taxesEnabled = false;
        _v3LPProtectionEnabled = false;

        buyTax = 0;
        sellTax = 0;

        swapBackTreshold = totalSupply();

        if (balanceOf(address(this)) > 0) {
            super._transfer(
                address(this),
                msg.sender,
                balanceOf(address(this))
            );
        }

        emit PrepareForMigration(block.number, block.timestamp);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function withdrawStuckTokens(address _token) public onlyOwner {
        uint256 amount;
        if (_token == ZERO_ADDRESS) {
            bool success;
            amount = address(this).balance;
            (success, ) = address(msg.sender).call{value: amount}("");
        } else {
            require(IERC20(_token).balanceOf(address(this)) > 0, "No tokens");
            amount = IERC20(_token).balanceOf(address(this));
            IERC20(_token).transfer(msg.sender, amount);
        }
        emit WithdrawStuckTokens(_token, amount);
    }

    /* ///////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////
    */
    function setBuyTax(uint256 _tax) public onlyOwner {
        require(_tax <= 20, "setBuyTax: Must keep tax at 20% or less");
        uint256 oldValue = buyTax;
        buyTax = _tax;
        emit SetBuyTaxes(oldValue, buyTax);
    }

    function setSellTax(uint256 _tax) public onlyOwner {
        require(_tax <= 20, "setSellTax: Must keep tax at 20% or less");
        uint256 oldValue = sellTax;
        sellTax = _tax;
        emit SetSellTaxes(oldValue, sellTax);
    }

    function setTaxWallet(address _taxWallet) public onlyOwner {
        require(_taxWallet != ZERO_ADDRESS, "ERC20: Address 0");
        address oldWallet = taxWallet;
        taxWallet = _taxWallet;
        _excludeFromTaxes(_taxWallet, true);
        emit SetTaxWallet(oldWallet, taxWallet);
    }

    function setSwapEnabled(bool _value) public onlyOwner {
        swapEnabled = _value;
        emit SetSwapEnabled(swapEnabled);
    }

    function setTaxesEnabled(bool _value) public onlyOwner {
        taxesEnabled = _value;
        emit SetTaxesEnabled(taxesEnabled);
    }

    function setSwapBackTreshold(uint256 _amount) public onlyOwner {
        uint256 oldValue = swapBackTreshold;
        swapBackTreshold = _amount;
        emit SetSwapBackTreshold(oldValue, swapBackTreshold);
    }

    function excludeFromTaxes(
        address[] calldata _wallets,
        bool _value
    ) public onlyOwner {
        for (uint256 i = 0; i < _wallets.length; i++) {
            _excludeFromTaxes(_wallets[i], _value);
        }
    }

    /* ///////////////////////////////////////////////////////////
                            GETTERS
    //////////////////////////////////////////////////////////////
    */
    function isExcludedFromTaxes(
        address _wallet
    ) public view returns (bool _isExcluded) {
        return _isExcludedFromTaxes[_wallet];
    }

    /* ///////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////
    */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(from != ZERO_ADDRESS, "ERC20: transfer from the zero address");
        require(to != ZERO_ADDRESS, "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (
            _v3LPProtectionEnabled &&
            (from == uniswapV3Pair || to == uniswapV3Pair)
        ) {
            require(
                _isExcludedFromTaxes[from] || _isExcludedFromTaxes[to],
                "ERC20: Not authorized to add LP to Uniswap V3 Pool"
            );
        }

        if (
            from != owner() &&
            to != owner() &&
            to != ZERO_ADDRESS &&
            to != DEAD_ADDRESS &&
            !_swapping
        ) {
            if (!launched) {
                require(
                    _isExcludedFromTaxes[from] || _isExcludedFromTaxes[to],
                    "ERC20: Not launched."
                );
            }
        }

        if (swapEnabled) {
            uint256 balance = balanceOf(address(this));

            bool canSwap = balance >= swapBackTreshold;

            if (
                canSwap &&
                !_swapping &&
                !_ammPairs[from] &&
                !_isExcludedFromTaxes[from] &&
                !_isExcludedFromTaxes[to]
            ) {
                _swapBack(balance);
            }
        }

        if (taxesEnabled) {
            bool takeTax = !_swapping;

            if (_isExcludedFromTaxes[from] || _isExcludedFromTaxes[to]) {
                takeTax = false;
            }

            uint256 taxes = 0;
            uint256 totalTaxes = 0;

            if (takeTax) {
                if (_ammPairs[to] && sellTax > 0) {
                    if (block.number > launchBlock.add(1000)) {
                        totalTaxes = sellTax;
                    } else if (block.number > launchBlock.add(30)) {
                        totalTaxes = 20;
                    } else if (block.number > launchBlock.add(10)) {
                        totalTaxes = 33;
                    } else if (block.number > launchBlock.add(2)) {
                        totalTaxes = 40;
                    } else {
                        totalTaxes = 50;
                    }
                    taxes = amount.mul(totalTaxes).div(100);
                } else if (_ammPairs[from] && buyTax > 0) {
                    if (block.number > launchBlock.add(1000)) {
                        totalTaxes = buyTax;
                    } else if (block.number > launchBlock.add(30)) {
                        totalTaxes = 20;
                    } else if (block.number > launchBlock.add(10)) {
                        totalTaxes = 33;
                    } else if (block.number > launchBlock.add(2)) {
                        totalTaxes = 40;
                    } else {
                        totalTaxes = 50;
                    }
                    taxes = amount.mul(totalTaxes).div(100);
                }

                if (taxes > 0) {
                    super._transfer(from, address(this), taxes);
                }

                amount -= taxes;
            }
        }

        super._transfer(from, to, amount);
    }

    function _swapTokensForETH(uint256 _amount) internal virtual {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), _amount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _swapBack(uint256 _amount) internal virtual lockSwapping {
        bool success;

        if (_amount == 0) return;

        _swapTokensForETH(_amount);

        (success, ) = address(taxWallet).call{value: address(this).balance}("");
    }

    function _excludeFromTaxes(address _wallet, bool _value) internal virtual {
        _isExcludedFromTaxes[_wallet] = _value;
        emit ExcludeFromTaxes(_wallet, _value);
    }

    function _setAMMPair(address _wallet, bool _value) internal virtual {
        _ammPairs[_wallet] = _value;
        emit SetAMMPair(_wallet, _value);
    }

    receive() external payable {}
}