
pragma solidity ^0.8.0;

import "./GainswapHook.base.t.sol";

contract UniswapV4OracleTest is GainswapBaseTest {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 constant DIFF_0_5_PERCENT = 5e15; // 0.5%

    function testSqrtPriceOracleBTCUSDC() public view {
        // check with UniswapV3Pool (wbtc-usdc 0.3)
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35).slot0();
        uint256 sqrtPriceX96Oracle = uniswapV4Oracle.getSqrtPriceX96(currency0, currency1);
        console.log("pool price  :", sqrtPriceX96);
        console.log("oracle price:", sqrtPriceX96Oracle);
        // note this can be off since oracle can be deviated
        // (let's say 0.5% is close enough)
        assertApproxEqRel(sqrtPriceX96, sqrtPriceX96Oracle, DIFF_0_5_PERCENT, "not close enough");
    }

    function testSqrtPriceOracleUNIWETH() public view {
        // check with UniswapV3Pool (UNI-WETH 0.3)
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801).slot0();
        uint256 sqrtPriceX96Oracle = uniswapV4Oracle.getSqrtPriceX96(Currency.wrap(UNI), Currency.wrap(WETH));
        console.log("pool price  :", sqrtPriceX96);
        console.log("oracle price:", sqrtPriceX96Oracle);
        // note this can be off since oracle can be deviated
        // (let's say 0.5% is close enough)
        assertApproxEqRel(sqrtPriceX96, sqrtPriceX96Oracle, DIFF_0_5_PERCENT, "not close enough");
    }

    function testUniswapV4PositionPriceInRange_fuzz(uint256 liquidity) public {
        uint128 liquidityDesired = bound(liquidity, 1e5, 1e18).toUint128();
        uint256 currency0BalanceBf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceBf = currency1.balanceOf(ALICE);
        _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            liquidityDesired,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            new bytes(0)
        );
        uint256 currency0BalanceAf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceAf = currency1.balanceOf(ALICE);

        uint256 price = uniswapV4Oracle.getUniswapV4Price(poolKey, TICK_LOWER, TICK_UPPER, liquidityDesired);
        // check if the price is correct
        uint256 usedVal =
            (currency0BalanceBf - currency0BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency0));
        usedVal += (currency1BalanceBf - currency1BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency1));
        require(currency0BalanceBf - currency0BalanceAf > 0, "should be positive");
        require(currency1BalanceBf - currency1BalanceAf > 0, "shounld be positive");
        assertApproxEqRel(price, usedVal, DIFF_0_5_PERCENT, "price not match");
    }

    function testUniswapV4PositionPriceOutOfRangeUpper_fuzz(uint256 liquidity) public {
        uint128 liquidityDesired = bound(liquidity, 1e5, 1e18).toUint128();
        uint256 currency0BalanceBf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceBf = currency1.balanceOf(ALICE);
        (, int24 tick,,) = manager.getSlot0(poolKey.toId());
        int24 tickUpper = tick - tick % 60 - 120;
        _mint(
            ALICE,
            TICK_LOWER,
            tickUpper,
            liquidityDesired,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            new bytes(0)
        );
        uint256 currency0BalanceAf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceAf = currency1.balanceOf(ALICE);

        uint256 price = uniswapV4Oracle.getUniswapV4Price(poolKey, TICK_LOWER, tickUpper, liquidityDesired);
        // check if the price is correct
        uint256 usedVal =
            (currency0BalanceBf - currency0BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency0));
        usedVal += (currency1BalanceBf - currency1BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency1));
        require(currency0BalanceBf - currency0BalanceAf == 0, "should be zero");
        require(currency1BalanceBf - currency1BalanceAf > 0, "shounld be positive");
        assertApproxEqRel(price, usedVal, DIFF_0_5_PERCENT, "price not match");
    }

    function testUniswapV4PositionPriceOutOfRangeLower_fuzz(uint256 liquidity) public {
        uint128 liquidityDesired = bound(liquidity, 1e5, 1e18).toUint128();
        uint256 currency0BalanceBf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceBf = currency1.balanceOf(ALICE);
        (, int24 tick,,) = manager.getSlot0(poolKey.toId());
        int24 tickLower = tick - tick % 60 + 120;
        _mint(
            ALICE,
            tickLower,
            TICK_UPPER,
            liquidityDesired,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            new bytes(0)
        );
        uint256 currency0BalanceAf = currency0.balanceOf(ALICE);
        uint256 currency1BalanceAf = currency1.balanceOf(ALICE);

        uint256 price = uniswapV4Oracle.getUniswapV4Price(poolKey, tickLower, TICK_UPPER, liquidityDesired);
        // check if the price is correct
        uint256 usedVal =
            (currency0BalanceBf - currency0BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency0));
        usedVal += (currency1BalanceBf - currency1BalanceAf) * uniswapV4Oracle.getPrice(Currency.unwrap(currency1));
        require(currency0BalanceBf - currency0BalanceAf > 0, "shounld be positive");
        require(currency1BalanceBf - currency1BalanceAf == 0, "should be zero");
        assertApproxEqRel(price, usedVal, DIFF_0_5_PERCENT, "price not match");
    }
}
