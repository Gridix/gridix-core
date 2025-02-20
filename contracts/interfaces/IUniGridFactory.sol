// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import './IGridFactoryBase.sol';

interface IUniGridFactory is IGridFactoryBase {
    function uniFactory() external view returns(address);
    function uniSwapRouter() external view returns(address);
    function nonfungiblePositionManager() external view returns(address);
}