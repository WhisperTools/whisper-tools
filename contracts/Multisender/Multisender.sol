// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Multisender is Ownable, Pausable {
    using Address for address;
    using SafeMath for uint256;

    address payable feeReceiver =
        payable(0xaCE5005f3E960A8e9Bfbe95f0fa6C925858a7272);

    uint256 lockFee = 0.05 ether;

    mapping(address => bool) private listFreeTokens;

    modifier onlyContract(address account) {
        require(
            account.isContract(),
            "The address does not contain a contract"
        );
        _;
    }

    constructor() {
        listFreeTokens[0xc8Ec5B0627C794de0e4ea5d97AD9A556B361d243] = true; // WISP
        listFreeTokens[0xBe21BCD3a21dC4Dd6C58945f0F5DE4132644020a] = true; // vMLP (WETH/WISP)
    }

    receive() external payable {}

    fallback() external payable {}

    function multisendETH(
        address[] memory recipients,
        uint256[] memory values
    ) external payable {
        _chargeFees(address(0));
        for (uint256 i = 0; i < recipients.length; i++)
            payable(recipients[i]).transfer(values[i]);
        uint256 balance = address(this).balance;
        if (balance > 0) address(msg.sender).call{value: balance};
    }

    function multisendToken(
        IERC20 token,
        address[] memory recipients,
        uint256[] memory values
    ) external {
        _chargeFees(address(token));
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++) total += values[i];
        require(token.transferFrom(msg.sender, address(this), total));
        for (uint256 i = 0; i < recipients.length; i++)
            require(token.transfer(recipients[i], values[i]));
    }

    function multisendTokenSimple(
        IERC20 token,
        address[] memory recipients,
        uint256[] memory values
    ) external {
        _chargeFees(address(token));
        for (uint256 i = 0; i < recipients.length; i++)
            require(token.transferFrom(msg.sender, recipients[i], values[i]));
    }

    function _chargeFees(address _tokenAddress) internal {
        uint256 minRequiredFeeInEth = getFeesInETH(_tokenAddress);
        if (minRequiredFeeInEth > 0) {
            bool feesBelowMinRequired = msg.value < minRequiredFeeInEth;
            uint256 feeDiff = feesBelowMinRequired
                ? SafeMath.sub(minRequiredFeeInEth, msg.value)
                : SafeMath.sub(msg.value, minRequiredFeeInEth);

            if (feesBelowMinRequired) {
                uint256 feeSlippagePercentage = feeDiff.mul(100).div(
                    minRequiredFeeInEth
                );
                //will allow if diff is less than 5%
                require(feeSlippagePercentage <= 5, "Fee not met");
            }
            (bool success, ) = feeReceiver.call{
                value: feesBelowMinRequired ? msg.value : minRequiredFeeInEth
            }("");
            require(success, "Fee transfer failed");
            bool refundSuccess;
            /* refund difference. */
            if (!feesBelowMinRequired && feeDiff > 0) {
                (refundSuccess, ) = _msgSender().call{value: feeDiff}("");
            }
        }
    }

    function getFeesInETH(address _tokenAddress) public view returns (uint256) {
        //token listed free or fee params not set
        if (isFreeToken(_tokenAddress)) {
            return 0;
        } else {
            return lockFee;
        }
    }

    function isFreeToken(address token) public view returns (bool) {
        return listFreeTokens[token];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setLockFee(uint256 _lockFee) external onlyOwner {
        require(_lockFee >= 0, "fees should be greater or equal 0");
        lockFee = _lockFee;
    }

    function setFeeReceiver(address payable _feeReceiver) external onlyOwner {
        require(_feeReceiver != address(0), "Invalid wallet address");
        feeReceiver = _feeReceiver;
    }

    function addTokenToFreeList(
        address token
    ) external onlyOwner onlyContract(token) {
        listFreeTokens[token] = true;
    }

    function removeTokenFromFreeList(
        address token
    ) external onlyOwner onlyContract(token) {
        listFreeTokens[token] = false;
    }

    function withdrawStuckTokens(address tkn) external onlyOwner {
        bool success;
        if (tkn == address(0))
            (success, ) = address(msg.sender).call{
                value: address(this).balance
            }("");
        else {
            require(IERC20(tkn).balanceOf(address(this)) > 0);
            uint256 amount = IERC20(tkn).balanceOf(address(this));
            IERC20(tkn).transfer(msg.sender, amount);
        }
    }
}
