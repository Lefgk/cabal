# TSTT Token Creation Guide — Flux Factory

This guide walks you through creating **The Staking Test Token (TSTT)** using the Flux Factory token creator.

Go to: **FLUX > Token Factory > Create Token**

---

## Tax Structure Overview

TSTT uses a **5% total tax** on every buy, sell, and transfer, split across 5 purposes:

| # | Tax Type | % | What It Does | Where It Goes |
|---|----------|---|--------------|---------------|
| 0 | **Dev (Staking)** | 3.25% | Funds staking rewards | StakingVault → swapped to pHEX → dripped to stakers |
| 1 | **Dev (DAO)** | 1.00% | Funds the DAO treasury | TreasuryDAO → wrapped as WPLS → used for governance proposals |
| 2 | **Liquify** | 0.25% | Auto-builds TSTT liquidity | Half swapped to WPLS + paired with TSTT → LP burned permanently |
| 3 | **External Burn** | 0.25% | Buys & burns ZKP | Swapped to ZKP → sent to dead address (deflationary pressure on ZKP) |
| 4 | **Self Burn** | 0.25% | Burns TSTT supply | Sent to dead address (deflationary — reduces total TSTT supply over time) |

**Total: 5.00%** on every taxed transfer.

---

## Addresses You'll Need

Copy these before you start — you'll paste them during Step 2:

```
StakingVault:  0x995486558C59c5fb024eE7be3773CEd95eB5BE6c
TreasuryDAO:   0x8EE53E4687A9BA4a21771E34e085117A54A612AD
ZKP Token:     0x80e61Df31035e3d90f41e5524e53e08DB0aF186D
Dead Address:  0x000000000000000000000000000000000000dEaD
```

---

## Understanding the 6 Tax Types

Before we start, here's what each tax type in Flux Factory does:

**Dev** — Sends a percentage of every taxed transfer to a specific wallet or contract address. You choose the receiver. Can optionally receive as PLS instead of the token itself. You can add multiple Dev taxes with different receivers (e.g. one for staking, one for DAO).

**Burn** — Permanently destroys a percentage of the token on every transfer by sending it to the dead address (`0x...dEaD`). Reduces circulating supply over time. No configuration needed — just set the percentage.

**Reflection** — Distributes the tax proportionally to ALL token holders automatically. The more tokens you hold, the more you receive. No swaps involved — works natively with the token itself. NOT used for TSTT.

**Yield** — Similar to Reflection, but first swaps the tax to a different reward token (e.g. pHEX, WETH) before distributing to holders. Requires a reward token address. NOT used for TSTT because we want rewards to flow through the StakingVault, not directly to all holders.

**External Burn** — Buys a 3rd-party token using the tax, then sends it to a burn address. Creates constant buy pressure on the target token while permanently removing it from circulation. Requires: target token address + destination address.

**Liquify** — Takes the taxed tokens, swaps half to WPLS (or a custom pair token), pairs both halves together, adds them to PulseX as liquidity, and permanently burns the LP tokens. Creates ever-growing, irremovable liquidity for your token.

---

## Step 1: Basic Info

You'll see the **Basic Info** form with three fields.

Fill in:

- **Token Name:** `The Staking Test Token`
- **Ticker Symbol:** `TSTT`
- **Total Supply:** `38000000000` (38 billion)
- **Token Logo:** Upload your logo if you have one (optional, can be added later)

The bottom shows the mint fee: **2,000,000 PLS** (for tax tokens).

Click **Continue**.

---

## Step 2: Taxes

This is the most important step. You need to add 5 taxes across 4 tax types.

### 2a. Enable Taxes

