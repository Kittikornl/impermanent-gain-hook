// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./GainswapHook.base.t.sol";

contract GainswapBaseShorterTest is GainswapBaseTest {
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    uint256 aliceUniswapV4PositionId;

    function setUp() public override {
        super.setUp();
        // alice provides liquidity
        aliceUniswapV4PositionId = _mint(
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
    }

    function testShortLp_fuzz(uint256 liquidity) public {
        uint128 liquidityDesired = bound(liquidity, 1e5, 1e18).toUint128();
        uint256 token0BalanceBf = currency0.balanceOf(BOB);
        uint256 token1BalanceBf = currency1.balanceOf(BOB);
        // shortLp (fuzz)
        _shortLp(BOB, aliceUniswapV4PositionId, liquidityDesired, 1e30, ZERO_BYTES);
        uint256 token0BalanceAf = currency0.balanceOf(BOB);
        uint256 token1BalanceAf = currency1.balanceOf(BOB);
        // check if the balance is correct
        require(token0BalanceAf > token0BalanceBf, "should have more token0");
        // note: remove 1e30 since token1 and collateral are the same token
        // and we deposit 1e30 token1 as collateral
        require(token1BalanceAf > token1BalanceBf - 1e30, "should have more token1");
    }

    function testShortLpAfterSwap_fuzz(uint256 liquidity) public {
        uint128 liquidityDesired = bound(liquidity, 1e5, 1e18).toUint128();
        uint256 aliceToken0BalanceBf = currency0.balanceOf(ALICE);
        uint256 aliceToken1BalanceBf = currency1.balanceOf(ALICE);
        uint256 bobToken0BalanceBf = currency0.balanceOf(BOB);
        uint256 bobToken1BalanceBf = currency1.balanceOf(BOB);
        swap(poolKey, true, (currency0.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        swap(poolKey, false, (currency1.balanceOf(address(manager)) / 10000).toInt256(), ZERO_BYTES);
        // shortLp (fuzz)
        _shortLp(BOB, aliceUniswapV4PositionId, liquidityDesired, 1e30, ZERO_BYTES);
        uint256 aliceToken0BalanceAf = currency0.balanceOf(ALICE);
        uint256 aliceToken1BalanceAf = currency1.balanceOf(ALICE);
        uint256 bobToken0BalanceAf = currency0.balanceOf(BOB);
        uint256 bobToken1BalanceAf = currency1.balanceOf(BOB);
        // check if the balance is correct
        require(aliceToken0BalanceAf > aliceToken0BalanceBf, "should have more token0");
        require(aliceToken1BalanceAf > aliceToken1BalanceBf, "should have more token1");
        require(bobToken0BalanceAf > bobToken0BalanceBf, "should have more token0");
        // note: remove 1e30 since token1 and collateral are the same token
        // and we deposit 1e30 token1 as collateral
        require(bobToken1BalanceAf > bobToken1BalanceBf - 1e30, "should have more token1");
    }

    function testAddCollateral_fuzz(uint256 amount) public {
        uint256 shortPositionId = _shortLp(BOB, aliceUniswapV4PositionId, 1e10, 1e18, ZERO_BYTES);
        uint256 amountDesired = bound(amount, 0, currency1.balanceOf(BOB));
        // add collateral (fuzz)
        _addCollateral(BOB, shortPositionId, amountDesired);
    }

    function testRemoveCollateral_fuzz(uint256 amount) public {
        uint256 amountDesired = bound(amount, 0, 1e20);
        uint256 shortPositionId = _shortLp(BOB, aliceUniswapV4PositionId, 1e10, 1e30, ZERO_BYTES);
        // remove collateral (fuzz)
        _removeCollateral(BOB, shortPositionId, amountDesired, ZERO_BYTES);
    }

    function testRemoveCollateralNotEnoughCollateralExpectRevert() public {
        uint256 shortPositionId = _shortLp(BOB, aliceUniswapV4PositionId, 1e10, 1e30, ZERO_BYTES);
        // remove collateral (not enough collateral) (expected revert)
        _removeCollateral(BOB, shortPositionId, 1e30, "short position not healthy");
    }

    function testShortLpNotEnoughCollateralExpectRevert() public {
        // shortLp (not enough collateral) (expected revert)
        _shortLp(BOB, aliceUniswapV4PositionId, 1e18, 0, "short position not healthy");
    }

    function testShortLpNotEnoughLiquidityExpectRevert() public {
        _shortLp(BOB, aliceUniswapV4PositionId, 1e18 + 1, 1e30, "not enough liquidity");
    }
}
