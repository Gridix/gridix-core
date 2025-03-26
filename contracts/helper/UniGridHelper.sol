// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import '../interfaces/INonfungiblePositionManager.sol';
import '../interfaces/TickMath.sol';
import '../interfaces/IUniGrid.sol';
import '../grid/UniGrid.sol';

/**
 * @title UniGridHelper
 * @dev Helper contract for interacting with UniGrid strategy contracts
 * Provides functions to query grid information and check strategy status
 */
contract UniGridHelper {
    /**
     * @dev Struct containing complete grid strategy information
     * @param gridScheme Basic grid parameters
     * @param status Current strategy status
     * @param currentPrice Current market price
     * @param lowerTokenId NFT token ID for lower position
     * @param upperTokenId NFT token ID for upper position
     * @param lowerPosition Detailed information about lower position
     * @param upperPosition Detailed information about upper position
     * @param tokenBalances Token balances and decimals information
     */
    struct GridInfo {
        IUniGrid.GridScheme gridScheme;
        IUniGrid.GridStrategyStatus status;
        uint256 currentPrice;
        uint256 lowerTokenId;
        uint256 upperTokenId;
        PositionInfo lowerPosition;
        PositionInfo upperPosition;
        TokenBalances tokenBalances;
    }

    /**
     * @dev Struct containing Uniswap V3 position information
     * @param liquidity Current liquidity amount
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param currentTick Current pool tick
     * @param amount0 Amount of token0 in position
     * @param amount1 Amount of token1 in position
     */
    struct PositionInfo {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint256 amount0;
        uint256 amount1;
    }

    /**
     * @dev Struct containing token balance information
     * @param token0Balance Balance of token0
     * @param token1Balance Balance of token1
     * @param token0Decimals Decimals of token0
     * @param token1Decimals Decimals of token1
     * @param token0IsLower Whether token0 has lower address than token1
     */
    struct TokenBalances {
        uint256 token0Balance;
        uint256 token1Balance;
        uint8 token0Decimals;
        uint8 token1Decimals;
        bool token0IsLower;
    }

    /**
     * @notice Get complete information about a grid strategy
     * @param gridAddress Address of the grid strategy contract
     * @return Complete grid information including positions and balances
     */
    function getGridInfo(address gridAddress) external view returns (GridInfo memory) {
        IUniGrid grid = IUniGrid(gridAddress);
        
        IUniGrid.GridScheme memory scheme = grid.gridScheme();
        IUniGrid.GridStrategyStatus status = grid.status();
        uint256 currentPrice = grid.getPriceFromOracle();
        
        uint256 lowerTokenId = grid.lowerTokenId();
        uint256 upperTokenId = grid.upperTokenId();

        IERC20 token0 = IERC20(grid.token0());
        IERC20 token1 = IERC20(grid.token1());
        
        TokenBalances memory balances = TokenBalances({
            token0Balance: token0.balanceOf(gridAddress),
            token1Balance: token1.balanceOf(gridAddress),
            token0Decimals: IERC20Metadata(address(token0)).decimals(),
            token1Decimals: IERC20Metadata(address(token1)).decimals(),
            token0IsLower: address(token0) < address(token1)
        });

        PositionInfo memory lowerPosition = getPositionInfo(grid, lowerTokenId);
        PositionInfo memory upperPosition = getPositionInfo(grid, upperTokenId);

        return GridInfo({
            gridScheme: scheme,
            status: status,
            currentPrice: currentPrice,
            lowerTokenId: lowerTokenId,
            upperTokenId: upperTokenId,
            lowerPosition: lowerPosition,
            upperPosition: upperPosition,
            tokenBalances: balances
        });
    }

    /**
     * @notice Get detailed information about a specific NFT position
     * @param grid Grid strategy contract
     * @param tokenId NFT token ID
     * @return Position information including liquidity and amounts
     */
    function getPositionInfo(IUniGrid grid, uint256 tokenId) internal view returns (PositionInfo memory) {
        if (tokenId == 0) {
            return PositionInfo(0, 0, 0, 0, 0, 0);
        }

        INonfungiblePositionManager nftManager = INonfungiblePositionManager(grid.nonfungiblePositionManager());
        
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,
        ) = nftManager.positions(tokenId);

        IUniswapV3Pool pool = IUniswapV3Pool(
            IUniswapV3Factory(grid.uniswapV3Factory()).getPool(
                address(grid.token0()),
                address(grid.token1()),
                grid.poolFee()
            )
        );
        
        (, int24 currentTick,,,,,) = pool.slot0();

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            currentTick,
            tickLower,
            tickUpper,
            liquidity,
            pool
        );

        return PositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            currentTick: currentTick,
            amount0: amount0,
            amount1: amount1
        });
    }

    /**
     * @notice Calculate token amounts for given liquidity at current price
     * @param currentTick Current pool tick
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param liquidity Liquidity amount
     * @param pool Uniswap V3 pool contract
     * @return amount0 Amount of token0
     * @return amount1 Amount of token1
     */
    function getAmountsForLiquidity(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        IUniswapV3Pool pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) {
            return (0, 0);
        }

        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();

        if (currentTick < tickLower) {
            amount0 = getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
        } else if (currentTick < tickUpper) {
            amount0 = getAmount0Delta(
                uint160(sqrtRatioX96),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
            amount1 = getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                uint160(sqrtRatioX96),
                liquidity
            );
        } else {
            amount1 = getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
        }
    }

    /**
     * @notice Calculate amount of token0 for given liquidity and price range
     * @param sqrtRatioAX96 Lower sqrt price
     * @param sqrtRatioBX96 Upper sqrt price
     * @param liquidity Liquidity amount
     * @return amount0 Amount of token0
     */
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 numerator1 = uint256(liquidity);
        uint256 numerator2;
        if(numerator1 > type(uint256).max / uint256(sqrtRatioBX96 - sqrtRatioAX96) * 2) {
            numerator2 = numerator1 / uint256(sqrtRatioAX96) * (sqrtRatioBX96 - sqrtRatioAX96);
        } else {
            numerator2 = numerator1 * (sqrtRatioBX96 - sqrtRatioAX96) / uint256(sqrtRatioAX96);
        }
        if(numerator2 > (2**160 - 1)) {
            return mulDiv(numerator2, 1, sqrtRatioAX96 >> 96);
        } else {
            return mulDiv(numerator2, 1 << 96, sqrtRatioAX96);
        }
    }

    /**
     * @notice Calculate amount of token1 for given liquidity and price range
     * @param sqrtRatioAX96 Lower sqrt price
     * @param sqrtRatioBX96 Upper sqrt price
     * @param liquidity Liquidity amount
     * @return amount1 Amount of token1
     */
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint160 numerator = sqrtRatioBX96 - sqrtRatioAX96;
        if(numerator > 2**48) {
            numerator = numerator >> 48;
        } else {
            liquidity = liquidity >> 48;
        }

        return mulDiv(liquidity, numerator, 2**48);
    }

    /**
     * @notice Multiply and divide numbers while handling overflow
     * @param a First number
     * @param b Second number
     * @param denominator Denominator
     * @return result Result of (a * b) / denominator
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        require(denominator > prod1);

        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
        }

        assembly {
            prod0 := div(prod0, twos)
        }
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;

        result = prod0 * inv;
        return result;
    }

    /**
     * @notice Check if a grid strategy needs rebalancing
     * @param gridAddress Address of the grid strategy contract
     * @return needSwap Whether rebalancing is needed
     */
    function checkRebalanceNeeded(address gridAddress) external view returns (
        bool needSwap
    ) {
        IUniGrid grid = IUniGrid(gridAddress);
        return grid.checkRebalanceNeeded();
    }

    /**
     * @notice Check if a grid strategy can be activated
     * @param gridAddress Address of the grid strategy contract
     * @return canActivate Whether the strategy can be activated
     */
    function checkCanActivate(address gridAddress) external view returns (
        bool canActivate
    ) {
        IUniGrid grid = IUniGrid(gridAddress);
        IUniGrid.GridScheme memory gridScheme = grid.gridScheme();
        uint256 currentPrice = grid.getPriceFromOracle();
        if (grid.status() != IUniGrid.GridStrategyStatus.Inactive || currentPrice > gridScheme.upperPrice || currentPrice < gridScheme.lowerPrice) {
            return false;
        }

        uint256 gridPrice = (gridScheme.upperPrice - gridScheme.lowerPrice) / gridScheme.gridCount;
        uint256 emptyGridStartPrice = currentPrice - gridPrice / 2;
        return (emptyGridStartPrice > gridScheme.lowerPrice + gridPrice && emptyGridStartPrice + gridPrice * 2 < gridScheme.upperPrice);
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
        IUniGrid.GridStrategyStatus[] memory statuses
    ) {
        statuses = new IUniGrid.GridStrategyStatus[](gridAddresses.length);
        
        for (uint256 i = 0; i < gridAddresses.length; i++) {
            IUniGrid grid = IUniGrid(gridAddresses[i]);
            statuses[i] = grid.status();
        }
        
        return statuses;
    }
}
