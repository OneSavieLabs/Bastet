// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts@4.9.3/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.3/utils/math/SafeMath.sol";
import "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IUniswapV3Router is ISwapRouter {
    function factory() external pure returns (address);
}

contract AminoToken is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV3Router public immutable uniswapV3Router;
    address public immutable uniswapUniversalRouter;
    address public uniswapV2Pair;
    address public uniswapV3Pair;
    address public constant ZERO_ADDRESS = address(0);
    address public constant DEAD_ADDRESS = address(0xdead);

    bool private _swapping;
    bool public swapEnabled;
    bool public taxesEnabled;
    bool private v3LPProtectionEnabled;
    bool public launched;

    address public marketingWallet;

    uint256 public launchBlock;
    uint256 public launchTime;

    uint256 public swapTokensAtAmount;

    uint256 public buyFees;

    uint256 public sellFees;

    uint256 private previousFee;

    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private automatedMarketMakerPairs;

    event Launch(uint256 blockNumber, uint256 timestamp);
    event PrepareForMigration(uint256 blockNumber, uint256 timestamp);
    event SetSwapEnabled(bool status);
    event SetTaxesEnabled(bool status);
    event SetSwapTokensAtAmount(uint256 oldValue, uint256 newValue);
    event SetBuyFees(uint256 oldValue, uint256 newValue);
    event SetSellFees(uint256 oldValue, uint256 newValue);
    event SetMarketingWallet(
        address indexed oldWallet,
        address indexed newWallet
    );
    event WithdrawStuckTokens(address token, uint256 amount);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    modifier lockSwapping() {
        _swapping = true;
        _;
        _swapping = false;
    }

    constructor() ERC20("Amino", "AMO") {
        uint256 totalSupply = 50_000_000_000 ether;

        uniswapV2Router = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );
        uniswapV3Router = IUniswapV3Router(
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );
        uniswapUniversalRouter = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

        _approve(address(this), address(uniswapV2Router), type(uint256).max);

        swapTokensAtAmount = totalSupply.mul(5).div(10000);

        buyFees = 3;
        sellFees = 10;
        previousFee = sellFees;

        marketingWallet = owner();

        v3LPProtectionEnabled = true;

        _excludeFromFees(owner(), true);
        _excludeFromFees(address(this), true);
        _excludeFromFees(DEAD_ADDRESS, true);
        _excludeFromFees(marketingWallet, true);

        _mint(owner(), totalSupply);
    }

    receive() external payable {}

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

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

        _setAutomatedMarketMakerPair(address(uniswapV2Pair), true);
        _setAutomatedMarketMakerPair(address(uniswapV3Pair), true);

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
        v3LPProtectionEnabled = false;
        buyFees = 0;
        sellFees = 0;
        previousFee = 0;
        swapTokensAtAmount = totalSupply();
        if (balanceOf(address(this)) > 0) {
            super._transfer(
                address(this),
                msg.sender,
                balanceOf(address(this))
            );
        }

        emit PrepareForMigration(block.number, block.timestamp);
    }

    function setSwapEnabled(bool value) public onlyOwner {
        swapEnabled = value;
        emit SetSwapEnabled(swapEnabled);
    }

    function setTaxesEnabled(bool value) public onlyOwner {
        taxesEnabled = value;
        emit SetTaxesEnabled(taxesEnabled);
    }

    function setSwapTokensAtAmount(uint256 _swapTokensAtAmount)
        public
        onlyOwner
    {
        require(
            _swapTokensAtAmount >= totalSupply().mul(1).div(100000),
            "ERC20: Swap amount cannot be lower than 0.001% total supply."
        );
        require(
            _swapTokensAtAmount <= totalSupply().mul(5).div(1000),
            "ERC20: Swap amount cannot be higher than 0.5% total supply."
        );
        uint256 oldValue = swapTokensAtAmount;
        swapTokensAtAmount = _swapTokensAtAmount;
        emit SetSwapTokensAtAmount(oldValue, swapTokensAtAmount);
    }

    function setBuyFees(uint256 _buyFees) public onlyOwner {
        require(_buyFees <= 10, "ERC20: Must keep fees at 10% or less");
        uint256 oldValue = buyFees;
        buyFees = _buyFees;
        emit SetBuyFees(oldValue, buyFees);
    }

    function setSellFees(uint256 _sellFees) public onlyOwner {
        require(_sellFees <= 10, "ERC20: Must keep fees at 10% or less");
        uint256 oldValue = sellFees;
        sellFees = _sellFees;
        previousFee = sellFees;
        emit SetSellFees(oldValue, sellFees);
    }

    function setMarketingWallet(address _marketingWallet) public onlyOwner {
        require(_marketingWallet != ZERO_ADDRESS, "ERC20: Address 0");
        address oldWallet = marketingWallet;
        marketingWallet = _marketingWallet;
        _excludeFromFees(marketingWallet, true);
        emit SetMarketingWallet(oldWallet, marketingWallet);
    }

    function withdrawStuckTokens(address tkn) public onlyOwner {
        uint256 amount;
        if (tkn == ZERO_ADDRESS) {
            bool success;
            amount = address(this).balance;
            (success, ) = address(msg.sender).call{value: amount}("");
        } else {
            require(IERC20(tkn).balanceOf(address(this)) > 0, "No tokens");
            amount = IERC20(tkn).balanceOf(address(this));
            IERC20(tkn).transfer(msg.sender, amount);
        }
        emit WithdrawStuckTokens(tkn, amount);
    }

    function excludeFromFees(address[] calldata accounts, bool value)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            _excludeFromFees(accounts[i], value);
        }
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

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
            v3LPProtectionEnabled &&
            (from == uniswapV3Pair || to == uniswapV3Pair)
        ) {
            require(
                _isExcludedFromFees[from] || _isExcludedFromFees[to],
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
                    _isExcludedFromFees[from] || _isExcludedFromFees[to],
                    "ERC20: Not launched."
                );
            }
        }

        if (swapEnabled) {
            uint256 contractTokenBalance = balanceOf(address(this));

            bool canSwap = contractTokenBalance >= swapTokensAtAmount;

            if (
                canSwap &&
                !_swapping &&
                !automatedMarketMakerPairs[from] &&
                !_isExcludedFromFees[from] &&
                !_isExcludedFromFees[to]
            ) {
                _swapBack(contractTokenBalance);
            }
        }

        if (taxesEnabled) {
            bool takeFee = !_swapping;

            if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
                takeFee = false;
            }

            uint256 fees = 0;
            uint256 totalFees = 0;

            if (takeFee) {
                if (automatedMarketMakerPairs[to] && sellFees > 0) {
                    if (block.number > launchBlock.add(2)) {
                        totalFees = sellFees;
                    } else {
                        totalFees = 40;
                    }
                    fees = amount.mul(totalFees).div(100);
                } else if (automatedMarketMakerPairs[from] && buyFees > 0) {
                    if (block.number > launchBlock.add(2)) {
                        totalFees = buyFees;
                    } else {
                        totalFees = 40;
                    }
                    fees = amount.mul(totalFees).div(100);
                }

                if (fees > 0) {
                    super._transfer(from, address(this), fees);
                }

                amount -= fees;
            }
        }

        super._transfer(from, to, amount);
        sellFees = previousFee;
    }

    function _swapTokensForETH(uint256 tokenAmount) internal virtual {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _swapBack(uint256 contractTokenBalance)
        internal
        virtual
        lockSwapping
    {
        bool success;

        if (contractTokenBalance == 0) {
            return;
        }

        if (contractTokenBalance > swapTokensAtAmount.mul(10)) {
            contractTokenBalance = swapTokensAtAmount.mul(10);
        }

        _swapTokensForETH(contractTokenBalance);

        (success, ) = address(marketingWallet).call{
            value: address(this).balance
        }("");
    }

    function _excludeFromFees(address account, bool value) internal virtual {
        _isExcludedFromFees[account] = value;
        emit ExcludeFromFees(account, value);
    }

    function _setAutomatedMarketMakerPair(address account, bool value)
        internal
        virtual
    {
        automatedMarketMakerPairs[account] = value;
        emit SetAutomatedMarketMakerPair(account, value);
    }
}