Make sure **Enable Taxes** is checked (it should be by default since you're on the tax token path).

### 2b. Tax 0 — Dev (Staking Rewards) — 3.25%

1. Click the **Dev** tab in the tax strip
2. Set **Percentage** to `3.25`
3. In the **Treasury Address** field, paste the StakingVault address:
   ```
   0x995486558C59c5fb024eE7be3773CEd95eB5BE6c
   ```
4. Leave **"Receive in PLS"** unchecked — the StakingVault receives TSTT and handles its own swap to pHEX internally via its autoProcess mechanism

**Why Dev and not Yield?** Yield distributes rewards directly to all token holders. We don't want that — we want rewards to go only to people who actively stake in the vault. Dev tax sends to a specific contract (the vault), which then swaps to pHEX and drips rewards only to stakers.

### 2c. Tax 1 — Dev (DAO Treasury) — 1.00%

1. Click the **+** button (top-right of the Dev section) to add a second Dev tax instance
2. A new Dev section appears below the first one
3. Set **Percentage** to `1`
4. In the **Treasury Address** field, paste the TreasuryDAO address:
   ```
   0x8EE53E4687A9BA4a21771E34e085117A54A612AD
   ```
5. Check **"Receive in PLS"** — the DAO treasury accepts PLS and auto-wraps it to WPLS for governance proposals

You should now see two Dev sections: one at 3.25% (staking) and one at 1% (DAO). The summary bar should show **Buy 4.3% / Sell 4.3% / Transfer 4.3%** so far.

### 2d. Tax 2 — Liquify (Auto-LP) — 0.25%

1. Click the **Liquify** tab in the tax strip
2. Set **Percentage** to `0.25`
3. Leave **Custom Pair Token** blank — it defaults to pairing with WPLS

A yellow notice may appear: *"Liquidity required. Some selected tax functions need a PulseX pool to swap tokens."* This is expected — you'll add the TSTT-PLS pool after deployment.

**How it works:** On each transfer, 0.25% accumulates in the contract. When enough builds up, it auto-swaps half to WPLS, pairs it with the remaining TSTT half, adds both to PulseX as liquidity, and permanently burns the LP tokens. This creates a liquidity floor that can never be pulled.

### 2e. Tax 3 — External Burn (ZKP) — 0.25%

1. Click the **External Burn** tab in the tax strip
2. Set **Percentage** to `0.25`
3. In the **Token Address** field, paste the ZKP token:
   ```
   0x80e61Df31035e3d90f41e5524e53e08DB0aF186D
   ```
4. In the **Destination Address** field, paste the dead address:
   ```
   0x000000000000000000000000000000000000dEaD
   ```
   (or click the red **Burn Address** quick-fill button)

**How it works:** The contract accumulates TSTT from this 0.25% tax. When enough builds up, it swaps to ZKP via PulseX, then sends the ZKP to the dead address. This creates constant buy pressure on ZKP while permanently removing ZKP from circulation.

### 2f. Tax 4 — Self Burn — 0.25%

1. Click the **Burn** tab in the tax strip
2. Set **Percentage** to `0.25`
3. No other configuration needed

**How it works:** 0.25% of every transfer is sent directly to the dead address. Over time this reduces TSTT's total circulating supply, making each remaining token more scarce.

### 2g. Verify the Summary

The tax strip at the top should now show all active tabs: **Dev x** | **Burn x** | **External Burn x** | **Liquify x**

The summary bar should read:

```
Buy 5.0% / Sell 5.0% / Transfer 5.0%
```

If it doesn't add up to 5.0%, go back and check each percentage.

Click **Continue**.

---

## Step 3: Tokenomics

This step lets you burn tokens at deploy or set up vesting. For TSTT:

- **Burn on Deploy**: Leave at **0%** — we have ongoing burn via the 0.25% Burn + 0.25% External Burn taxes, no need to burn supply upfront
- **Vesting**: Leave at **0%** — no team token vesting
- **Deployer Receives**: Should show **100% (38,000,000,000)**

Click **Continue**.

---

## Step 4: Trading

This step configures when trading is enabled and optional settings.

- **Trading**: Choose one:
  - **Enable Now** — trading starts immediately at deployment (simplest)
  - **Auto Timer** — trading starts at a specific date/time (useful to announce launch time)
  - **Disabled (owner enables)** — you manually enable trading later by calling a function (use if you want to add liquidity first without anyone trading)

- **Renounce Ownership**: Decides if you give up owner control of the token contract after deployment
  - **Checked** = fully trustless, nobody can change taxes or settings ever again
  - **Unchecked** = you keep the ability to modify tax percentages, add exclusions, etc.
  - Recommendation: leave unchecked initially, renounce later once everything is confirmed working

- **Add Liquidity**: Optionally add initial TSTT-PLS liquidity during deployment
  - If you check this, set the % of supply for LP and how much PLS to pair with
  - You can also do this manually on PulseX after deployment

Click **Continue**.

---

## Step 5: Review & Deploy

The review screen shows a summary of everything:

```
Name:               The Staking Test Token
Symbol:             TSTT
Supply:             38,000,000,000
Taxes:              Buy 5.00% / Sell 5.00% / Transfer 5.00%
Deployer Receives:  100% (38,000,000,000)
Trading:            Enabled at deploy
```

Verify all values are correct.

Two deploy buttons appear:
- **Deploy Token (Pay 2,000,000 PLS)** — pay with PLS
- **Deploy Token (Pay in NEON, -10% off)** — pay with NEON at a discount

Click your preferred option. Your wallet (MetaMask) will prompt you to confirm the transaction.

Wait for the transaction to confirm on PulseChain (usually a few seconds).

---

## After Deployment

Once the token is deployed, you'll see a success screen with your new token contract address. Copy it.

### Required steps:

1. **Add TSTT-PLS liquidity on PulseX** — The External Burn, Liquify, and Dev (with PLS option) taxes all need a PulseX pool to swap through. Without it, those tax swaps silently fail and tokens accumulate in the contract until a pool exists.

2. **Add tax exclusions** — The StakingVault and TreasuryDAO contracts should be excluded from taxes so staking/unstaking and proposal execution aren't taxed. Call `addTaxExclusion(vaultAddress)` and `addTaxExclusion(daoAddress)` on the TSTT token contract.

3. **Fund initial staking rewards** — Send pHEX to the StakingVault and call `notifyRewardAmount(amount)` to start the 7-day reward drip. After that, the 3.25% Dev tax will auto-fund future reward periods.

4. **Verify on Otterscan** — Verify the token source on PulseChain so users can read the contract:
   ```
   https://otter.pulsechain.com/address/<YOUR_TSTT_ADDRESS>
   ```

### Optional steps:

5. **Set the token on the DAO** — If the TreasuryDAO's `token` state variable needs updating, call `setToken(tsttAddress)` as owner.

6. **Renounce token ownership** — Once everything is confirmed working (taxes flowing, staking rewards dripping, DAO proposals working), you can renounce ownership of the TSTT token contract to make it fully immutable and trustless.
