// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IUniGrid {
    enum GridStrategyStatus {
        Inactive, 
        Active,
        Closed
    }
    struct GridScheme{
        uint256 lowerPrice;
        uint256 upperPrice;
        uint256 gridCount;
        uint256 totalInvestment;
        uint256 extraToken1Amount;
    }
    function gridScheme() external view returns(GridScheme memory);
    function status() external view returns(GridStrategyStatus);
    function uniswapV3Factory() external view returns(address);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function poolFee() external view returns(uint24);
    function getPriceFromOracle() external view returns(uint256);
    function lowerTokenId() external view returns(uint256);
    function upperTokenId() external view returns(uint256);
    function nonfungiblePositionManager() external view returns(address);
    function uniSwapRouter() external view returns(address);
    function checkRebalanceNeeded() external view returns(bool);

}