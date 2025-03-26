// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

pragma abicoder v2;
import '../base/LimitGridBase.sol';

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface IAeroRouter {
    function poolFor(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory
    ) external view returns (address pool);
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract AeroLimitGrid is LimitGridBase {
    using SafeERC20 for IERC20;
    IAeroRouter public aeroRouter;
    address public aeroFactory;
    bool public stable;

    constructor(
        address _user,
        address _aeroRouter,
        address _token0,
        address _token1,
        bool _stable,
        address _aeroFactory,
        GridScheme memory scheme
    ) LimitGridBase(_user) {
        gridFactory = IGridFactoryBase(msg.sender);
        aeroRouter = IAeroRouter(_aeroRouter);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        stable = _stable;
        aeroFactory = _aeroFactory;
        gridScheme = scheme;
    }

    function swapByRouter(bool zeroForOne, uint256 amountIn, uint256 price) internal override {
        address tokenIn;
        address tokenOut;
        uint256 amountOutMinimum;

        if(zeroForOne) {
            tokenIn = address(token0);
            tokenOut = address(token1);
            amountOutMinimum = amountIn * 1e18 / price * (1000_000 - slippage) / 1000_000;
        } else {
            tokenIn = address(token1);
            tokenOut = address(token0);
            amountOutMinimum = amountIn * price / 1e18 * (1000_000 - slippage) / 1000_000;
        }
        IERC20(tokenIn).approve(address(aeroRouter), amountIn);
        IAeroRouter.Route memory route = IAeroRouter.Route({
            from: tokenIn,
            to: tokenOut,
            stable: stable,
            factory: aeroFactory
        });

        IAeroRouter.Route[] memory routes;
        routes[0] = route;
        aeroRouter.swapExactTokensForTokens(amountIn, amountOutMinimum, routes, address(this), block.timestamp + 15);
    }

    function getPriceFromOracle() public view override returns (uint256 price) {
        IAeroRouter.Route memory route = IAeroRouter.Route({
            from: address(token1),
            to: address(token0),
            stable: stable,
            factory: aeroFactory
        });
        IAeroRouter.Route[] memory routes;
        routes[0] = route;
        uint256[] memory amounts = aeroRouter.getAmountsOut(1e18, routes);
        return amounts[amounts.length - 1];
    }
}