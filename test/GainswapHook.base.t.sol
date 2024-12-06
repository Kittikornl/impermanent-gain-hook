// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {Deployers, IPoolManager} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Currency} from "v4-core/types/Currency.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

import {UniswapV4Oracle} from "gainswap/UniswapV4Oracle.sol";
import {GainswapHook} from "gainswap/GainswapHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract GainswapBaseTest is Test, Deployers {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FullMath for uint256;

    // tokens
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // senders
    address ALICE = makeAddr("alice");
    address BOB = makeAddr("bob");
    address CAROL = makeAddr("carol");

    PoolKey poolKey;

    UniswapV4Oracle uniswapV4Oracle;
    GainswapHook hook;

    int24 TICK_LOWER;
    int24 TICK_UPPER;

    modifier prankSender(address sender) {
        if (sender != address(this)) {
            vm.startPrank(sender, sender);
        }
        _;
        if (sender != address(this)) {
            vm.stopPrank();
        }
    }

    function setUp() public virtual {
        vm.createSelectFork("https://rpc.ankr.com/eth");
        deployFreshManagerAndRouters();

        uniswapV4Oracle = new UniswapV4Oracle();

        // note: we use btc-usd for wbtc price to simplify the test
        // in prod we need adapter for wbtc price since chainlink have only wbtc-btc
        uniswapV4Oracle.setChainlinkInfo(
            WBTC,
            UniswapV4Oracle.ChainlinkInfo({tokenAdaptor: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, maxDelay: 1 days})
        );
        uniswapV4Oracle.setChainlinkInfo(
            USDC,
            UniswapV4Oracle.ChainlinkInfo({tokenAdaptor: 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D, maxDelay: 1 days})
        );
        uniswapV4Oracle.setChainlinkInfo(
            UNI,
            UniswapV4Oracle.ChainlinkInfo({tokenAdaptor: 0x553303d460EE0afB37EdFf9bE42922D8FF63220e, maxDelay: 1 days})
        );
        uniswapV4Oracle.setChainlinkInfo(
            WETH,
            UniswapV4Oracle.ChainlinkInfo({tokenAdaptor: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, maxDelay: 1 days})
        );

        currency0 = Currency.wrap(WBTC);
        currency1 = Currency.wrap(USDC);

        address hookAddress = address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        deployCodeTo("GainswapHook.sol", abi.encode(manager, address(uniswapV4Oracle), USDC), hookAddress);

        (, int24 tick,,,,,) = IUniswapV3Pool(0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35).slot0();
        // default tick range is +-10% from current price
        // note: need to convert for tick spacing 60
        int24 tickRange = tick * 10 / 100;
        TICK_LOWER = tick - tickRange;
        TICK_UPPER = tick + tickRange;
        TICK_LOWER -= TICK_LOWER % 60;
        TICK_UPPER -= TICK_UPPER % 60;

        hook = GainswapHook(hookAddress);

        (poolKey,) =
            initPool(currency0, currency1, IHooks(hook), 3000, uniswapV4Oracle.getSqrtPriceX96(currency0, currency1));

        mintAndApproveCurrency(currency0, address(this));
        mintAndApproveCurrency(currency0, ALICE);
        mintAndApproveCurrency(currency0, BOB);
        mintAndApproveCurrency(currency0, CAROL);
        mintAndApproveCurrency(currency1, address(this));
        mintAndApproveCurrency(currency1, ALICE);
        mintAndApproveCurrency(currency1, BOB);
        mintAndApproveCurrency(currency1, CAROL);
    }

    function mintAndApproveCurrency(Currency token, address to) public prankSender(to) {
        // mint token
        deal(Currency.unwrap(token), to, 1e36);
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(hook)
        ];
        // approve all
        for (uint256 i = 0; i < toApprove.length; i++) {
            IERC20(Currency.unwrap(token)).forceApprove(toApprove[i], type(uint256).max);
        }
    }

    function _mint(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        uint96 borrowPremiumBPS,
        bytes memory expectedError
    ) internal prankSender(sender) returns (uint256 uniswapV4PositionId) {
        if (expectedError.length != 0) {
            vm.expectRevert();
        }
        uniswapV4PositionId =
            hook.mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, borrowPremiumBPS);
        if (expectedError.length != 0) {
            return 0;
        }
        GainswapHook.UniswapV4Position memory positionInfo;
        (
            positionInfo.poolKey,
            positionInfo.owner,
            positionInfo.premiumBPS,
            positionInfo.borrowedLiquidity,
            positionInfo.tickLower,
            positionInfo.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        require(PoolId.unwrap((positionInfo.poolKey.toId())) == PoolId.unwrap(poolKey.toId()), "poolId not set");
        require(positionInfo.owner == owner, "owner not set");
        require(positionInfo.premiumBPS == borrowPremiumBPS, "premiumBPS not set");
        require(positionInfo.borrowedLiquidity == 0, "borrowed liquidity should be 0");
        require(positionInfo.tickLower == tickLower, "tickLower not set");
        require(positionInfo.tickUpper == tickUpper, "tickUpper not set");
        (uint128 availableLiquidity,,) =
            manager.getPositionInfo(poolKey.toId(), address(hook), tickLower, tickUpper, bytes32(uniswapV4PositionId));
        require(availableLiquidity == liquidity, "liquidity not set");
    }

    function _addLiquidity(
        address sender,
        uint256 uniswapV4PositionId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory expectedError
    ) internal prankSender(sender) {
        GainswapHook.UniswapV4Position memory positionInfoBf;
        (
            positionInfoBf.poolKey,
            positionInfoBf.owner,
            positionInfoBf.premiumBPS,
            positionInfoBf.borrowedLiquidity,
            positionInfoBf.tickLower,
            positionInfoBf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        (uint128 availableLiquidityBf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            positionInfoBf.tickLower,
            positionInfoBf.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        if (expectedError.length != 0) {
            vm.expectRevert();
        }
        hook.addLiquidity(uniswapV4PositionId, liquidity, amount0Max, amount1Max);
        if (expectedError.length != 0) {
            return;
        }
        GainswapHook.UniswapV4Position memory positionInfoAf;
        (
            positionInfoAf.poolKey,
            positionInfoAf.owner,
            positionInfoAf.premiumBPS,
            positionInfoAf.borrowedLiquidity,
            positionInfoAf.tickLower,
            positionInfoAf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        (uint128 availableLiquidityAf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            positionInfoAf.tickLower,
            positionInfoAf.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        require(
            PoolId.unwrap((positionInfoBf.poolKey.toId())) == PoolId.unwrap(positionInfoAf.poolKey.toId()),
            "poolKey shouldn't change"
        );
        require(positionInfoBf.owner == positionInfoBf.owner, "owner shouldn't change");
        require(positionInfoBf.premiumBPS == positionInfoAf.premiumBPS, "premiumBPS shouldn't change");
        require(
            positionInfoBf.borrowedLiquidity == positionInfoAf.borrowedLiquidity, "borrowed liquidity should not change"
        );
        require(positionInfoBf.tickLower == positionInfoAf.tickLower, "tickLower shouldn't change");
        require(positionInfoBf.tickUpper == positionInfoAf.tickUpper, "tickUpper shouldn't change");
        require(availableLiquidityBf + liquidity == availableLiquidityAf, "liquidity not set");
    }

    function _removeLiquidity(
        address sender,
        uint256 uniswapV4PositionId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes memory expectedError
    ) internal prankSender(sender) {
        GainswapHook.UniswapV4Position memory positionInfoBf;
        (
            positionInfoBf.poolKey,
            positionInfoBf.owner,
            positionInfoBf.premiumBPS,
            positionInfoBf.borrowedLiquidity,
            positionInfoBf.tickLower,
            positionInfoBf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        (uint128 availableLiquidityBf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            positionInfoBf.tickLower,
            positionInfoBf.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        if (expectedError.length != 0) {
            vm.expectRevert();
        }
        hook.removeLiquidity(uniswapV4PositionId, liquidity, amount0Min, amount1Min);
        if (expectedError.length != 0) {
            return;
        }
        GainswapHook.UniswapV4Position memory positionInfoAf;
        (
            positionInfoAf.poolKey,
            positionInfoAf.owner,
            positionInfoAf.premiumBPS,
            positionInfoAf.borrowedLiquidity,
            positionInfoAf.tickLower,
            positionInfoAf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        (uint128 availableLiquidityAf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            positionInfoAf.tickLower,
            positionInfoAf.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        require(
            PoolId.unwrap((positionInfoBf.poolKey.toId())) == PoolId.unwrap(positionInfoAf.poolKey.toId()),
            "poolKey shouldn't change"
        );
        require(positionInfoBf.owner == positionInfoAf.owner, "owner shouldn't change");
        require(positionInfoBf.premiumBPS == positionInfoAf.premiumBPS, "premiumBPS shouldn't change");
        require(
            positionInfoBf.borrowedLiquidity == positionInfoAf.borrowedLiquidity, "borrowed liquidity should not change"
        );
        require(positionInfoBf.tickLower == positionInfoAf.tickLower, "tickLower shouldn't change");
        require(positionInfoBf.tickUpper == positionInfoAf.tickUpper, "tickUpper shouldn't change");
        require(availableLiquidityBf - liquidity == availableLiquidityAf, "liquidity not set");
    }

    function _collectTradingFees(address sender, uint256 uniswapV4PositionId, bytes memory expectedError)
        internal
        prankSender(sender)
    {
        if (expectedError.length != 0) {
            vm.expectRevert(expectedError);
        }
        hook.addLiquidity(uniswapV4PositionId, 0, 0, 0);
    }

    function _shortLp(
        address shorter,
        uint256 uniswapV4PositionId,
        uint256 liquidity,
        uint256 collateralAmount,
        bytes memory expectedError
    ) internal prankSender(shorter) returns (uint256 shortPositionId) {
        GainswapHook.UniswapV4Position memory uniswapPositionInfoBf;
        (
            uniswapPositionInfoBf.poolKey,
            uniswapPositionInfoBf.owner,
            uniswapPositionInfoBf.premiumBPS,
            uniswapPositionInfoBf.borrowedLiquidity,
            uniswapPositionInfoBf.tickLower,
            uniswapPositionInfoBf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);
        (uint128 availableLiquidityBf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            uniswapPositionInfoBf.tickLower,
            uniswapPositionInfoBf.tickUpper,
            bytes32(uniswapV4PositionId)
        );

        // scope to avoid stack too deep
        {
            uint256 hookCollateralBalanceBf = IERC20(USDC).balanceOf(address(hook));
            if (expectedError.length != 0) {
                vm.expectRevert(expectedError);
            }
            shortPositionId = hook.shortLp(uniswapV4PositionId, liquidity, collateralAmount);
            if (expectedError.length != 0) {
                return 0;
            }
            uint256 hookCollateralBalanceAf = IERC20(USDC).balanceOf(address(hook));
            require(
                hookCollateralBalanceBf + collateralAmount == hookCollateralBalanceAf, "hook collateral balance not set"
            );
        }
        GainswapHook.UniswapV4Position memory uniswapPositionInfoAf;
        (
            uniswapPositionInfoAf.poolKey,
            uniswapPositionInfoAf.owner,
            uniswapPositionInfoAf.premiumBPS,
            uniswapPositionInfoAf.borrowedLiquidity,
            uniswapPositionInfoAf.tickLower,
            uniswapPositionInfoAf.tickUpper
        ) = hook.uniswapV4Positions(uniswapV4PositionId);

        (uint128 availableLiquidityAf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            uniswapPositionInfoAf.tickLower,
            uniswapPositionInfoAf.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        require(
            PoolId.unwrap((uniswapPositionInfoBf.poolKey.toId())) == PoolId.unwrap(uniswapPositionInfoAf.poolKey.toId()),
            "poolKey shouldn't change"
        );
        require(uniswapPositionInfoBf.owner == uniswapPositionInfoAf.owner, "owner shouldn't change");
        require(uniswapPositionInfoBf.premiumBPS == uniswapPositionInfoAf.premiumBPS, "premiumBPS shouldn't change");

        require(uniswapPositionInfoBf.tickLower == uniswapPositionInfoAf.tickLower, "tickLower shouldn't change");
        require(uniswapPositionInfoBf.tickUpper == uniswapPositionInfoAf.tickUpper, "tickUpper shouldn't change");

        require(availableLiquidityBf - liquidity == availableLiquidityAf, "liquidity not set");

        GainswapHook.ShortPosition memory shortPositionInfoAf;
        (
            shortPositionInfoAf.uniswapV4PositionId,
            shortPositionInfoAf.owner,
            shortPositionInfoAf.maturityTimestamp,
            shortPositionInfoAf.owedLiquidity,
            shortPositionInfoAf.collateralAmount
        ) = hook.shortPositions(shortPositionId);
        require(
            uniswapPositionInfoBf.borrowedLiquidity + shortPositionInfoAf.owedLiquidity
                == uniswapPositionInfoAf.borrowedLiquidity,
            "borrowed liquidity should not change"
        );
        require(shortPositionInfoAf.uniswapV4PositionId == uniswapV4PositionId, "uniswapV4PositionId not set");
        require(shortPositionInfoAf.owner == shorter, "owner not set");
        require(shortPositionInfoAf.maturityTimestamp == block.timestamp + 30 days, "maturityTimestamp not set");
        require(
            shortPositionInfoAf.owedLiquidity
                == liquidity + liquidity.mulDivRoundingUp(uniswapPositionInfoBf.premiumBPS, 10_000),
            "owed liquidity not set"
        );
        require(shortPositionInfoAf.collateralAmount == collateralAmount, "collateralAmount not set");
    }

    function _addCollateral(address sender, uint256 shortPositionId, uint256 collateralAmount)
        internal
        prankSender(sender)
    {
        (
            uint256 uniswapV4PositionIdBf,
            address ownerBf,
            uint64 maturityTimestampBf,
            uint128 owedLiquidityBf,
            uint128 collateralAmountBf
        ) = hook.shortPositions(shortPositionId);
        hook.addCollateral(shortPositionId, collateralAmount);
        (
            uint256 uniswapV4PositionIdAf,
            address ownerAf,
            uint64 maturityTimestampAf,
            uint128 owedLiquidityAf,
            uint128 collateralAmountAf
        ) = hook.shortPositions(shortPositionId);
        require(uniswapV4PositionIdBf == uniswapV4PositionIdAf, "uniswapV4PositionId shouldn't change");
        require(ownerBf == ownerAf, "owner shouldn't change");
        require(maturityTimestampBf == maturityTimestampAf, "maturityTimestamp shouldn't change");
        require(owedLiquidityBf == owedLiquidityAf, "owed liquidity shouldn't change");
        require(collateralAmountBf + collateralAmount == collateralAmountAf, "collateralAmount not set");
    }

    function _removeCollateral(
        address sender,
        uint256 shortPositionId,
        uint256 collateralAmount,
        bytes memory expectedError
    ) internal prankSender(sender) {
        (
            uint256 uniswapV4PositionIdBf,
            address ownerBf,
            uint64 maturityTimestampBf,
            uint128 owedLiquidityBf,
            uint128 collateralAmountBf
        ) = hook.shortPositions(shortPositionId);
        if (expectedError.length != 0) {
            vm.expectRevert();
        }
        hook.removeCollateral(shortPositionId, collateralAmount);
        if (expectedError.length != 0) {
            return;
        }
        (
            uint256 uniswapV4PositionIdAf,
            address ownerAf,
            uint64 maturityTimestampAf,
            uint128 owedLiquidityAf,
            uint128 collateralAmountAf
        ) = hook.shortPositions(shortPositionId);
        require(uniswapV4PositionIdBf == uniswapV4PositionIdAf, "uniswapV4PositionId shouldn't change");
        require(ownerBf == ownerAf, "owner shouldn't change");
        require(maturityTimestampBf == maturityTimestampAf, "maturityTimestamp shouldn't change");
        require(owedLiquidityBf == owedLiquidityAf, "owed liquidity shouldn't change");
        require(collateralAmountBf - collateralAmount == collateralAmountAf, "collateralAmount not set");
    }

    function _settleShortPosition(address sender, uint256 shortPositionId, bytes memory expectedError)
        internal
        prankSender(sender)
    {
        GainswapHook.ShortPosition memory shortPositionInfoBf;
        (
            shortPositionInfoBf.uniswapV4PositionId,
            shortPositionInfoBf.owner,
            shortPositionInfoBf.maturityTimestamp,
            shortPositionInfoBf.owedLiquidity,
            shortPositionInfoBf.collateralAmount
        ) = hook.shortPositions(shortPositionId);

        GainswapHook.UniswapV4Position memory uniswapPositionInfoBf;
        (
            uniswapPositionInfoBf.poolKey,
            uniswapPositionInfoBf.owner,
            uniswapPositionInfoBf.premiumBPS,
            uniswapPositionInfoBf.borrowedLiquidity,
            uniswapPositionInfoBf.tickLower,
            uniswapPositionInfoBf.tickUpper
        ) = hook.uniswapV4Positions(shortPositionInfoBf.uniswapV4PositionId);

        (uint128 availableLiquidityBf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            uniswapPositionInfoBf.tickLower,
            uniswapPositionInfoBf.tickUpper,
            bytes32(shortPositionInfoBf.uniswapV4PositionId)
        );

        if (expectedError.length != 0) {
            vm.expectRevert(expectedError);
        }
        hook.settleShortPosition(shortPositionId);
        if (expectedError.length != 0) {
            return;
        }

        GainswapHook.ShortPosition memory shortPositionInfoAf;
        (
            shortPositionInfoAf.uniswapV4PositionId,
            shortPositionInfoAf.owner,
            shortPositionInfoAf.maturityTimestamp,
            shortPositionInfoAf.owedLiquidity,
            shortPositionInfoAf.collateralAmount
        ) = hook.shortPositions(shortPositionId);

        require(shortPositionInfoAf.uniswapV4PositionId == 0, "uniswapV4PositionId not set");
        require(shortPositionInfoAf.owner == address(0), "owner not set");
        require(shortPositionInfoAf.maturityTimestamp == 0, "maturityTimestamp not set");
        require(shortPositionInfoAf.owedLiquidity == 0, "owed liquidity not set");
        require(shortPositionInfoAf.collateralAmount == 0, "collateralAmount not set");

        GainswapHook.UniswapV4Position memory uniswapPositionInfoAf;
        (
            uniswapPositionInfoAf.poolKey,
            uniswapPositionInfoAf.owner,
            uniswapPositionInfoAf.premiumBPS,
            uniswapPositionInfoAf.borrowedLiquidity,
            uniswapPositionInfoAf.tickLower,
            uniswapPositionInfoAf.tickUpper
        ) = hook.uniswapV4Positions(shortPositionInfoBf.uniswapV4PositionId);

        (uint128 availableLiquidityAf,,) = manager.getPositionInfo(
            poolKey.toId(),
            address(hook),
            uniswapPositionInfoAf.tickLower,
            uniswapPositionInfoAf.tickUpper,
            bytes32(shortPositionInfoBf.uniswapV4PositionId)
        );

        require(
            PoolId.unwrap((uniswapPositionInfoBf.poolKey.toId())) == PoolId.unwrap(uniswapPositionInfoAf.poolKey.toId()),
            "poolKey shouldn't change"
        );
        require(uniswapPositionInfoBf.owner == uniswapPositionInfoAf.owner, "owner shouldn't change");
        require(uniswapPositionInfoBf.premiumBPS == uniswapPositionInfoAf.premiumBPS, "premiumBPS shouldn't change");
        require(
            uniswapPositionInfoBf.borrowedLiquidity - shortPositionInfoBf.owedLiquidity
                == uniswapPositionInfoAf.borrowedLiquidity,
            "borrowed liquidity should not change"
        );
        require(uniswapPositionInfoBf.tickLower == uniswapPositionInfoAf.tickLower, "tickLower shouldn't change");
        require(uniswapPositionInfoBf.tickUpper == uniswapPositionInfoAf.tickUpper, "tickUpper shouldn't change");
        require(availableLiquidityBf + shortPositionInfoBf.owedLiquidity == availableLiquidityAf, "liquidity not set");
    }
}
