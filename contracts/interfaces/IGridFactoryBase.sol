// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IGridFactoryBase {
    function swapFeeRate() external view returns(uint256);
    function getExecutionFee(address token) external view returns(uint256);
    function feeAddr() external view returns(address);
    function notifyUpdated(address token, uint256 value) external;
}