Perennial V2 Perpetuals Liquidation Bot — Core Logic Specification

Purpose

Build a profitable liquidation bot for Perennial V2 perpetual markets.

This bot:
	•	Detects undercollateralized (underwater) positions
	•	Calculates liquidation profitability
	•	Executes liquidation via Perennial’s settlement mechanism
	•	Uses Aave flash loans for capital efficiency
	•	Earns profit from liquidation fees

This document defines how liquidation works on Perennial V2, what to index, and how profit is calculated.

⸻

1. Protocol Reality (Read This First)

Perennial V2 does NOT have a liquidate() function.

Liquidation in Perennial V2:
	•	Is implicit
	•	Occurs during position settlement
	•	Is finalized on the next oracle price update
	•	Rewards the initiator of a protected update

Liquidation is triggered by:

update(..., protect = true)

The caller becomes the liquidator.

⸻

2. Liquidation Lifecycle in Perennial V2

Step 1 — Position Becomes Undercollateralized

A position is unsafe when:

Equity < Maintenance Requirement

This can happen due to:
	•	Oracle price movement
	•	Funding accrual
	•	Fees
	•	Leverage increase

⸻

Step 2 — Liquidation Initiation

Anyone can initiate liquidation by submitting an update() call that:
	•	Settles the account
	•	Sets protect = true
	•	Locks the account

This:
	•	Prevents further updates
	•	Prevents competing liquidations

⸻

Step 3 — Oracle Settlement

Liquidation does not finalize immediately.

It settles:
	•	On the next oracle version
	•	During _processOrderLocal()

⸻

Step 4 — Liquidation Reward

During settlement:

_credit(liquidator, liquidationFee)

The reward is credited to claimable.

Withdraw using:

claimFee()


⸻

3. What the Bot Must Index (Critical)

The bot must track accounts and market state.

Market-Level Data
	•	Oracle price (latest + pending)
	•	Maintenance margin ratio
	•	Liquidation fee ratio
	•	Funding rate
	•	Settlement timing

Account-Level Data
	•	Collateral balance
	•	Position size (long / short)
	•	Entry price (VWAP)
	•	Pending orders
	•	Accrued funding
	•	Accrued fees

⸻

4. Core Liquidation Math

4.1 Position Notional

notional = abs(positionSize × oraclePrice)

4.2 Unrealized PnL

pnl = positionSize × (oraclePrice − entryPrice)

4.3 Equity

equity =
  collateral
+ pnl
− fundingAccrued
− feesAccrued

4.4 Maintenance Requirement

maintenance = notional × maintenanceMarginRatio

4.5 Liquidatable Condition

equity < maintenance

Use a buffer to avoid race conditions:

equity < maintenance × 1.02


⸻

5. Liquidation Reward Calculation

Perennial pays liquidators:

liquidationReward = maintenance × liquidationFee

This is the ONLY source of profit.

⸻

6. Profitability Check (Mandatory)

Costs

gasCost
+ flashLoanFee
+ oracleUpdateCost (if any)

Profit Condition

liquidationReward > totalCost + safetyMargin

If this fails → DO NOT LIQUIDATE

⸻

7. Flash Loan Usage (Aave)

Flash loans are used to:
	•	Temporarily fund margin settlement
	•	Cover collateral movements if required

Flow
	1.	Borrow funds from Aave
	2.	Call Perennial update(... protect = true)
	3.	Wait for oracle settlement
	4.	Claim liquidation fee
	5.	Repay flash loan
	6.	Keep profit

⚠️ Flash loan must be repaid in the same transaction — ensure reward liquidity allows this.

⸻

8. Execution Flow Summary

1. Observe oracle price update
2. Recalculate equity for tracked accounts
3. Identify underwater positions
4. Estimate liquidation reward
5. Check profitability
6. Execute protected update
7. Wait for oracle settlement
8. Claim liquidation fee


⸻

9. Key Constraints & Risks
	•	Oracle update delay introduces risk
	•	Competing liquidators may front-run
	•	Partial liquidations are NOT supported
	•	All math must be conservative
	•	Failed liquidation = gas loss

⸻

10. What the LLM Must Produce

The LLM should output:
	•	Liquidation detection logic
	•	On-chain math functions
	•	Profit estimation logic
	•	Flash loan integration plan
	•	Safety buffers & guards
	•	Comments explaining Perennial V2 mechanics

DO NOT:
	•	Invent liquidate() functions
	•	Assume instant liquidation
	•	Ignore oracle settlement delays
	•	Rely on off-chain keepers

⸻

11. Goal

