// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./GainswapHook.base.t.sol";

contract GainswapBaseLiquidityProviderTest is GainswapBaseTest {
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    function testMintLiquidity_fuzz(uint256 liquidityIndex, uint256 tickLowerIndex, uint256 tickUpperIndex) public {
        uint128 liquidityDesired = bound(liquidityIndex, 1e5, 1e18).toUint128();
        int24 tickLower = TICK_LOWER - (bound(tickLowerIndex, 0, 1000) * 60).toInt256().toInt24();
        int24 tickUpper = TICK_UPPER + (bound(tickUpperIndex, 0, 1000) * 60).toInt256().toInt24();
        _mint(
            ALICE,
            tickLower,
            tickUpper,
            liquidityDesired,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
    }

    function testAddLiquidity_fuzz(uint256 liquidityIndex, uint256 tickLowerIndex, uint256 tickUpperIndex) public {
        uint128 liquidityDesired = bound(liquidityIndex, 1e5, 1e18).toUint128();
        int24 tickLower = TICK_LOWER - (bound(tickLowerIndex, 0, 1000) * 60).toInt256().toInt24();
        int24 tickUpper = TICK_UPPER + (bound(tickUpperIndex, 0, 1000) * 60).toInt256().toInt24();
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            tickLower,
            tickUpper,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );

        _addLiquidity(ALICE, uniswapV4PositionId, liquidityDesired, type(uint128).max, type(uint128).max, ZERO_BYTES);
    }

    function testRemoveLiquidity_fuzz(uint256 liquidityIndex, uint256 tickLowerIndex, uint256 tickUpperIndex) public {
        uint128 liquidityDesired = bound(liquidityIndex, 0, 1e18).toUint128();
        int24 tickLower = TICK_LOWER - (bound(tickLowerIndex, 0, 1000) * 60).toInt256().toInt24();
        int24 tickUpper = TICK_UPPER + (bound(tickUpperIndex, 0, 1000) * 60).toInt256().toInt24();
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            tickLower,
            tickUpper,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        _removeLiquidity(ALICE, uniswapV4PositionId, liquidityDesired, 0, 0, ZERO_BYTES);
    }

    function testCollectTradingFees() public {
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        // collect 0 trading fees
        _collectTradingFees(ALICE, uniswapV4PositionId, ZERO_BYTES);
        // collect trading fees
        swap(poolKey, true, (currency0.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        swap(poolKey, false, (currency1.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        uint256 balance0Bf = currency0.balanceOf(ALICE);
        uint256 balance1Bf = currency1.balanceOf(ALICE);
        _collectTradingFees(ALICE, uniswapV4PositionId, ZERO_BYTES);
        uint256 balance0Af = currency0.balanceOf(ALICE);
        uint256 balance1Af = currency1.balanceOf(ALICE);
        // fees should be collected
        require(balance0Af > balance0Bf, "fees not collected");
        require(balance1Af > balance1Bf, "fees not collected");
        // bob claim fees for alice
        // this might be useful for implementing vault
        swap(poolKey, true, (currency0.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        swap(poolKey, false, (currency1.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        balance0Bf = currency0.balanceOf(ALICE);
        balance1Bf = currency1.balanceOf(ALICE);
        _collectTradingFees(BOB, uniswapV4PositionId, ZERO_BYTES);
        balance0Af = currency0.balanceOf(ALICE);
        balance1Af = currency1.balanceOf(ALICE);
        // fees should be collected
        require(balance0Af > balance0Bf, "fees not collected 2");
        require(balance1Af > balance1Bf, "fees not collected 2");
    }

    function testAddLiquidityDirectlyToPoolExpectRevert() public {
        // note: we need to force every liquidity provider to use GainswapHook
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testMintSlippageExpectRevert() public {
        _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            0,
            0,
            ALICE,
            1_000, // 10%
            "max slippage exceeded"
        );
    }

    function testAddLiquiditySlippageExpectRevert() public {
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        _addLiquidity(ALICE, uniswapV4PositionId, 1e18, 0, 0, "max slippage exceeded");
    }

    function testRemoveLiquidityNotOwnerExpectRevert() public {
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        _removeLiquidity(BOB, uniswapV4PositionId, 1e18, 0, 0, "not owner");
    }

    function testRemoveLiquidityExcessAvailableLiquidityExpectRevert() public {
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        _removeLiquidity(ALICE, uniswapV4PositionId, 1e18 + 1, 0, 0, "not enough liquidity");
    }

    function testRemoveLiquiditySlippageExpectRevert() public {
        uint256 uniswapV4PositionId = _mint(
            ALICE,
            TICK_LOWER,
            TICK_UPPER,
            1e18,
            type(uint128).max,
            type(uint128).max,
            ALICE,
            1_000, // 10%
            ZERO_BYTES
        );
        _removeLiquidity(
            ALICE, uniswapV4PositionId, 1e18, type(uint128).max, type(uint128).max, "max slippage exceeded"
        );
    }
}
