// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface ILimitGrid {
    enum GridStrategyStatus {
        Inactive, 
        Active,
        Closed
    }

    struct GridScheme {
        uint256 lowerPrice;
        uint256 upperPrice;
        uint256 gridCount;
        uint256 totalInvestment;
        uint256 extraToken1Amount;
        uint256 triggerPrice;
    }

    function gridScheme() external view returns(GridScheme memory);
    
    function status() external view returns (GridStrategyStatus);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getPriceFromOracle() external view returns (uint256);
    function lastPrice() external view returns (uint256);
    function checkRebalanceNeeded() external view returns(bool);
} 