A deterministic, math-driven, profitable Perennial V2 liquidation bot.

Focus on:
	•	Precision
	•	Risk management
	•	Capital efficiency




note : profit should be sent to profit receiver


# Perennial Perp Liquidation Bot - LLM Instructions

## Objective

Build a bot that can liquidate undercollateralized positions on Perennial V2 perpetuals and capture profit. The bot should handle:

* Position indexing
* Profit calculations
* Detecting underwater positions
* Executing flash loans from Aave for liquidations
* Integrating Reactive Network for on-chain event subscriptions and periodic view function checks

---

## 1. Understanding Liquidation on Perennial

### Key Concepts:

* Positions can be long or short with leverage
* Liquidation is possible when `collateralization ratio < maintenance margin`
* There is **no direct `Liquidatable` event** emitted by the contract
* Relevant contracts:

  * `MarketV2` (positions, orders)
  * `Perennial` core contracts
* Important data for calculating liquidation:

  * Position size
  * Collateral amount
  * Mark price of the underlying asset
  * Maintenance margin ratio

### Liquidation Logic:

1. Calculate position’s current value:

   ```
   position_value = position_size * mark_price
   ```
2. Calculate collateralization:

   ```
   collateralization_ratio = collateral / position_value
   ```
3. Compare with `maintenance_margin`:

   * If `collateralization_ratio < maintenance_margin`, position is undercollateralized → eligible for liquidation
4. Compute potential profit:

   ```
   profit = (repay_amount + liquidation_bonus) - flash_loan_fee - gas_fee
   ```

---

## 2. Flash Loan Integration (Aave)

* Steps to perform a flash loan liquidation:

  1. Borrow required token via Aave flash loan
  2. Repay the undercollateralized position on Perennial
  3. Collect liquidation reward/bonus
  4. Swap collateral if needed
  5. Repay flash loan
  6. Keep remaining profit

* Ensure you account for:

  * Aave flash loan fees
  * Slippage in swaps
  * Gas fees

---

## 3. Position Indexing

### Events to Track

Perennial V2 emits these key events (subscribe via Reactive Network):

* `Updated()` → Position updates
* `OrderAdded()` → New order added
* `OrderUpdated()` → Order updated

> Note: There is no `LiquidationPending` or `UnderCollateralized` event. We rely on these updates to track changes in positions and compute collateralization in real-time.

### View Functions for Periodic Checks

Poll these view functions to ensure you capture positions that may not emit events:

* `positions(address account)` → Current position details
* `global()` → Market exposure
* `parameter()` → Maintenance margin and risk parameters

---

## 4. Reactive Contract Integration

Reactive Network allows **on-chain event subscriptions** and can trigger functions when events occur.

### Links

* [Reactive Network Overview](https://dev.reactive.network/education/introduction)
* [Prerequisites](https://dev.reactive.network/education/introduction/prerequisites)

### Setup

1. Subscribe your reactive contract to Perennial events:

   * `Updated()`
   * `OrderAdded()`
   * `OrderUpdated()`
2. On event trigger:

   * Fetch position data
   * Compute collateralization
   * Flag potential liquidations
3. Combine with periodic **view polling**:

   * Every 5-10 minutes, call `positions(account)` and `global()`
   * Compute collateralization ratios
   * Ensure no liquidatable position is missed
4. If profitable:

   * Execute flash loan liquidation logic

---

## 5. Profit Calculation Logic

For each position:

```
position_value = position_size * mark_price
collateralization_ratio = collateral / position_value
```

If `collateralization_ratio < maintenance_margin`:

```
required_repay = position_value - collateral
liquidation_bonus = required_repay * liquidation_bonus_percent
flash_loan_fee = required_repay * aave_fee
profit = liquidation_bonus - flash_loan_fee - gas_cost
```

Only execute liquidation if `profit > 0`.

---

## 6. Summary Workflow

1. **Event-driven**:

   * Reactive contract subscribes to Perennial V2 events
   * On update, fetch positions, compute collateralization
2. **Periodic checks**:

   * Poll view functions every 5-10 minutes for all active positions
   * Recompute collateralization
3. **Decision logic**:

   * Identify undercollateralized positions
   * Calculate potential profit
4. **Action**:

   * Execute Aave flash loan liquidation
   * Repay position
   * Collect bonus
   * Repay flash loan
   * Keep profit

---

## References

* [Perennial V2 Docs](https://docs.perennial.finance/)
* [Reactive Network Docs](https://dev.reactive.network/education/introduction)
* [Aave Flash Loan Docs](https://docs.aave.com/developers/guides/flash-loans)
