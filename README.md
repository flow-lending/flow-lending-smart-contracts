# Flow Lending Smart Contract

## Overview

Flow is a peer-to-pool lending protocol implemented in Aiken on Cardano. It enables users to deposit assets as collateral, borrow against them, and interact with a common pool that manages liquidity, interest, and risk. The protocol is designed for efficiency, security, and composability, supporting batched order execution and flexible collateral management.

---

## 🏗 Protocol Architecture

### Core Components

- **Vault**: Tracks user-specific borrow positions, collateral, and loan state.
- **Pool**: Manages global liquidity, borrows, reserves, and cToken issuance.
- **Order**: Encapsulates user intent for actions (deposit, withdraw, borrow, repay, liquidate) and enables batching.
- **cToken**: Synthetic token representing user deposits, minted/burned on deposit/withdrawal.
- **Pool Info**: Stores pool configuration, supported assets, interest model, and collateral parameters.
- **Authorization Tokens**: PoolAuthToken and VaultAuthToken enforce access control and validate pool/vault UTxOs.
- **Batcher**: Processes orders in batches, ensuring atomic execution and correct indexing.

---

## 📦 Components & Data Structures

### 1. Vault

- **Purpose**: Stores user-specific borrow state tied to a lending pool.
- **Datum**: `VaultDatum`
  - `pool_id`: `OutputReference` – Pool association.
  - `borrow_id`: `OutputReference` – Unique loan instance.
  - `owner_pkh`: `PubKeyHash` – User's public key hash.
  - `owner_stake_key`: `Option<PubKeyHash>` – Optional stake key for rewards.
  - `collateral_amount`: `Int` – Amount of collateral posted.
  - `collateral_asset`: `Asset` – Collateral asset type.
  - `interest_rate`: `Int` – Fixed interest rate at loan start.
  - `start_time`: `Int` – Borrow start timestamp.
  - `principal`: `Int` – Borrowed amount.

Each `VaultDatum` enables per-loan interest accrual, collateral enforcement, and liquidation, ensuring separation between pool-level and user-level accounting.

---

### 2. Pool

- **Datum**: `PoolDatum`

  - `pool_id`: `OutputReference` – Pool instance ID.
  - `total_supplied`: `Int` – Total supplied liquidity.
  - `total_borrowed`: `Int` – Outstanding borrows.
  - `reserve`: `Int` – Protocol-held reserves.
  - `total_ctoken`: `Int` – cTokens in circulation.

- **Redeemers**:
  - `ApplyDeposit`, `ApplyWithdraw`, `ApplyBorrow`, `ApplyRepay`, `ApplyLiquidate`

---

### 3. Order

- **Purpose**: User-intent wrapper for action batching.
- **Datum**: `OrderDatum` (Enum)
  - `ODeposit`, `OWithdraw`, `OBorrow`, `ORepay`, `OLiquidate`

---

### 4. cToken

- **Purpose**: Synthetic token representing user deposits.
- **Lifecycle**: Minted on deposit, burned on withdrawal. Tracks user share of pool liquidity.
- **Profit**: When a user withdraws, the cToken is redeemed at a higher exchange rate than when deposited—representing earned interest from borrowers.

  `underlying_received = ctoken_amount × (total_supplied / total_ctoken)`

---

### 5. Pool Info

- **Purpose**: Parameters and configuration for each lending pool.
- **Datum**: `PoolInfoDatum`
  - `pool_id`: `OutputReference` – Pool identifier.
  - `envelope_amount`: `Int` – Minimum batch size for execution.
  - `pool_asset`: `Asset` – Borrowed asset (debt token).
  - `ctoken`: `Asset` – cToken for depositors.
  - `vault_authtoken`: `Asset` – Vault authorization token.
  - `batcher_policy_id`: `ByteArray` – Restricts order processing to authorized batchers.
  - `vault_script_hash`: `ByteArray` – Expected vault script hash.
  - `pool_stake_key`: `Option<PubKeyHash>` – Optional reward key.
  - `reserve_factor_percentage`: `Int` – Protocol reserve share.
  - `collateral_infos`: `List<CollateralInfo>` – Supported collateral types and parameters.
  - `kink`: `Int` – Utilization point for interest curve change.
  - `base_rate`: `Int` – Minimum interest rate.
  - `slope_low`: `Int` – Interest slope before kink.
  - `slope_high`: `Int` – Slope after kink.

---

### 6. Authorization Tokens

- **PoolAuthToken**: Validates pool UTxOs and restricts pool operations.
- **VaultAuthToken**: Validates vault UTxOs and restricts vault operations.

---

### 7. Batcher

- **Purpose**: Applies orders in batches atomically, enforcing correct order and access control via redeemers.

---

## 🔣 Interest Model

- **Jump Rate Model**:
  - Low utilization: Gradual interest increase (`slope_low`).
  - Above kink: Steep interest increase (`slope_high`).
- **Mechanics**:
  - Uses `interest_index` for compounding.
  - Normalized by `year_in_milliseconds` constant.

Let:

- `U` = utilization = `total_borrowed / total_supplied`
- `kink` = utilization threshold
- `r_borrow` = interest rate charged to borrowers

Then:

```
if U ≤ kink:
    r_borrow = base_rate + slope_low × U
else:
    r_borrow = base_rate + slope_low × kink + slope_high × (U - kink)
```

- This model encourages borrowing when utilization is low and discourages it when high.
- Interest accrues to the pool continuously and is distributed to depositors via cToken value growth.

---

## 🔄 User Lifecycle

1. **Deposit**: Mint cTokens, increase `total_supplied`.
2. **Borrow**: Update vault principal, increase `total_borrowed`.
3. **Repay**: Reduce principal, update interest.
4. **Withdraw**: Burn cTokens, adjust liquidity.
5. **Liquidate**: Seize undercollateralized collateral.

---

## 📈 Oracle Integration

- **Purpose**: Ensures up-to-date collateral pricing and liquidation checks.
- **Required for**:
  - Collateral ratio enforcement
  - Liquidation validation

---

## 🛡 Security & Access Control

- **User actions**: Require user signature for orders.
- **Auth tokens**: Restrict mint/burn to valid pool/vault operations.

---

## 🧩 Extensibility

- **Collateral types**: Configurable via `PoolInfoDatum`.
- **Interest model**: Adjustable via pool parameters.
- **Batching**: Supports atomic multi-action execution for efficiency.
