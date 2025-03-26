// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0 <0.9.0;

import '../interfaces/IGridFactoryBase.sol';
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Interface for calculating and updating user benefits
 */
interface IBenefitCalculator {
    function refresh(address user, address token, uint256 value) external;
}

/**
 * @title GridFactoryBase
 * @dev Base contract for grid strategy factories
 * Provides common functionality for managing grid trading strategies, fees, and user benefits
 */
abstract contract GridFactoryBase is IGridFactoryBase, Ownable {
    // Swap fee rate in basis points (1 = 0.01%)
    uint256 public swapFeeRate = 10;
    // Address to collect fees
    address public feeAddr;
    // WETH token address
    address public WETH = 0x5FbDB2315678afecb367f032d93F642f64180aa3; //0x4200000000000000000000000000000000000006
    // Benefit calculator contract interface
    IBenefitCalculator public benefitCalculator;
    
    // Mapping of grid contract addresses to their owners
    mapping(address => address) public gridContractToUser;
    // Mapping of token addresses to their execution fees
    mapping(address => uint256) public executionFee;
    // Mapping of allowed token0 addresses
    mapping(address => bool) public allowedToken0Addresses;

    // Events
    event AddressStatusUpdated(address indexed addr, bool status);
    event FeeAddrUpdated(address oldAddr, address newAddr);
    event SwapFeeRateUpdated(uint256 oldFeeRate, uint256 newFeeRate);
    event BenefitCalculatorUpdated(address oldAddr, address newAddr);
    event ExecutionFeeUpdated(address indexed token, uint256 oldFee, uint256 newFee);

    /**
     * @notice Constructor for GridFactoryBase
     * @param _swapFeeRate Initial fee rate for swaps (in basis points)
     * @param _feeAddr Initial address to collect fees
     * @param _user Initial owner of the contract
     */
    constructor(uint256 _swapFeeRate, address _feeAddr, address _user) Ownable(_user) {
        swapFeeRate = _swapFeeRate;
        feeAddr = _feeAddr;
    }

    /**
     * @notice Update token0 allowance status
     * @param token0 Token address to update
     * @param status Whether the token is allowed as token0
     * @dev Only callable by owner
     */
    function setAddressStatus(address token0, bool status) external onlyOwner {
        require(token0 != address(0), "Invalid address");
        allowedToken0Addresses[token0] = status;
        emit AddressStatusUpdated(token0, status);
    }

    /**
     * @notice Notify benefit calculator of value updates
     * @param value New total value for user's position
     * @dev Called by grid contracts when value changes
     */
    function notifyUpdated(address token, uint256 value) external {
        if(address(benefitCalculator) != address(0) && gridContractToUser[msg.sender]!= address(0)) {
            try benefitCalculator.refresh(gridContractToUser[msg.sender], token, value){}
             catch {}
        }
    }

    /**
     * @notice Update the swap fee rate
     * @param _swapFeeRate New fee rate (max 0.1%)
     * @dev Only callable by owner
     */
    function setSwapFeeRate(uint256 _swapFeeRate) public onlyOwner {
        require(_swapFeeRate <= 10); //.1%
        emit SwapFeeRateUpdated(swapFeeRate, _swapFeeRate);
        swapFeeRate = _swapFeeRate;
    }

    /**
     * @notice Update the fee collection address
     * @param _addr New address to collect fees
     * @dev Only callable by owner
     */
    function setFeeAddr(address _addr) public onlyOwner {
        require(_addr != address(0));
        emit FeeAddrUpdated(feeAddr, _addr);
        feeAddr = _addr;
    }

    /**
     * @notice Set the benefit calculator contract
     * @param _addr Address of the new benefit calculator
     * @dev Only callable by owner
     */
    function setBenefitCalculator(address _addr) public onlyOwner {
        emit BenefitCalculatorUpdated(address(benefitCalculator), _addr);
        benefitCalculator = IBenefitCalculator(_addr);
    }

    /**
     * @notice Set execution fee for a token
     * @param token Token address
     * @param fee New execution fee amount
     * @dev Only callable by owner
     * @dev For WETH, max fee is 0.0005 ETH
     * @dev For other tokens, max fee is 1 token unit
     */
    function setPoolExecutionFee(address token, uint256 fee) external onlyOwner {
        if(token == WETH) {
            require(fee <= 5e14);
        } else {
            require(fee <= 10 ** ERC20(token).decimals());
        }
        emit ExecutionFeeUpdated(token, executionFee[token], fee);
        executionFee[token] = fee;
    }

    /**
     * @notice Get execution fee for a token
     * @param token Token address
     * @return Execution fee amount
     */
    function getExecutionFee(address token) external view returns(uint256) {
        return executionFee[token];
    }
}
