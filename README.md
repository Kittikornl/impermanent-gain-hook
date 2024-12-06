# Uniswap v4 Periphery

GainSwap enables liquidity providers to earn premium fees by lending liquidity and allows impermanent loss (IL) short sellers to profit from anticipated market movements. The design incorporates direct interaction with Uniswap v4 Hooks, Oracle for price data, and a custom settlement mechanism.

### **Key Smart Contract Feature**

### **1. Liquidity Manager**

- Liquidity Provider: Manages LP deposits, withdrawals, and premium settings.
    - mint
    - addLiquidity
    - removeLiquidity
    - setPremiumBPS (lp need to take historical trading fee + IL into account )
- Shorter (Borrower): Tracks borrowed liquidity and calculates available balances for withdrawal.
    - shortLP (borrowLiquidity & removeLiquidity)
    - addCollateral
    - removeCollateral
    - settle
        - Ensures that collateral exceeds borrowed liquidity + premium fees.
        - Handles collateral seizure for expired or under-collateralized positions.

### **2. Pricing Oracle**

- Fetches real-time price data for token pairs from Chainlink.
- Calculates slot0 prices and LP token valuations for accurate fee calculations.

---

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test -vv
```

### Format

```shell
$ forge fmt
```

