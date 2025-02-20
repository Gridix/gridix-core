// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

pragma abicoder v2;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import '../interfaces/IGridFactoryBase.sol';

/**
 * @title LimitGridBase
 * @dev Base contract for limit order grid trading strategies
 * Implements core functionality for managing grid positions and executing trades
 * Handles strategy activation, rebalancing, and termination
 */
abstract contract LimitGridBase is Ownable {
    using SafeERC20 for IERC20;

    // Token pair for the grid strategy
    IERC20 public token0;
    IERC20 public token1;

    // Maximum allowed slippage in basis points (default: 10%)
    uint256 public slippage = 100_000;
    // Reference to the factory contract
    IGridFactoryBase public gridFactory;

    // Last recorded price for the token pair
    uint256 public lastPrice;
    // Grid strategy parameters
    GridScheme public gridScheme;
    // Current status of the grid strategy
    GridStrategyStatus public status = GridStrategyStatus.Inactive;

    /**
     * @dev Enum representing the possible states of the grid strategy
     * Inactive: Strategy not yet started
     * Active: Strategy is running
     * Closed: Strategy has been terminated
     */
    enum GridStrategyStatus {
        Inactive, 
        Active,
        Closed
    }

    /**
     * @dev Struct containing grid strategy parameters
     * @param lowerPrice Minimum price for the grid range
     * @param upperPrice Maximum price for the grid range
     * @param gridCount Number of grid lines
     * @param totalInvestment Total investment amount in token0
     * @param triggerPrice Price at which the strategy should be activated
     */
    struct GridScheme {
        uint256 lowerPrice;
        uint256 upperPrice;
        uint256 gridCount;
        uint256 totalInvestment;
        uint256 triggerPrice;
    }

    // Events
    event GridStrategyActivated(uint256 currentPrice, uint256 token0Amount, uint256 token1Amount, uint256 time);
    event SlippageUpdated(uint256 slippage);
    event RebalanceExecuted(uint256 currentPrice, uint256 token0Amount, uint256 token1Amount, uint256 time);
    event StrategyTerminated(uint256 remainingToken0, uint256 remainingToken1, uint256 price, uint256 time);

    /**
     * @notice Constructor
     * @param _user Address of the strategy owner
     */
    constructor(address _user) Ownable(_user) {}

    /**
     * @notice Execute rebalancing of the grid positions
     * @dev Can only be called when strategy is active
     * Handles position adjustments based on price movements
     */
    function rebalance() external {
        require(status == GridStrategyStatus.Active, "GNA");
        uint256 currentPrice = getPriceFromOracle();
        uint256 fee = gridFactory.getExecutionFee(address(token0));
        if(token0.balanceOf(address(this)) > fee) {
            token0.safeTransfer(msg.sender, fee);
        }
        if(currentPrice > gridScheme.upperPrice || currentPrice < gridScheme.lowerPrice) {
            _terminateStrategy();
            return;
        }
        uint256 gridPrice = (gridScheme.upperPrice - gridScheme.lowerPrice) / gridScheme.gridCount;
        require(currentPrice > lastPrice + gridPrice || currentPrice < lastPrice - gridPrice, "NM");

        uint256 swapAmount;
        if(currentPrice > lastPrice + gridPrice) {
            swapAmount = token1.balanceOf(address(this)) * (currentPrice - lastPrice) / (gridScheme.upperPrice - lastPrice);
            swapByRouter(false, swapAmount, currentPrice);
        } else {
            swapAmount = token0.balanceOf(address(this)) * (lastPrice - currentPrice) / (lastPrice - gridScheme.lowerPrice);
            swapByRouter(true, swapAmount, currentPrice);
        }
        uint256 token0Balance = token0.balanceOf(address(this));
        uint256 token1Balance = token1.balanceOf(address(this));
        lastPrice = currentPrice;
        gridFactory.notifyUpdated(token0Balance + token1Balance * currentPrice / 1e18);
        emit RebalanceExecuted(currentPrice, token0Balance, token1Balance, block.timestamp);
    }

    /**
     * @notice Terminate the grid strategy
     * @dev Only callable by owner when strategy is active
     */
    function terminateStrategyByOwner() external onlyOwner {
        require(status == GridStrategyStatus.Active, "GNA");
        _terminateStrategy();
    }

    /**
     * @notice Update maximum allowed slippage
     * @param _slippage New slippage value in basis points (max 2%)
     * @dev Only callable by owner
     */
    function setSlippage(uint256 _slippage) external onlyOwner {
        require(_slippage <= 20_000, "Slippage cannot exceed 2%");
        slippage = _slippage;
        emit SlippageUpdated(slippage);
    }

    /**
     * @notice Activate the grid strategy
     * @param amount Initial token1 amount (if called by factory)
     * @dev Strategy can only be activated when price is below trigger price
     */
    function activateGridStrategy(uint256 amount) external {
        uint256 currentPrice = getPriceFromOracle();
        if (status != GridStrategyStatus.Inactive || currentPrice > gridScheme.triggerPrice) {
            return;
        }
        uint256 token1Amount = (msg.sender == address(gridFactory)) ? amount : 0;
        _initial(gridScheme, currentPrice, token1Amount);
    }

    /**
     * @notice Execute swap through router
     * @param zeroForOne Direction of swap (true for token0 to token1)
     * @param amountIn Amount of input token
     * @param price Current price
     * @dev Must be implemented by derived contracts
     */
    function swapByRouter(bool zeroForOne, uint256 amountIn, uint256 price) internal virtual {}

    /**
     * @notice Initialize the grid strategy
     * @param scheme Grid parameters
     * @param currentPrice Current market price
     * @param extraToken1Amount Additional token1 amount
     * @dev Sets up initial positions and activates the strategy
     */
    function _initial(GridScheme memory scheme, uint256 currentPrice, uint256 extraToken1Amount) internal {
        require(scheme.lowerPrice < currentPrice && scheme.upperPrice > currentPrice, "NM");

        uint256 amountIn;
        uint256 needToken0 = (scheme.totalInvestment + (extraToken1Amount * currentPrice / 1e18)) * (currentPrice - scheme.lowerPrice) / (scheme.upperPrice - scheme.lowerPrice);
        if (extraToken1Amount == 0 || scheme.totalInvestment > needToken0) {
            amountIn = scheme.totalInvestment - needToken0;
            swapByRouter(true, amountIn, currentPrice);
        } else {
            amountIn = (needToken0 - scheme.totalInvestment) * 1e18 / currentPrice;
            swapByRouter(false, amountIn, currentPrice);
        }

        uint256 token0Amount = token0.balanceOf(address(this));
        uint256 token1Amount = token1.balanceOf(address(this));

        status = GridStrategyStatus.Active;
        lastPrice = currentPrice;
        gridScheme.totalInvestment = token0Amount + token1Amount * currentPrice / 1e18;
        gridFactory.notifyUpdated(gridScheme.totalInvestment);
        emit GridStrategyActivated(currentPrice, token0Amount, token1Amount, block.timestamp);
    }

    /**
     * @notice Internal function to terminate the strategy
     * @dev Handles final position adjustments and token transfers
     */
    function _terminateStrategy() internal {
        uint256 currentPrice = getPriceFromOracle();

        uint256 token0Amount = token0.balanceOf(address(this));
        uint256 token1Amount = token1.balanceOf(address(this));

        if(currentPrice > gridScheme.upperPrice){
            swapByRouter(false, token1Amount, currentPrice);
        }

        if(currentPrice < gridScheme.lowerPrice){
            swapByRouter(true, token0Amount, currentPrice);
        }
        _closeStrategy(currentPrice);
    }

    /**
     * @notice Close the strategy and transfer remaining tokens
     * @param currentPrice Current market price
     * @dev Transfers all tokens to owner and updates status
     */
    function _closeStrategy(uint256 currentPrice) internal {
        uint256 token0Amount = token0.balanceOf(address(this));
        uint256 token1Amount = token1.balanceOf(address(this));

        token0.safeTransfer(owner(), token0Amount);
        token1.safeTransfer(owner(), token1Amount);
        gridFactory.notifyUpdated(token0Amount + token1Amount * currentPrice / 1e18);
        
        status = GridStrategyStatus.Closed;
        emit StrategyTerminated(token0Amount, token1Amount, currentPrice, block.timestamp);
    }

    /**
     * @notice Get current price from oracle
     * @return price Current market price
     * @dev Must be implemented by derived contracts
     */
    function getPriceFromOracle() public view virtual returns (uint256 price) {}

    /**
     * @notice Check if rebalancing is needed
     * @return Whether the strategy needs rebalancing
     * @dev Returns true if price has moved beyond grid boundaries
     */
    function checkRebalanceNeeded() external view returns(bool) {
        if(status != GridStrategyStatus.Active) {
            return false;
        }
        uint256 currentPrice = getPriceFromOracle();
        uint256 gridPrice = (gridScheme.upperPrice - gridScheme.lowerPrice) / gridScheme.gridCount;

        if(currentPrice > lastPrice + gridPrice || currentPrice < lastPrice - gridPrice) {
            return true;
        }
        return false;
    }
}