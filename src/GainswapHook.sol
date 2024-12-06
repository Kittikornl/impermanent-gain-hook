// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks, IHooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {SlippageCheck} from "v4-periphery/libraries/SlippageCheck.sol";

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV4Oracle} from "./interfaces/IUniswapV4Oracle.sol";

contract GainswapHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SlippageCheck for BalanceDelta;

    using FullMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    struct UniswapV4Position {
        PoolKey poolKey;
        address owner;
        uint96 premiumBPS; // premium to pay for borrowing position
        uint128 borrowedLiquidity; // amount of liquidity borrowed
        int24 tickLower;
        int24 tickUpper;
    }

    struct ShortPosition {
        uint256 uniswapV4PositionId;
        address owner;
        uint64 maturityTimestamp; // timestamp when position matures (needs to be settled)
        uint128 owedLiquidity; // borrowed liquidity + premium
        uint128 collateralAmount; // amount of usdc deposited as collateral
    }

    struct CallbackData {
        address sender;
        address owner;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
    }

    mapping(uint256 => UniswapV4Position) public uniswapV4Positions;
    mapping(uint256 => ShortPosition) public shortPositions;

    address public immutable oracle;
    address public immutable usdc;
    uint256 public lastUniswapV4Id;
    uint256 public lastShortPositionId;

    constructor(IPoolManager _poolManager, address _oracle, address _usdc) BaseHook(_poolManager) {
        oracle = _oracle;
        usdc = _usdc;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice make this hook only entry point for adding liquidity
    /// @param sender sender address
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        require(sender == address(this), "not GainswapHook");
        return IHooks.beforeAddLiquidity.selector;
    }

    function mint(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        uint96 borrowPremiumBPS
    ) external returns (uint256 positionId) {
        unchecked {
            positionId = ++lastUniswapV4Id;
        }
        // Initialize the position info
        uniswapV4Positions[positionId] = UniswapV4Position({
            poolKey: key,
            owner: owner,
            borrowedLiquidity: 0,
            tickLower: tickLower,
            tickUpper: tickUpper,
            premiumBPS: borrowPremiumBPS
        });

        // we ignore fees accrued in this case
        (BalanceDelta delta,) =
            _modifyLiquidity(msg.sender, key, tickLower, tickUpper, liquidity.toInt256().toInt128(), positionId);
        delta.validateMaxIn(amount0Max, amount1Max);
    }

    function addLiquidity(uint256 uniswapV4PositionId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max)
        external
    {
        UniswapV4Position memory uniswapV4Position = uniswapV4Positions[uniswapV4PositionId];

        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) = _modifyLiquidity(
            uniswapV4Position.owner,
            uniswapV4Position.poolKey,
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            liquidity.toInt256().toInt128(),
            uniswapV4PositionId
        );
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        BalanceDelta delta = liquidityDelta - feesAccrued;
        delta.validateMaxIn(amount0Max, amount1Max);
    }

    function removeLiquidity(uint256 uniswapV4PositionId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min)
        external
    {
        UniswapV4Position memory uniswapV4Position = uniswapV4Positions[uniswapV4PositionId];
        require(msg.sender == uniswapV4Position.owner, "not owner");

        (uint128 availableLiquidity,,) = poolManager.getPositionInfo(
            uniswapV4Position.poolKey.toId(),
            address(this),
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        require(availableLiquidity >= liquidity, "not enough liquidity");

        // remove liquidity from position
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) = _modifyLiquidity(
            msg.sender,
            uniswapV4Position.poolKey,
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            -(liquidity.toInt256().toInt128()),
            uniswapV4PositionId
        );
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        BalanceDelta delta = liquidityDelta - feesAccrued;
        delta.validateMinOut(amount0Min, amount1Min);
    }

    function setPremiumBPS(uint256 uniswapV4PositionId, uint96 premiumBPS) external {
        UniswapV4Position storage uniswapV4Position = uniswapV4Positions[uniswapV4PositionId];
        require(msg.sender == uniswapV4Position.owner, "not owner");
        uniswapV4Position.premiumBPS = premiumBPS;
    }

    function isPositionHealthy(
        UniswapV4Position memory uniswapV4Position,
        uint256 collateralAmount,
        uint256 owedLiquidity
    ) public view returns (bool) {
        uint256 uniswapV4PositionValue = IUniswapV4Oracle(oracle).getUniswapV4Price(
            uniswapV4Position.poolKey,
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            owedLiquidity.toUint128()
        );

        uint256 collateralValue = collateralAmount * IUniswapV4Oracle(oracle).getPrice(usdc);
        return (collateralValue * 90 / 100 > uniswapV4PositionValue);
    }

    function shortLp(uint256 uniswapV4PositionId, uint256 liquidity, uint256 collateralAmount)
        external
        returns (uint256 positionId)
    {
        unchecked {
            positionId = ++lastShortPositionId;
        }
        // get uniswap v4 position info
        UniswapV4Position memory uniswapV4Position = uniswapV4Positions[uniswapV4PositionId];
        (uint128 availableLiquidity,,) = poolManager.getPositionInfo(
            uniswapV4Position.poolKey.toId(),
            address(this),
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            bytes32(uniswapV4PositionId)
        );
        require(availableLiquidity >= liquidity, "not enough liquidity");

        // validate that collateral is enough
        uint256 owedLiquidity = liquidity + liquidity.mulDivRoundingUp(uniswapV4Position.premiumBPS, 10_000);
        require(isPositionHealthy(uniswapV4Position, collateralAmount, owedLiquidity), "short position not healthy");
        // update short position info
        ShortPosition memory shortPosition = ShortPosition({
            uniswapV4PositionId: uniswapV4PositionId,
            owner: msg.sender,
            maturityTimestamp: (block.timestamp + 30 days).toUint64(),
            owedLiquidity: owedLiquidity.toUint128(),
            collateralAmount: collateralAmount.toUint128()
        });
        shortPositions[positionId] = shortPosition;
        // update position info
        uniswapV4Position.borrowedLiquidity += uint128(owedLiquidity);
        uniswapV4Positions[uniswapV4PositionId] = uniswapV4Position;
        // transfer collateral
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), collateralAmount);

        _modifyLiquidity(
            uniswapV4Position.owner,
            uniswapV4Position.poolKey,
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            -(uint256(liquidity)).toInt256().toInt128(),
            uniswapV4PositionId
        );
    }

    function addCollateral(uint256 shortPositionId, uint256 amount) external {
        ShortPosition storage shortPosition = shortPositions[shortPositionId];
        shortPosition.collateralAmount += amount.toUint128();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
    }

    function removeCollateral(uint256 shortPositionId, uint256 amount) external {
        ShortPosition memory shortPosition = shortPositions[shortPositionId];
        require(msg.sender == shortPosition.owner, "not owner");
        require(
            isPositionHealthy(
                uniswapV4Positions[shortPosition.uniswapV4PositionId],
                shortPosition.collateralAmount - amount,
                shortPosition.owedLiquidity
            ),
            "short position not healthy"
        );
        shortPosition.collateralAmount -= amount.toUint128();
        shortPositions[shortPositionId] = shortPosition;
        IERC20(usdc).safeTransfer(msg.sender, amount);
    }

    function settleShortPosition(uint256 shortPositionId) external payable {
        // check that position is matured or if position owner
        ShortPosition memory shortPosition = shortPositions[shortPositionId];
        bool isSettable = block.timestamp >= shortPosition.maturityTimestamp || msg.sender == shortPosition.owner;
        UniswapV4Position memory uniswapV4Position = uniswapV4Positions[shortPosition.uniswapV4PositionId];
        require(
            isSettable
                || !isPositionHealthy(uniswapV4Position, shortPosition.collateralAmount, shortPosition.owedLiquidity),
            "not settable"
        );
        // update uniswap position info
        unchecked {
            // note: we can safely subtract owed liquidity from borrowed liquidity since
            // borrowed liquidity is sum of  all owed liquidity
            uniswapV4Position.borrowedLiquidity -= uint128(shortPosition.owedLiquidity);
        }
        uniswapV4Positions[shortPosition.uniswapV4PositionId] = uniswapV4Position;
        // remove short position info
        delete shortPositions[shortPositionId];
        // close short position and transfer collateral
        // note: in real world scenario, we should revamp this settlement incentive
        // for now => settler get all collateral
        IERC20(usdc).safeTransfer(msg.sender, shortPosition.collateralAmount);
        // add owed liquidity to position
        _modifyLiquidity(
            uniswapV4Position.owner,
            uniswapV4Position.poolKey,
            uniswapV4Position.tickLower,
            uniswapV4Position.tickUpper,
            int128(shortPosition.owedLiquidity),
            shortPosition.uniswapV4PositionId
        );
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        // decode callback data
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        (BalanceDelta delta, BalanceDelta feesAccrued) =
            poolManager.modifyLiquidity(data.key, data.params, data.hookData);
        // transfer trading fees to owner if sender is not owner
        if (data.sender != data.owner) {
            _take(data.key.currency0, data.owner, feesAccrued.amount0());
            _take(data.key.currency1, data.owner, feesAccrued.amount1());
        }

        // transfer delta to sender
        BalanceDelta senderDelta = data.sender != data.owner ? delta - feesAccrued : delta;
        int128 delta0 = senderDelta.amount0();
        int128 delta1 = senderDelta.amount1();

        if (delta0 < 0) _settle(data.key.currency0, data.sender, delta0);
        if (delta1 < 0) _settle(data.key.currency1, data.sender, delta1);
        if (delta0 > 0) _take(data.key.currency0, data.sender, delta0);
        if (delta1 > 0) _take(data.key.currency1, data.sender, delta1);
        return abi.encode(delta, feesAccrued);
    }

    function _modifyLiquidity(
        address owner,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        uint256 salt
    ) internal returns (BalanceDelta, BalanceDelta) {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(salt)
        });
        bytes memory data = poolManager.unlock(abi.encode(CallbackData(msg.sender, owner, key, params, new bytes(0))));
        return abi.decode(data, (BalanceDelta, BalanceDelta));
    }

    /// @notice Take an amount of currency out of the PoolManager
    /// @param currency Currency to take
    /// @param recipient Address to receive the currency
    /// @param amount Amount to take
    /// @dev Returns early if the amount is 0
    function _take(Currency currency, address recipient, int128 amount) internal {
        if (amount == 0) return;
        poolManager.take(currency, recipient, int256(amount).toUint256());
    }

    /// @notice Pay and settle a currency to the PoolManager
    /// @dev The implementing contract must ensure that the `payer` is a secure address
    /// @param currency Currency to settle
    /// @param payer Address of the payer
    /// @param amount Amount to send
    /// @dev Returns early if the amount is 0
    function _settle(Currency currency, address payer, int128 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        uint256 amountAbs = int256(-amount).toUint256();
        if (currency.isAddressZero()) {
            poolManager.settle{value: amountAbs}();
        } else {
            address token = Currency.unwrap(currency);
            IERC20(token).safeTransferFrom(payer, address(poolManager), amountAbs);
            poolManager.settle();
        }
    }
}
