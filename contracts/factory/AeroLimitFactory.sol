// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0 <0.9.0;
import '../base/GridFactoryBase.sol';
import '../grid/AeroLimitGrid.sol';

/**
 * @dev Interface for Aerodrome pool to get token addresses
 */
interface IPool {
    function tokens() external view returns (address, address);
}

/**
 * @title AeroLimitFactory
 * @dev Factory contract for creating and managing Aerodrome grid strategy contracts
 * Handles the creation and initial setup of limit order grid trading strategies on Aerodrome
 */
contract AeroLimitFactory is GridFactoryBase {
    // Aerodrome router contract address
    IAeroRouter constant public aeroRouter = IAeroRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    // Event emitted when a new grid strategy is created
    event GridCreated(address indexed gridAddress, address indexed user, address token0, address token1, bool stable, address factory);

    /**
     * @notice Constructor for AeroLimitFactory
     * @param _swapFeeRate Fee rate for swaps (in basis points)
     * @param _feeAddr Address to collect fees
     */
    constructor(uint256 _swapFeeRate, address _feeAddr) GridFactoryBase(_swapFeeRate, _feeAddr, msg.sender){
        allowedToken0Addresses[0x2E983A1Ba5e8b38AAAeC4B440B9dDcFBf72E15d1] = true; // USDC token address
        allowedToken0Addresses[WETH] = true; // WETH token address
    }

    /**
     * @notice Check if a token pair is eligible for grid strategy creation
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param _stable Whether the pool is stable or volatile
     * @param _aeroFactory Aerodrome factory address
     * @return Whether the pair is eligible
     */
    function checkEligibility(address token0, address token1, bool _stable, address _aeroFactory) public view returns(bool) {
        if (!allowedToken0Addresses[token0]) return false;
        
        address poolAddr = aeroRouter.poolFor(token0, token1, _stable, _aeroFactory);
        (address tokenR0, address tokenR1) = IPool(poolAddr).tokens();
        
        if(token0 == tokenR0 && token1 == tokenR1 || token0 == tokenR1 && token1 == tokenR0) return true;
        return false;
    }

    /**
     * @notice Create a new limit order grid strategy
     * @param token0 Address of token0 (must be allowed)
     * @param token1 Address of token1
     * @param _stable Whether to use stable or volatile pool
     * @param _aeroFactory Aerodrome factory address
     * @param scheme Grid strategy parameters
     * @param token1Amount Initial amount of token1 to deposit
     */
    function creatGrid(address token0, address token1, bool _stable, address _aeroFactory, AeroLimitGrid.GridScheme memory scheme, uint256 token1Amount) external {
        require(checkEligibility(token0, token1, _stable, _aeroFactory), "Pair not eligible");

        // Create new grid strategy contract
        AeroLimitGrid grid = new AeroLimitGrid(msg.sender, address(aeroRouter), token0, token1, _stable, _aeroFactory, scheme);
        gridContractToUser[address(grid)] = msg.sender;

        // Activate the grid strategy
        grid.activateGridStrategy(token1Amount);
        
        emit GridCreated(address(grid), msg.sender, token0, token1, _stable, _aeroFactory);
    }
}
