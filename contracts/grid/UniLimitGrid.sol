// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

pragma abicoder v2;
import '../base/LimitGridBase.sol';
import "../interfaces/ISwapRouter.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";


contract UniLimitGrid is IERC721Receiver, LimitGridBase {
    using SafeERC20 for IERC20;
    ISwapRouter public uniSwapRouter;
    uint24 public poolFee;
    IUniswapV3Pool public uniswapV3Pool;

    constructor(
        address _user,
        address _token0,
        address _token1,
        uint24 _poolFee,
        address _poolAddr,
        address _uniSwapRouter,
        GridScheme memory scheme
    ) LimitGridBase(_user) {
        gridFactory = IGridFactoryBase(msg.sender);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        poolFee = _poolFee;
        uniswapV3Pool = IUniswapV3Pool(_poolAddr);
        uniSwapRouter = ISwapRouter(_uniSwapRouter);
        gridScheme = scheme;
    }

    // Implementing `onERC721Received` so this contract can receive custody of erc721 tokens
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external override pure returns (bytes4) {
        // get position information
        return this.onERC721Received.selector;
    }

    function swapByRouter(bool zeroForOne, uint256 amountIn, uint256 price) internal override {
        address tokenIn;
        address tokenOut;
        uint256 amountOutMinimum;

        if(zeroForOne) {
            tokenIn = address(token0);
            tokenOut = address(token1);
            amountOutMinimum = amountIn * 1e18 /price * (1000_000 - slippage) / 1000_000;
        } else {
            tokenIn = address(token1);
            tokenOut = address(token0);
            amountOutMinimum = amountIn * price / 1e18 * (1000_000 - slippage) / 1000_000;
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

    function getPriceFromOracle() public override view returns (uint256 uniPrice) {
        (uint160 sqrtPriceX96, , , , , , ) = uniswapV3Pool.slot0();
        if(uniswapV3Pool.token0() == address(token1)) {
            uniPrice = uint256(sqrtPriceX96) ** 2 / (1 << 60) * 1e18 / (1 << 132);
        } else {
            uniPrice = 1e18 * (1 << 192) / (uint256(sqrtPriceX96) ** 2);
        }
    }
}