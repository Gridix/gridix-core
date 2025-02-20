// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0 <0.9.0;

import '../base/GridFactoryBase.sol';
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "../grid/UniLimitGrid.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UniLimitFactory
 * @dev Factory contract for creating and managing UniLimit grid strategy contracts
 * Handles the creation and initial setup of limit order grid trading strategies
 */
contract UniLimitFactory is GridFactoryBase {
    using SafeERC20 for IERC20;

    // Uniswap V3 contract addresses
    address constant public uniFactory = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address constant public uniSwapRouter = 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;

    // Event emitted when a new grid strategy is created
    event GridCreated(address indexed gridAddress, address indexed user, address token0, address token1, address uniPool, uint256 timestamp);

    /**
     * @notice Constructor for UniLimitFactory
     * @param _swapFeeRate Fee rate for swaps (in basis points)
     * @param _feeAddr Address to collect fees
     */
    constructor(uint256 _swapFeeRate, address _feeAddr) GridFactoryBase(_swapFeeRate, _feeAddr, msg.sender) {
        allowedToken0Addresses[0x2E983A1Ba5e8b38AAAeC4B440B9dDcFBf72E15d1] = true; // USDC token address
        allowedToken0Addresses[WETH] = true; // WETH token address
    }

    /**
     * @notice Create a new limit order grid strategy
     * @param token0 Address of token0 (must be allowed)
     * @param token1 Address of token1
     * @param poolFee Pool fee tier
     * @param scheme Grid strategy parameters
     * @param token1Amount Initial amount of token1 to deposit
     */
    function creatGrid(address token0, address token1, uint24 poolFee, UniLimitGrid.GridScheme memory scheme, uint256 token1Amount) external {
        require(allowedToken0Addresses[token0], "Token0 not allowed");
        
        // Get Uniswap V3 pool address
        address poolAddr = IUniswapV3Factory(uniFactory).getPool(address(token0), address(token1), poolFee);
        require(poolAddr != address(0), "Pool does not exist");

        // Create new grid strategy contract
        UniLimitGrid grid = new UniLimitGrid(msg.sender, token0, token1, poolFee, poolAddr, uniSwapRouter, scheme);
        gridContractToUser[address(grid)] = msg.sender;

        // Transfer initial tokens to the grid contract
        IERC20(token0).safeTransferFrom(msg.sender, address(grid), scheme.totalInvestment);
        if(token1Amount > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(grid), token1Amount);
        }

        // Activate the grid strategy
        grid.activateGridStrategy(token1Amount);
        
        emit GridCreated(address(grid), msg.sender, token0, token1, poolAddr, block.timestamp);
    }
}
