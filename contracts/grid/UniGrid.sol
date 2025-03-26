// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

pragma abicoder v2;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import '../interfaces/INonfungiblePositionManager.sol';
import "../interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import '../interfaces/IUniGridFactory.sol';
import '../interfaces/TickMath.sol';

/**
 * @title UniGrid Contract
 * @dev Implementation of a grid trading strategy using Uniswap V3
 * This contract enables users to create automated grid trading strategies
 * by deploying liquidity across different price ranges
 */
contract UniGrid is IERC721Receiver, Ownable {
    using SafeERC20 for IERC20;
    
    // Uniswap V3 related contract interfaces
    ISwapRouter public uniSwapRouter;
    uint24 public poolFee;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IUniswapV3Factory public uniswapV3Factory;
    IUniGridFactory public gridFactory;

    // Slippage protection parameter, default 10%
    uint256 public slippage = 100_000;

    // NFT token IDs for tracking upper and lower bound liquidity positions
    uint256 public lowerTokenId;
    uint256 public upperTokenId;
    
    // Grid strategy parameters
    GridScheme public gridScheme;
    IERC20 public token0;
    IERC20 public token1;
    uint256 public emptyGridStartPrice;
    
    // Strategy status
    GridStrategyStatus public status = GridStrategyStatus.Inactive;
    
    /**
     * @dev Enum representing the grid strategy status
     * Inactive: Not activated
     * Active: Running
     * Closed: Terminated
     */
    enum GridStrategyStatus {
        Inactive, 
        Active,
        Closed
    }

    /**
     * @dev Struct containing grid strategy parameters
     * @param lowerPrice Lower price boundary of the grid
     * @param upperPrice Upper price boundary of the grid
     * @param gridCount Number of grid lines
     * @param totalInvestment Total investment amount
     * @param extraToken1Amount Additional token1 amount
     */
    struct GridScheme{
        uint256 lowerPrice;
        uint256 upperPrice;
        uint256 gridCount;
        uint256 totalInvestment;
        uint256 extraToken1Amount;
    }

    // Events
    event GridStrategyActivated(uint256 currentPrice, uint256 token0Amount, uint256 token1Amount, uint256 time);
    event SlippageUpdated(uint256 slippage);
    event RebalanceExecuted(uint256 newGrid, uint256 currentPrice, uint256 token0Amount, uint256 token1Amount, uint256 time);
    event StrategyTerminated(uint256 remainingToken0, uint256 remainingToken1, uint256 price, uint256 time);
    event NewPositionMinted(uint256 tokenId, uint256 amount0, uint256 amount1, uint256 lowerPrice, uint256 upperPrice, uint256 time);
    event LiquidityRemovedAndFeesCollected(uint256 tokenId, uint256 amount0, uint256 amount1, uint256 time);

    /**
     * @dev Constructor
     * @param _user Strategy owner address
     * @param _token0 Token0 address
     * @param _token1 Token1 address
     * @param _poolFee Pool fee rate
     * @param scheme Grid strategy parameters
     */
    constructor(
        address _user,
        address _token0,
        address _token1,
        uint24 _poolFee,
        GridScheme memory scheme
    ) Ownable(_user) {
        gridFactory = IUniGridFactory(msg.sender);
        uniswapV3Factory = IUniswapV3Factory(gridFactory.uniFactory());
        uniSwapRouter = ISwapRouter(gridFactory.uniSwapRouter());
        nonfungiblePositionManager = INonfungiblePositionManager(gridFactory.nonfungiblePositionManager());
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        poolFee = _poolFee;
        gridScheme = scheme;
    }

    /**
     * @dev Implements ERC721 receiver interface to allow contract to receive NFTs
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev Execute grid rebalancing
     * When price moves beyond a certain range, adjust liquidity positions
     */
    function rebalance() external {
        require(status == GridStrategyStatus.Active, "GNA");
        uint256 currentPrice = getPriceFromOracle();
        
        // If price is outside grid range, terminate strategy
        if(currentPrice > gridScheme.upperPrice || currentPrice < gridScheme.lowerPrice) {
            _terminateStrategy();
            return;
        }
        
        uint256 gridPrice = _getGridPrice();
        require(currentPrice >= emptyGridStartPrice + gridPrice * 2 || currentPrice <= emptyGridStartPrice - gridPrice, "NM");
        
        // Remove existing liquidity and collect fees
        _removeLiquidityAndCollectFees(upperTokenId);
        uint256 token0InUpper = token0.balanceOf(address(this));
        uint256 token1InUpper = token1.balanceOf(address(this));
        _removeLiquidityAndCollectFees(lowerTokenId);
        uint256 token0Balance = token0.balanceOf(address(this));
        uint256 token1Balance = token1.balanceOf(address(this));

        // Calculate and pay execution fee and swap fee
        uint256 fee = gridFactory.getExecutionFee(address(token0));
        uint256 swapFee;
        if(currentPrice >= emptyGridStartPrice + gridPrice * 2) {
            swapFee = token0InUpper * gridFactory.swapFeeRate() / 10_000;
            emptyGridStartPrice = currentPrice - gridPrice;
        } else {
            swapFee = (token1Balance - token1InUpper) * currentPrice / 1e18 * gridFactory.swapFeeRate() / 10_000;
            emptyGridStartPrice = currentPrice;
        }
        
        if(token0Balance >= fee + swapFee) {
            token0.safeTransfer(msg.sender, fee);
            token0.safeTransfer(gridFactory.feeAddr(), swapFee);
            token0Balance -= swapFee + fee;
            gridFactory.notifyUpdated(address(token0), fee + swapFee);
        }
        
        // Create new liquidity positions at new price ranges
        lowerTokenId = _mintNewPosition(token0Balance, 0, gridScheme.lowerPrice, emptyGridStartPrice, false);
        upperTokenId = _mintNewPosition(0, token1Balance, emptyGridStartPrice + gridPrice, gridScheme.upperPrice, true);
        
        emit RebalanceExecuted(emptyGridStartPrice, currentPrice, token0Balance, token1Balance, block.timestamp);
    }

    /**
     * @dev Terminate strategy by owner
     * Can only be called by strategy owner
     */
    function terminateStrategyByOwner() external onlyOwner {
        if(status == GridStrategyStatus.Inactive) {
            token0.safeTransfer(owner(), token0.balanceOf(address(this)));
            token1.safeTransfer(owner(), token1.balanceOf(address(this)));
            status = GridStrategyStatus.Closed;
            return;
        }
        require(status == GridStrategyStatus.Active, "GNA");
        _terminateStrategy();
    }

    /**
     * @dev Set slippage protection parameter
     * @param _slippage New slippage value (in basis points, 1% = 10000)
     */
    function setSlippage(uint256 _slippage) external onlyOwner {
        require(_slippage <= 20_000, "EML");
        slippage = _slippage;
        emit SlippageUpdated(slippage);
    }

    /**
     * @dev Activate grid strategy
     */
    function activateGridStrategy() external {
        uint256 currentPrice = getPriceFromOracle();
        if (status != GridStrategyStatus.Inactive || gridScheme.lowerPrice > currentPrice || gridScheme.upperPrice < currentPrice) {
            return;
        }
        _initial(currentPrice);
    }

    /**
     * @dev Execute exact input single swap
     * @param scheme Grid strategy parameters
     * @param currentPrice Current market price
     * @param extraToken1Amount Additional token1 amount
     */
    function _exactInputSingle(GridScheme memory scheme, uint256 currentPrice, uint256 extraToken1Amount) internal {
        uint256 amountIn;
        address tokenIn;
        address tokenOut;
        uint256 amountOutMinimum;

        uint256 needToken0 = (scheme.totalInvestment + (extraToken1Amount * currentPrice / 1e18)) * (currentPrice - scheme.lowerPrice) / (scheme.upperPrice - scheme.lowerPrice);

        if (extraToken1Amount == 0 || scheme.totalInvestment > needToken0) {
            amountIn = scheme.totalInvestment - needToken0;
            tokenIn = address(token0);
            tokenOut = address(token1);
            amountOutMinimum = (amountIn * 1e18 / currentPrice) * (1000_000 - slippage) / 1000_000;
        } else {
            amountIn = (needToken0 - scheme.totalInvestment) * 1e18 / currentPrice;
            tokenIn = address(token1);
            tokenOut = address(token0);
            amountOutMinimum = (needToken0 - scheme.totalInvestment) * (1000_000 - slippage) / 1000_000;
        }

        IERC20(tokenIn).approve(address(uniSwapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        uniSwapRouter.exactInputSingle(params);
    }

    /**
     * @dev Initialize grid strategy
     * @param currentPrice Current market price
     */
    function _initial(uint256 currentPrice) internal {
        require(gridScheme.lowerPrice < currentPrice && gridScheme.upperPrice > currentPrice, "NM");
        uint256 gridPrice = _getGridPrice();
        emptyGridStartPrice = currentPrice - gridPrice / 2;
        require(emptyGridStartPrice > gridScheme.lowerPrice + gridPrice && emptyGridStartPrice + gridPrice * 2 < gridScheme.upperPrice, "ENM");

        _exactInputSingle(gridScheme, currentPrice, gridScheme.extraToken1Amount);
        uint256 token0Amount = token0.balanceOf(address(this));
        uint256 token1Amount = token1.balanceOf(address(this));

        uint256 realPrice = getPriceFromOracle();

        lowerTokenId = _mintNewPosition(token0Amount, 0, gridScheme.lowerPrice, realPrice, false);
        upperTokenId = _mintNewPosition(0, token1Amount, realPrice, gridScheme.upperPrice, true);

        status = GridStrategyStatus.Active;

        gridScheme.totalInvestment += gridScheme.extraToken1Amount * realPrice / 1e18;
        emit GridStrategyActivated(realPrice, token0Amount, token1Amount, block.timestamp);
    }

    /**
     * @dev Create new liquidity position
     * @param amount0ToMint Amount of token0 to mint
     * @param amount1ToMint Amount of token1 to mint
     * @param lowerPrice Lower price boundary
     * @param upperPrice Upper price boundary
     * @param direction Price direction
     * @return tokenId ID of newly created position
     */
    function _mintNewPosition(
        uint256 amount0ToMint,
        uint256 amount1ToMint,
        uint256 lowerPrice,
        uint256 upperPrice,
        bool direction
    ) internal returns (uint256) {
        // Approve position manager to use tokens
        token0.safeIncreaseAllowance(address(nonfungiblePositionManager), amount0ToMint);
        token1.safeIncreaseAllowance(address(nonfungiblePositionManager), amount1ToMint);
        bool zeroToOne = getZeroToOne();
        if(zeroToOne) {
            (lowerPrice, upperPrice) = _swapValues(lowerPrice, upperPrice);
        } else {
            (amount0ToMint, amount1ToMint) = _swapValues(amount0ToMint, amount1ToMint);
        }

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: address(token0) < address(token1) ? address(token0) : address(token1),
                token1: address(token0) < address(token1) ? address(token1) : address(token0),
                fee: poolFee,
                tickLower: TickMath.getTickFromPrice(lowerPrice, zeroToOne, poolFee, direction),
                tickUpper: TickMath.getTickFromPrice(upperPrice, zeroToOne, poolFee, direction),
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: amount0ToMint * (1000_000 - slippage) / 1000_000,
                amount1Min: amount1ToMint * (1000_000 - slippage) / 1000_000,
                recipient: address(this),
                deadline: block.timestamp + 15
            });

        (uint256 tokenId, , uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(params);
        emit NewPositionMinted(tokenId, amount0, amount1, lowerPrice, upperPrice, block.timestamp);
        return tokenId;
    }

    /**
     * @dev Remove liquidity and collect fees
     * @param tokenId Liquidity position ID
     */
    function _removeLiquidityAndCollectFees(uint256 tokenId) internal {
        uint128 liquidity = _getLiquidity(tokenId);
        require(liquidity > 0, "NL");

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 15
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.decreaseLiquidity(decreaseParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 amount01, uint256 amount11) = nonfungiblePositionManager.collect(collectParams);
        emit LiquidityRemovedAndFeesCollected(tokenId, amount0 + amount01, amount1 + amount11, block.timestamp);
    }

    /**
     * @dev Terminate strategy
     * Remove all liquidity and return tokens to owner
     */
    function _terminateStrategy() internal {
        _removeLiquidityAndCollectFees(lowerTokenId);
        _removeLiquidityAndCollectFees(upperTokenId);

        uint256 token0Amount = token0.balanceOf(address(this));
        uint256 token1Amount = token1.balanceOf(address(this));
        uint256 currentPrice = getPriceFromOracle();
        uint256 fee = gridFactory.getExecutionFee(address(token0));

        if(msg.sender != owner()) {
            if(token0Amount >= fee) {
                token0.safeTransfer(msg.sender, fee);
                token0Amount -= fee;
            } else {
                uint256 feeBytoken1 = fee * 1e18 / currentPrice;
                token1.safeTransfer(msg.sender, feeBytoken1);
                token1Amount -= feeBytoken1;
            }
        }

        token0.safeTransfer(owner(), token0Amount);
        token1.safeTransfer(owner(), token1Amount);

        status = GridStrategyStatus.Closed;
        emit StrategyTerminated(token0Amount, token1Amount, currentPrice, block.timestamp);
    }

    /**
     * @dev Get liquidity amount of a position
     * @param tokenId Position ID
     * @return liquidity Amount of liquidity
     */
    function _getLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (, , , , , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
    }

    /**
     * @dev Calculate grid price spacing
     * @return Grid price interval
     */
    function _getGridPrice() internal view returns(uint256) {
        return (gridScheme.upperPrice - gridScheme.lowerPrice) / gridScheme.gridCount;
    }

    /**
     * @dev Swap two values
     * @param a First value
     * @param b Second value
     * @return Swapped values
     */
    function _swapValues(uint256 a, uint256 b) public pure returns (uint256, uint256) {
        uint256 temp = a; 
        a = b; 
        b = temp;
        return (a, b);
    }

    /**
     * @dev Check if token0 to token1 direction
     * @return True if token0 address is less than token1 address
     */
    function getZeroToOne() internal view returns(bool) {
        return address(token0) < address(token1);
    }

    /**
     * @dev Check if rebalancing is needed
     * @return True if rebalancing is needed
     */
    function checkRebalanceNeeded() external view returns(bool) {
        if(status != GridStrategyStatus.Active) {
            return false;
        }
        uint256 currentPrice = getPriceFromOracle();
        if(currentPrice > gridScheme.upperPrice || currentPrice < gridScheme.lowerPrice) {
            return true;
        }
        uint256 gridPrice = _getGridPrice();
        if(currentPrice >= emptyGridStartPrice + gridPrice * 2 || currentPrice <= emptyGridStartPrice - gridPrice) return true;
        return false;
    }

    /**
     * @dev Get current price from oracle
     * @return uniPrice Current market price
     */
    function getPriceFromOracle() public view returns (uint256 uniPrice) {
        address poolAddr = uniswapV3Factory.getPool(address(token0), address(token1), poolFee);
        require(poolAddr != address(0), "PNE");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        if(!getZeroToOne()) {
            uniPrice = uint256(sqrtPriceX96) ** 2 / (1 << 60) * 1e18 / (1 << 132);
        } else {
            uniPrice = 1e18 * (1 << 192) / (uint256(sqrtPriceX96) ** 2);
        }
    }
}