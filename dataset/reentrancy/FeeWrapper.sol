// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./RubiconRouter.sol";

/// @notice allows 3rd party protocols to charge their own fees, from interatcions with the Rubicon Protocol
contract FeeWrapper {
    // libs
    using SafeERC20 for IERC20;

    struct CallParams {
        bytes4 selector; // function selector
        bytes args; // encoded arguments (abi.encode() || abi.encodePacked)
        address target; // target contract to call
        FeeParams feeParams;
    }

    struct FeeParams {
        address feeToken; // token in the form of which fee paid
        uint256 totalAmount; // amount without deducted fee
        uint256 feeAmount; // amount of feeToken from which fee should be charged
        address feeTo; // receiver of the fee
    }

    //============================= VIEW =============================
    /// @notice should be used to make proper FeeParams struct
    function calculateFee(
        uint256[] memory tokenAmounts,
        uint256 feeType,
        uint256 feeValue
    )
        external
        view
        returns (uint256[] memory amountsWithFee, uint256[] memory fees)
    {
        amountsWithFee = new uint256[](tokenAmounts.length);
        fees = new uint256[](tokenAmounts.length);

        for (uint256 i = 0; i < tokenAmounts.length; ++i) {
            fees[i] = (tokenAmounts[i] * feeValue) / feeType;
            amountsWithFee[i] = tokenAmounts[i] - fees[i];
        }
    }

    //============================= MAIN =============================
    /// @notice execute low-level call to the Rubicon Protocol
    function rubicall(
        CallParams memory params
    ) external payable returns (bytes memory) {
        if (msg.value == 0) {
            return _rubicall(params);
        } else {
            return _rubicallPayable(params);
        }
    }

    //============================= ROUTER-INTERNALS =============================
    /// @notice defaull call to the router functions
    function _rubicall(
        CallParams memory _params
    ) internal returns (bytes memory) {
        // charge fee from feeParams
        _chargeFee(_params.feeParams, _params.target);

        (bool _OK, bytes memory _data) = _params.target.call(
            bytes.concat(_params.selector, _params.args)
        );

        require(_OK, "low-level call to the Rubicon failed");

        return _data;
    }

    /// @notice rotuer call with ETH sent
    function _rubicallPayable(
        CallParams memory _params
    ) internal returns (bytes memory) {
        // charge fee from feeParams
        uint256 _msgValue = _chargeFeePayable(_params.feeParams);

        (bool _OK, bytes memory _data) = _params.target.call{value: _msgValue}(
            bytes.concat(_params.selector, _params.args)
        );

        require(_OK, "low-level call to the router failed");

        return _data;
    }

    //============================= FEE-INTERNALS =============================
    /// @param _target - target Rubicon contract on which needed function will be called
    function _chargeFee(FeeParams memory _feeParams, address _target) internal {
        address _feeToken = _feeParams.feeToken;
        uint256 _totalAmount = _feeParams.totalAmount;
        uint256 _feeAmount = _feeParams.feeAmount;
        address _feeTo = _feeParams.feeTo;

        // transfer total amount to the FeeWrapper
        IERC20(_feeToken).transferFrom(msg.sender, address(this), _totalAmount);
        // transfer fee to the 3rd party protocol
        IERC20(_feeToken).transfer(_feeTo, _feeAmount);

        // approve tokens to the `_target`
        IERC20(_feeToken).approve(_target, (_totalAmount - _feeAmount));
    }

    function _chargeFeePayable(
        FeeParams memory _feeParams
    ) internal returns (uint256 _msgValue) {
        // _feeToken is ETH
        uint256 _totalAmount = _feeParams.totalAmount;
        uint256 _feeAmount = _feeParams.feeAmount;
        address _feeTo = _feeParams.feeTo;
        require(msg.value == _totalAmount, "FeeWrapper: not enough ETH sent");

        // transfer fee to the 3rd party protocol
        (bool OK, ) = payable(_feeTo).call{value: _feeAmount}("");
		require(OK, "ETH transfer failed");
        _msgValue = msg.value - _feeAmount;
    }
}
