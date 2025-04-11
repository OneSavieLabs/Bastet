pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

interface veNFR {
    struct receiptInstance {
        uint receiptID;
        uint attachedNFT;
        uint lockedAmount;
        uint lockedDate;
        uint decimals;
        address vault;
        address underlying;
    }

    function getDataByReceipt(
        uint receiptID
    ) external view returns (receiptInstance memory);
}

interface IBuyOrderFactory {
    function emitDelete(address buyOrder) external;
    function emitUpdate(address buyOrder) external;
    function _deleteBuyOrder(address buyOrder) external;
    function sellFee() external view returns (uint);
    function feeAddress() external view returns (address);
}
contract BuyOrder is Initializable {
    using SafeERC20 for IERC20;

    struct BuyInfo {
        address buyOrderAddress;
        address wantedToken;
        uint buyRatio;
        uint availableAmount;
        uint capturedAmount;
        address owner;
        address buyToken;
        bool isActive;
    }

    BuyInfo public buyInformation;
    address buyOrderFactory;

    modifier onlyOwner() {
        require(msg.sender == buyInformation.owner, "Only owner");
        _;
    }

    function initialize(
        address _owner,
        address _token,
        address wantedToken,
        address factory,
        uint _amount,
        uint ratio
    ) public initializer {
        buyInformation = BuyInfo({
            buyOrderAddress: address(this),
            wantedToken: wantedToken,
            buyRatio: ratio,
            availableAmount: _amount,
            capturedAmount: 0,
            owner: _owner,
            buyToken: _token,
            isActive: true
        });
        buyOrderFactory = factory;
    }

    function deleteBuyOrder() public onlyOwner {
        require(buyInformation.isActive, "Buy order is not active");
        // save amount on memory
        uint amount = buyInformation.availableAmount;
        buyInformation.isActive = false;
        buyInformation.availableAmount = 0;

        SafeERC20.safeTransfer(
            IERC20(buyInformation.buyToken),
            buyInformation.owner,
            amount
        );

        IBuyOrderFactory(buyOrderFactory)._deleteBuyOrder(address(this));
        IBuyOrderFactory(buyOrderFactory).emitDelete(address(this));
    }

    function sellNFT(uint receiptID) public {
        require(buyInformation.isActive, "Buy order is not active");
        require(
            buyInformation.availableAmount > 0,
            "Buy order is not available"
        );

        IERC721(buyInformation.wantedToken).transferFrom(
            msg.sender,
            address(this),
            receiptID
        );
        veNFR receipt = veNFR(buyInformation.wantedToken);
        veNFR.receiptInstance memory receiptData = receipt.getDataByReceipt(
            receiptID
        );
        uint collateralAmount = receiptData.lockedAmount;
        uint collateralDecimals = receiptData.decimals;

        uint amount = (buyInformation.buyRatio * collateralAmount) /
            (10 ** collateralDecimals);
        require(
            amount <= buyInformation.availableAmount,
            "Amount exceeds available amount"
        );

        buyInformation.availableAmount -= amount;
        buyInformation.capturedAmount += collateralAmount;
        uint feeAmount = (amount *
            IBuyOrderFactory(buyOrderFactory).sellFee()) / 10000;
        SafeERC20.safeTransfer(
            IERC20(buyInformation.buyToken),
            msg.sender,
            amount - feeAmount
        );

        SafeERC20.safeTransfer(
            IERC20(buyInformation.buyToken),
            IBuyOrderFactory(buyOrderFactory).feeAddress(),
            feeAmount
        );

        if (buyInformation.availableAmount == 0) {
            buyInformation.isActive = false;
            IBuyOrderFactory(buyOrderFactory).emitDelete(address(this));
            IBuyOrderFactory(buyOrderFactory)._deleteBuyOrder(address(this));
        } else {
            IBuyOrderFactory(buyOrderFactory).emitUpdate(address(this));
        }
    }

    function getBuyInfo() public view returns (BuyInfo memory) {
        return buyInformation;
    }
}
