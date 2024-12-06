// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IUniswapV4Oracle {
    function getUniswapV4Price(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256);

    function getPrice(address token) external view returns (uint256);
}
