// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV4Oracle} from "./interfaces/IUniswapV4Oracle.sol";

interface IChainlinkAdaptor {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract UniswapV4Oracle is IUniswapV4Oracle, Ownable {
    using Math for uint256;
    using SafeCast for uint256;

    struct ChainlinkInfo {
        address tokenAdaptor;
        uint96 maxDelay;
    }

    mapping(address => ChainlinkInfo) public chainlinkInfos;

    constructor() Ownable(msg.sender) {}

    function setChainlinkInfo(address token, ChainlinkInfo memory info) public onlyOwner {
        chainlinkInfos[token] = info;
    }

    function getPrice(address token) public view returns (uint256) {
        return _getPrice(Currency.wrap(token));
    }

    function getUniswapV4Price(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        view
        returns (uint256)
    {
        // get token0 price
        uint256 token0Price = _getPrice(key.currency0);
        // get token1 price
        uint256 token1Price = _getPrice(key.currency1);
        // calculate current price in sqrtPriceX96
        // note: this is something like paraspace does in their oracle
        uint256 currentSqrtPriceX96 = (token0Price.mulDiv(1e36, token1Price).sqrt() << 96) / 1e18;
        // get amount0 and amount1 from liquidity using currentSqrtPriceX96
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96.toUint160(),
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        // calculate price from amount0 and amount1
        return amount0 * token0Price + amount1 * token1Price;
    }

    function _getPrice(Currency currency) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        ChainlinkInfo memory info = chainlinkInfos[token];
        require(info.tokenAdaptor != address(0), "chainlink info not found");
        (, int256 answer,, uint256 updatedAt,) = IChainlinkAdaptor(info.tokenAdaptor).latestRoundData();
        require(block.timestamp - updatedAt <= info.maxDelay, "price is outdated");
        return uint256(answer) * 1e36
            / (10 ** (IChainlinkAdaptor(info.tokenAdaptor).decimals() + IERC20Metadata(token).decimals()));
    }

    function getSqrtPriceX96(Currency currency0, Currency currency1) public view returns (uint160) {
        uint256 token0Price = _getPrice(currency0);
        uint256 token1Price = _getPrice(currency1);
        return ((token0Price.mulDiv(1e36, token1Price).sqrt() << 96) / 1e18).toUint160();
    }
}
