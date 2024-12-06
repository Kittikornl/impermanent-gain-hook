// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GainswapHook.base.t.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract GainswapBaseShorterTest is GainswapBaseTest {
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    uint256 aliceUniswapV4PositionId;
    uint256 bobShortPositionId;
    uint256 carolShortPositionId;
    uint128 shortLiquidity = 0.5e12;
    uint256 token0FromShortLp; // holding token0 after short lp
    uint256 token1FromShortLp; // holding token1 after short lp

    function setUp() public override {
        super.setUp();
        // alice provides liquidity
        aliceUniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e12,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            500, // 5%
            ZERO_BYTES
        );
        uint256 token0BalanceBf = currency0.balanceOf(BOB);
        uint256 token1BalanceBf = currency1.balanceOf(BOB);
        bobShortPositionId = _shortLp(BOB, aliceUniswapV4PositionId, shortLiquidity, 1e30, ZERO_BYTES);
        token0FromShortLp = currency0.balanceOf(BOB) - token0BalanceBf;
        token1FromShortLp = currency1.balanceOf(BOB) + 1e30 - token1BalanceBf;
    }

    function testSettleInProfit() public {
        (uint160 sqrtPriceX96Bf,,,) = manager.getSlot0(poolKey.toId());
        (,,, uint128 owedLiquidity,) = hook.shortPositions(bobShortPositionId);
        // simulate the price change
        swap(poolKey, false, 40 * 1e8, ZERO_BYTES); // buy 40 btc
        (uint160 sqrtPriceX96Af,,,) = manager.getSlot0(poolKey.toId());
        uint256 repayLPValueAfPriceChange =
            getUniswapV4PriceInToken1(TICK_LOWER, TICK_UPPER, owedLiquidity, sqrtPriceX96Af);
        uint256 holdingValue = token0FromShortLp * ((sqrtPriceX96Af >> 96) ** 2) + token1FromShortLp;
        console.log("slot0 sqrtPriceX96Bf:", sqrtPriceX96Bf);
        console.log("slot0 sqrtPriceX96Af:", sqrtPriceX96Af);
        console.log("price change:", (sqrtPriceX96Af - sqrtPriceX96Bf) * 1e18 / sqrtPriceX96Bf, "/ 1e18 * 100 %");
        console.log("holdingValue:", holdingValue);
        console.log("borrowLPValueAfPriceChange:", repayLPValueAfPriceChange);

        require(repayLPValueAfPriceChange < holdingValue, "should be profit");
        _settleShortPosition(BOB, bobShortPositionId, ZERO_BYTES);
    }

    function settleInLoss() public {
        (uint160 sqrtPriceX96Bf,,,) = manager.getSlot0(poolKey.toId());
        (,,, uint128 owedLiquidity,) = hook.shortPositions(bobShortPositionId);
        uint256 shortValue = getUniswapV4PriceInToken1(TICK_LOWER, TICK_UPPER, shortLiquidity, sqrtPriceX96Bf);
        // price not change
        (uint160 sqrtPriceX96Af,,,) = manager.getSlot0(poolKey.toId());
        uint256 repayLPValueAfPriceChange =
            getUniswapV4PriceInToken1(TICK_LOWER, TICK_UPPER, owedLiquidity, sqrtPriceX96Af);

        require(repayLPValueAfPriceChange > shortValue, "should be loss");
        _settleShortPosition(BOB, bobShortPositionId, ZERO_BYTES);
    }

    function testSettleNotOwnerAfterMaturityTimestamp() public {
        uint256 token0BalanceBf = currency0.balanceOf(CAROL);
        uint256 token1BalanceBf = currency1.balanceOf(CAROL);
        (,,,, uint256 collateralAmount) = hook.shortPositions(bobShortPositionId);
        skip(31 days);
        _settleShortPosition(CAROL, bobShortPositionId, ZERO_BYTES);
        uint256 token0BalanceAf = currency0.balanceOf(CAROL);
        uint256 token1BalanceAf = currency1.balanceOf(CAROL);
        require(token0BalanceAf < token0BalanceBf, "should repay liquidity");
        require(token1BalanceAf < token1BalanceBf + collateralAmount, "should repay liquidity");
    }

    function testSettleNotOwnerExpectRevert() public {
        _settleShortPosition(CAROL, bobShortPositionId, "not settable");
    }

    function getUniswapV4PriceInToken1(int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96)
        public
        pure
        returns (uint256)
    {
        // get amount0 and amount1 from liquidity using currentSqrtPriceX96
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        return amount0 * ((sqrtPriceX96 >> 96) ** 2) + amount1;
    }
}
