// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0 <0.9.0;

import '../base/GridFactoryBase.sol';
import '../grid/UniGrid.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UniGridFactory
 * @dev Factory contract for creating and managing UniGrid strategy contracts
 * Handles the creation and initial setup of grid trading strategies
 */
contract UniGridFactory is GridFactoryBase {
    using SafeERC20 for IERC20;

    // Uniswap V3 contract addresses
    address constant public nonfungiblePositionManager = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address constant public uniFactory = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address constant public uniSwapRouter = 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;

    // Event emitted when a new grid strategy is created
    event GridCreated(address indexed gridAddress, address indexed user, address token0, address token1, uint256 token0Amount, uint256 token1Amount, uint24 poolFee, uint256 timestamp);

    /**
     * @notice Constructor for UniGridFactory
     * @param _swapFeeRate Fee rate for swaps (in basis points)
     * @param _feeAddr Address to collect fees
     */
    constructor(uint256 _swapFeeRate, address _feeAddr) GridFactoryBase(_swapFeeRate, _feeAddr, msg.sender) {
        allowedToken0Addresses[0x663F3ad617193148711d28f5334eE4Ed07016602] = true; // USDC token address
        allowedToken0Addresses[0x2E983A1Ba5e8b38AAAeC4B440B9dDcFBf72E15d1] = true; // USDT token address
        allowedToken0Addresses[WETH] = true; // WETH token address
    }

    /**
     * @notice Check if a token pair is eligible for grid strategy creation
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param poolFee Pool fee tier
     * @return Whether the pair is eligible
     */
    function checkEligibility(address token0, address token1, uint24 poolFee) public view returns(bool) {
        address poolAddr = IUniswapV3Factory(uniFactory).getPool(address(token0), address(token1), poolFee);
        return (allowedToken0Addresses[token0] && token0 != token1 && poolAddr != address(0));
    }

    /**
     * @notice Create a new grid strategy
     * @param token0 Address of token0 (must be allowed)
     * @param token1 Address of token1
     * @param poolFee Pool fee tier
     * @param scheme Grid strategy parameters
     */
    function creatGrid(address token0, address token1, uint24 poolFee, UniGrid.GridScheme memory scheme) external {
        require(checkEligibility(token0, token1, poolFee));
        
        // Create new grid strategy contract
        UniGrid grid = new UniGrid(msg.sender, token0, token1, poolFee, scheme);
        gridContractToUser[address(grid)] = msg.sender;

        // Transfer initial tokens to the grid contract
        if(scheme.totalInvestment > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(grid), scheme.totalInvestment);
        }
        if(scheme.extraToken1Amount > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(grid), scheme.extraToken1Amount);
        }

        // Activate the grid strategy
        grid.activateGridStrategy();
        
        emit GridCreated(address(grid), msg.sender, token0, token1, scheme.totalInvestment, scheme.extraToken1Amount, poolFee, block.timestamp);
    }
}
