// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import '../interfaces/ISwapRouter.sol';
import '../interfaces/ILimitGrid.sol';
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/**
 * @title UniLimitHelper
 * @dev Helper contract for interacting with UniLimit grid strategy contracts
 * Provides functions to query grid information and find optimal pools
 */
contract UniLimitHelper {
    IUniswapV3Factory public uniFactory;

    /**
     * @dev Struct containing grid strategy information
     * @param gridScheme Basic grid parameters
     * @param status Current strategy status
     * @param currentPrice Current market price
     * @param lastPrice Last recorded price
     * @param tokenBalances Token balances and decimals information
     */
    struct GridInfo {
        ILimitGrid.GridScheme gridScheme;
        ILimitGrid.GridStrategyStatus status;
        uint256 currentPrice;
        uint256 lastPrice;
        TokenBalances tokenBalances;
    }

    /**
     * @dev Struct containing token balance information
     * @param token0Balance Balance of token0
     * @param token1Balance Balance of token1
     * @param token0Decimals Decimals of token0
     * @param token1Decimals Decimals of token1
     */
    struct TokenBalances {
        uint256 token0Balance;
        uint256 token1Balance;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    /**
     * @notice Constructor
     * @param _uniFactory Address of Uniswap V3 Factory contract
     */
    constructor(address _uniFactory) {
        uniFactory = IUniswapV3Factory(_uniFactory);
    }

    /**
     * @notice Get complete information about a grid strategy
     * @param gridAddress Address of the grid strategy contract
     * @return Complete grid information including status and balances
     */
    function getGridInfo(address gridAddress) external view returns (GridInfo memory) {
        ILimitGrid grid = ILimitGrid(gridAddress);
        ILimitGrid.GridScheme memory scheme = grid.gridScheme();
        
        ILimitGrid.GridStrategyStatus status = grid.status();
        uint256 currentPrice = grid.getPriceFromOracle();
        uint256 lastPrice = grid.lastPrice();
        
        IERC20 token0 = IERC20(grid.token0());
        IERC20 token1 = IERC20(grid.token1());
        
        TokenBalances memory balances = TokenBalances({
            token0Balance: token0.balanceOf(gridAddress),
            token1Balance: token1.balanceOf(gridAddress),
            token0Decimals: IERC20Metadata(address(token0)).decimals(),
            token1Decimals: IERC20Metadata(address(token1)).decimals()
        });

        return GridInfo({
            gridScheme: scheme,
            status: status,
            currentPrice: currentPrice,
            lastPrice: lastPrice,
            tokenBalances: balances
        });
    }

    /**
     * @notice Check if a grid strategy needs rebalancing
     * @param gridAddress Address of the grid strategy contract
     * @return needSwap Whether rebalancing is needed
     */
    function checkRebalanceNeeded(address gridAddress) public view returns (
        bool needSwap
    ) {
        ILimitGrid grid = ILimitGrid(gridAddress);
        return grid.checkRebalanceNeeded();
    }

    /**
     * @notice Check if a grid strategy can be activated
     * @param gridAddress Address of the grid strategy contract
     * @return canActivate Whether the strategy can be activated
     */
    function checkCanActivate(address gridAddress) public view returns (
        bool canActivate
    ) {
        ILimitGrid grid = ILimitGrid(gridAddress);
        ILimitGrid.GridScheme memory gridScheme = grid.gridScheme();
        uint256 currentPrice = grid.getPriceFromOracle();
        if (grid.status() != ILimitGrid.GridStrategyStatus.Inactive || currentPrice > gridScheme.upperPrice || currentPrice < gridScheme.lowerPrice) {
            return false;
        }
        if(gridScheme.totalInvestment == 0 && currentPrice < gridScheme.triggerPrice || gridScheme.extraToken1Amount == 0 && currentPrice > gridScheme.triggerPrice) {
            return false;
        }
        return true;
    }

    /**
     * @notice Get current price from Uniswap V3 pool
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param poolFee Pool fee tier
     * @return uniPrice Current price from pool
     */
    function getPriceFromOracle(address token0, address token1, uint24 poolFee) public view returns (uint256 uniPrice) {
        address poolAddr = uniFactory.getPool(token0, token1, poolFee);
        if(poolAddr == address(0)) {
            return 0;
        }

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        if(token0 > token1) {
            uniPrice = uint256(sqrtPriceX96) ** 2 / (1 << 60) * 1e18 / (1 << 132);
        } else {
            uniPrice = 1e18 * (1 << 192) / (uint256(sqrtPriceX96) ** 2);
        }
    }

    /**
     * @notice Find the most liquid pool for a token pair
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @return bestFee Fee tier of the most liquid pool
     */
    function findMostLiquidPool(
        address token0,
        address token1
    ) public view returns (uint24 bestFee) {
        // Define supported fee tiers
        uint24[] memory fees = new uint24[](3);
        fees[0] = 500;   // 0.05%
        fees[1] = 3000;  // 0.3%
        fees[2] = 10000; // 1%

        uint128 maxLiquidity = 0;
        
        // Find pool with highest liquidity
        for (uint i = 0; i < fees.length; i++) {
            address poolAddress = uniFactory.getPool(token0, token1, fees[i]);
            
            if (poolAddress != address(0)) {
                IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
                
                uint128 liquidity = pool.liquidity();
                if (liquidity > maxLiquidity) {
                    maxLiquidity = liquidity;
                    bestFee = fees[i];
                }
            }
        }
        return bestFee;
    }

    function batchCheckCanActivate(address[] calldata gridAddresses) external view returns (
        bool[] memory results
    ) {
        results = new bool[](gridAddresses.length);
        
        for (uint256 i = 0; i < gridAddresses.length; i++) {
            results[i] = this.checkCanActivate(gridAddresses[i]);
        }
        
        return results;
    }

    function batchCheckRebalanceNeeded(address[] calldata gridAddresses) external view returns (
        bool[] memory results
    ) {
        results = new bool[](gridAddresses.length);
        
        for (uint256 i = 0; i < gridAddresses.length; i++) {
            results[i] = this.checkRebalanceNeeded(gridAddresses[i]);
        }
        
        return results;
    }

    function checkGridStrategyStatus(address[] calldata gridAddresses) external view returns (
        ILimitGrid.GridStrategyStatus[] memory statuses
    ) {
        statuses = new ILimitGrid.GridStrategyStatus[](gridAddresses.length);
        
        for (uint256 i = 0; i < gridAddresses.length; i++) {
            ILimitGrid grid = ILimitGrid(gridAddresses[i]);
            statuses[i] = grid.status();
        }
        
        return statuses;
    }
} 