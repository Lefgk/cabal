# Cabal Protocol — Security Audit Report

**Scope:** `StakingVault.sol`, `TreasuryDAO.sol`, `LiquidityDeployer.sol`
**Chain:** PulseChain (chainId 369)
**Compiler:** Solidity ^0.8.24
**Date:** 2026-04-24
**Auditor:** Internal (AuditAI methodology)
**PoC Tests:** `test/AuditPoC.t.sol` — run with `forge test --match-path test/AuditPoC.t.sol -vvv`

---

## Summary

| ID | Title | Severity | Contract | Status |
|----|-------|----------|----------|--------|
| F-01 | Voting weight is live, not snapshotted | **HIGH** | TreasuryDAO | Open |
| F-02 | `castVote()` missing `nonReentrant` guard | **HIGH** | TreasuryDAO | Open |
| F-03 | `executed` flag dual semantics (clarification) | **HIGH** | TreasuryDAO | Confirmed Safe |
| F-04 | `LiquidityDeployer.addLiquidity()` permissionless | **HIGH** | LiquidityDeployer | Open |
| F-05 | Zero-slippage swaps across all DEX calls | **HIGH** | TreasuryDAO | Open |
| F-06 | Penalty tokens locked when DAO/dev address unset | **HIGH** | StakingVault | Open |
| F-07 | O(n²) top-staker insertion sort — gas DoS | **MEDIUM** | StakingVault | Open |
| F-08 | `totalOwed` CEI fragility — latent double-count | **MEDIUM** | StakingVault | Open |
| F-09 | `setDexRouter` with no timelock — centralization | **MEDIUM** | StakingVault | Open |
| F-10 | Custom proposal arbitrary call | **MEDIUM** | TreasuryDAO | Open |
| F-11 | Supermajority integer truncation at boundary | **LOW** | TreasuryDAO | Open |
| F-12 | `exit()` reverts for lock-only users | **LOW** | StakingVault | Open |
| F-13 | LiquidityDeployer V1 fallback uses stale V2 minOut | **LOW** | LiquidityDeployer | Open |
| F-14 | `setTopStakerCount` shrink evicts without grace | **LOW** | StakingVault | Open |
| F-15 | `setStakingVault` mid-vote bricks in-flight votes | **INFO** | TreasuryDAO | Open |

---

## Detailed Findings

---

### F-01 — HIGH: Voting Weight is Live (Not Snapshotted)

**Contract:** `TreasuryDAO.castVote()`
**Function:** `castVote(uint256 proposalId, bool support)`

**Description:**
Vote weight is read live from `stakingVault.effectiveBalance(voter)` at the moment `castVote()` is called, not at the time the proposal was created. This allows an attacker to:

1. Wait until a proposal exists.
2. Flash-borrow (or stake) a massive amount of tokens immediately before calling `castVote()`.
3. Cast a vote with inflated weight.
4. Withdraw after the vote (vote-lock prevents immediate exit, but the weight is already recorded).

**Impact:** A single whale or coordinated group can flip any proposal outcome, even against many existing legitimate voters. A flash-loan attack could acquire and vote in the same block if staking is uninhibited.

**PoC:** `test_F01_flashBoostVoteWeight` — sybil stakes 10,000 tokens after 5 honest stakers vote NO with 260 total weight. Sybil's YES votes flip the outcome to Succeeded (97.5% >> 65%).

**Recommendation:** Record a snapshot of `effectiveBalance` at proposal creation block (or use a 1-block delay like Compound Governor Bravo). Map `proposalId => snapshotBlock` and have `castVote` read the historical balance.

---

### F-02 — HIGH: `castVote()` Missing `nonReentrant` Guard

**Contract:** `TreasuryDAO`
**Function:** `castVote(uint256 proposalId, bool support)`

**Description:**
`castVote()` calls `stakingVault.lockForVote(voter, proposalId)` — an external call to a contract that may be swapped via `setStakingVault`. The function lacks a `nonReentrant` modifier. While the current implementation's CEI ordering (writing `receipt.hasVoted = true` before the external call) incidentally prevents double-voting, this is fragile:

- The reentrancy protection relies on source ordering, not an explicit guard.
- A future refactor that reorders the `receipt` assignment would silently introduce a reentrancy vulnerability.
- A malicious `stakingVault` replacement (see F-15) could re-enter `castVote` with a different proposal.

**PoC:** `test_F02_castVote_missingNonReentrant` — `MockReentrantVault.lockForVote()` calls back into `castVote()`. The re-entry is attempted (`reentrancyAttempted == true`) and only blocked by CEI ordering, not an explicit guard (`reentrancySucceeded == false`).

**Recommendation:** Add `nonReentrant` to `castVote()`.

```solidity
function castVote(uint256 proposalId, bool support) external nonReentrant { ... }
```

---

### F-03 — HIGH: `executed` Flag Dual Semantics (Double-Unlock Check)

**Contract:** `TreasuryDAO`
**Functions:** `unlockDefeated()`, `_cleanupStaleProposals()`

**Description:**
The `p.executed` flag is reused for two semantics: "proposal was executed" (for `Succeeded → Executed` transitions) and "lockedAmount was already decremented" (for defeated/expired cleanup). A `Defeated` proposal auto-processed by `_cleanupStaleProposals()` has `p.executed = true` set internally. If `unlockDefeated()` is then called, it correctly reverts with `AlreadyUnlocked`.

**PoC:** `test_F03_noDoubleUnlock_afterAutoCleanup` — confirms no double-decrement of `lockedAmount`. Both paths produce the correct outcome.

**Status:** Confirmed safe under current code. The semantic overloading is a maintenance hazard but no exploitable double-unlock exists. Recommend introducing a separate `uint8 cleanupState` or `bool fundsReleased` field to separate the two semantics for long-term clarity.

---

### F-04 — HIGH: `LiquidityDeployer.addLiquidity()` is Permissionless

**Contract:** `LiquidityDeployer`
**Function:** `addLiquidity(address tokenA, address tokenB) payable`

**Description:**
`addLiquidity()` has no `onlyOwner`, `onlyDAO`, or whitelist check. Any externally-owned account can call it with arbitrary token addresses and send PLS. Attack vectors:

1. **Honeypot drain:** Attacker calls `addLiquidity(honeypotToken, address(0))` — PLS is swapped into a token that can't be sold, permanently losing treasury value.
2. **Sandwich attack:** Attacker frontruns the DAO's intended `addLiquidity` call by seeding the pool, then backruns to extract the price impact.
3. **Griefing:** Any user can trigger LP operations on the DAO's behalf with malicious parameters.

**PoC:** `test_F04_anyoneCanCallAddLiquidity` and `test_F04_daoNotRequiredAsCaller` — both calls from `attacker` address succeed without revert.

**Recommendation:**
```solidity
error Unauthorized();
address public daoAddress;
modifier onlyDAO() {
    if (msg.sender != daoAddress) revert Unauthorized();
    _;
}
function addLiquidity(address tokenA, address tokenB) external payable onlyDAO { ... }
```

---

### F-05 — HIGH: Zero-Slippage Swaps Across All DEX Calls

**Contracts:** `TreasuryDAO._executeBuyAndBurn()`, `TreasuryDAO._executeAddAndBurnLP()`, `LiquidityDeployer.addLiquidity()`
**Functions:** All calls to `swapExactETHForTokensSupportingFeeOnTransferTokens`

**Description:**
All swap calls pass `amountOutMin = 0`, making every treasury spend trivially sandwichable. A mempool-watching bot can:

1. Detect the `executeProposal` transaction.
2. Frontrun by buying the target token (pumping the price).
3. Let the DAO swap at the inflated price, receiving nearly zero tokens.
4. Backrun by selling — pocketing the price difference.

On PulseChain, where mempool visibility and fast finality are common, this is a practical threat on every single treasury execution.

**PoC:** `test_F05_zeroSlippage_swapReturnsNearZero` — `MockDrainRouter` returns 1 wei regardless of PLS input. The DAO spends 100 ETH and receives ≤ 1 wei of burn token. No revert.

**Recommendation:** Use an on-chain oracle (TWAP or `getAmountsOut`) to calculate a minimum acceptable output with a configurable slippage tolerance (e.g., 2–5%), and pass it as `amountOutMin`:

```solidity
uint256 minOut = router.getAmountsOut(amount, path)[1] * (10000 - maxSlippageBps) / 10000;
```

The `LiquidityDeployer` already has partial slippage infrastructure (`_getMinOut`) — apply it consistently everywhere.

---

### F-06 — HIGH: Penalty Tokens Locked When DAO/Dev Address Unset

**Contract:** `StakingVault._distributePenalty()`

**Description:**
When a user early-unlocks a locked position, a 30% penalty is split:
- 59% burned to `DEAD`
- 30% queued as `pendingPenaltyTokens` (for stakers)
- 10% sent to `daoAddress` as WPLS (via swap)
- 1% sent to `devWallet` as WPLS (via swap)

If `daoAddress` or `devWallet` is `address(0)` (not yet configured by the owner), the `_swapAndSend()` call silently skips the transfer. The tokens are neither burned, queued for stakers, nor added to `pendingPenaltyTokens`. They remain stranded in the vault's ERC-20 balance with no recovery function.

**PoC:** `test_F06_daoShareLostWhenDaoAddressZero` — 33 tokens (toDao=30 + toDev=3) are confirmed stuck in vault balance, above what `pendingPenaltyTokens` accounts for.

**Recommendation:**
1. Require both addresses to be set before any penalty can occur (revert with a clear error if unset).
2. Or redirect unrouted shares to `pendingPenaltyTokens` as a fallback.

```solidity
if (daoAddress == address(0)) revert DaoAddressNotSet();
if (devWallet == address(0)) revert DevWalletNotSet();
```

---

### F-07 — MEDIUM: O(n²) Top-Staker Insertion Sort — Gas DoS

**Contract:** `StakingVault._updateTopStakers()`

**Description:**
Every `stake()`, `withdraw()`, and `unlock()` call triggers `_updateTopStakers()`, which performs a linear scan and shift on the sorted `_topStakers` array. With `topStakerCount = 100` (the maximum), inserting a new staker at position 0 (worst case) shifts all 100 elements. For 100 stakers with concurrent activity, this burns excessive gas and can approach the block gas limit.

**PoC:** `test_F07_stakeGasCostGrowsWithTopStakerCount` — logs gas used when staking as the 99th staker with a large balance (forced front insertion). Gas cost is measurably higher than a simple stake.

**Recommendation:** Use a heap or a sorted linked list (e.g., an `EnumerableSet` with lazy eviction) to achieve O(log n) insertion. Alternatively, cap `topStakerCount` at a lower bound (e.g., 20) or compute the top-staker list off-chain and commit it on-chain via a Merkle root.

---

### F-08 — MEDIUM: `totalOwed` CEI Fragility — Latent Double-Count

**Contract:** `StakingVault`
**Functions:** `_processRewardsIfNew()` modifier and `updateReward()` modifier

**Description:**
Both `_processRewardsIfNew()` and the `updateReward` modifier independently increment `totalOwed` when `rewardPerToken()` advances. On functions that carry both (e.g., `stake()` with `autoProcess`), the same RPT delta can be applied twice in a single transaction. The current CEI ordering incidentally prevents double-counting (the first modifier snaps `rewardPerTokenStored`, so the second finds no new delta). However:

- This protection is invisible from the function signature.
- A future refactor that extracts either modifier or changes ordering could silently introduce insolvency.

**PoC:** `test_F08_totalOwed_doubleCountedInSameTx` — documents the fragility. Under current code `totalOwed` is not double-counted, but the test confirms the protection relies on ordering, not design.

**Recommendation:** Merge the two reward-tracking paths into a single authoritative function; remove the duplication. Mark the dependency explicitly in code comments if merging is deferred.

---

### F-09 — MEDIUM: `setDexRouter` No Timelock — Centralization Risk

**Contract:** `StakingVault.setDexRouter(address)`

**Description:**
The owner can replace `dexRouter` at any time without a timelock. Because `_swapAndSend()` calls `STAKING_TOKEN.approve(dexRouter, amount)` followed immediately by a router call, a malicious router can:

1. Receive the token approval.
2. Call `transferFrom(vault, attacker, amount)` inside the swap callback.
3. Drain the vault of the penalty tokens being swapped.

This is a **centralization risk**: users must trust the deployer never to set a malicious router.

**PoC:** `test_F09_ownerCanPointRouterAtMaliciousContract` — `MaliciousRouter` confirms it receives the token approval (`approvalReceived == true`, `approvalAmount > 0`) after being set as the DEX router.

**Recommendation:**
1. Implement a 2-step timelock on `setDexRouter` (e.g., propose → 48h delay → confirm).
2. Or use a router registry that is immutable and only accepts pre-approved PulseX addresses.
3. Alternatively, use `safeIncreaseAllowance` with exact amounts and revoke after the call.

---

### F-10 — MEDIUM: Custom Proposal Executes Arbitrary Calls

**Contract:** `TreasuryDAO._executeCustom()`

**Description:**
`ActionType.Custom` proposals allow any `target` address and `data` payload. The DAO calls `target.call{value: amount}(data)` with no restrictions. A passed Custom proposal could:

- Transfer PLS to any address.
- Call `setTopStakerCount` or `setPaused` on the StakingVault (only limited by the vault's `onlyOwner` check — DAO is not vault owner currently, so this specific vector is safe).
- Call `LiquidityDeployer.addLiquidity()` with malicious parameters (if DAO is authorized).
- Selfdestruct a helper contract or poison downstream state.

**PoC:** `test_F10_customProposal_callsArbitraryTarget` — `ArbitraryTarget.doSomething(42)` is called with 5 ETH via a passed Custom proposal. Both ETH and calldata are delivered successfully.

**Recommendation:**
- Maintain a whitelist of allowed `target` addresses for Custom proposals.
- Or require Custom proposals to also pass a timelock/guardian review before execution.
- At minimum, document clearly in the UI that Custom proposals carry full arbitrary execution power.

---

### F-11 — LOW: Supermajority Integer Truncation at Boundary

**Contract:** `TreasuryDAO.state()` / `votingPercent()`

**Description:**
`votingPercent()` computes `yesVotes * 100 / (yesVotes + noVotes)`. Integer division truncates: 649 YES / 1000 total = `64900 / 1000 = 64` (not 65). A proposal at true 64.9% fails even though it is visually close to the threshold. This is mathematically correct behavior but can surprise proposers in edge cases.

**PoC:** `test_F11_superMajorityRoundingAt6499Pct` — confirms 649/1000 = 64 (truncated), state = Defeated.

**Recommendation:** Use basis-point precision: `yesVotes * 10000 / total >= 6500`. This removes the truncation error at the boundary.

```solidity
uint256 pct = (yesVotes * 10000) / (yesVotes + noVotes);
return pct >= supermajorityPct * 100;
```

---

### F-12 — LOW: `exit()` Reverts for Lock-Only Users

**Contract:** `StakingVault.exit()`

**Description:**
`exit()` is documented as "withdraw all + claim rewards". Internally it calls `withdraw(_flexBalance[msg.sender])`. If a user has only locked positions and no flex balance, `_flexBalance == 0` and `withdraw(0)` reverts with `ZeroWithdraw`. The user must know to call `unlock()` directly instead.

**PoC:** `test_F12_exitRevertsIfUserHasOnlyLockedPositions` — confirms `exit()` reverts with `ZeroWithdraw` for a lock-only user after the lock period expires.

**Recommendation:** In `exit()`, only call `withdraw()` if `_flexBalance[msg.sender] > 0`, and separately claim rewards:

```solidity
function exit() external nonReentrant {
    if (_flexBalance[msg.sender] > 0) _withdraw(_flexBalance[msg.sender]);
    _getReward();
}
```

---

### F-13 — LOW: LiquidityDeployer V1 Fallback Uses Stale V2 MinOut

**Contract:** `LiquidityDeployer`

**Description:**
When V2 swap fails, the deployer falls back to V1. The `minOut` passed to V1 is calculated from a V2 `getAmountsOut` call. If V1 has a materially different pool price, the stale V2 quote creates either:
- **False revert:** V1 output < V2-based minOut → fallback always fails unnecessarily.
- **False acceptance:** V1 output > V2-based minOut but the V1 price is worse than intended → slippage protection is bypassed.

**PoC:** `test_F13_v1FallbackUsesStaleV2Quote` — documents the path where V2 fails and V1 is called with a V2-derived quote.

**Recommendation:** When falling back to V1, re-query `getAmountsOut` from the V1 router to get a V1-specific quote before calculating minOut.

---

### F-14 — LOW: `setTopStakerCount` Shrink Evicts Without Grace Period

**Contract:** `StakingVault.setTopStakerCount(uint256)`

**Description:**
When the owner reduces `topStakerCount`, the weakest stakers are immediately popped from the array and marked `_isTopStaker[addr] = false`. Any active proposals created by those stakers remain valid (they are not invalidated), but those wallets immediately lose the ability to create new proposals. No grace period or notification exists.

**PoC:** `test_F14_shrinkingTopStakerEvictsWeakest` — Frank (30e18, weakest staker) is in top 10. Owner shrinks to 5. Frank is immediately evicted and receives `NotTopStaker` on his next `propose()` attempt, while his in-flight proposal remains active.

**Recommendation:** Emit an event on eviction and consider a grace period (e.g., 24h) before the eviction takes effect, allowing evicted proposers to react.

---

### F-15 — INFO: `setStakingVault` Mid-Vote Bricks In-Flight Casters

**Contract:** `TreasuryDAO.setStakingVault(address)`

**Description:**
The owner can replace `stakingVault` at any time. If swapped during an active voting period, users whose tokens are staked in the old vault have `effectiveBalance == 0` on the new vault, and their `castVote()` calls revert with `NoVotingPower`. The proposal cannot reach `minVoters` if enough voters are blocked this way.

**PoC:** `test_F15_stakingVaultSwapMidVote_breaksCasting` — Bob tries to vote after vault is replaced. `castVote()` reverts with `NoVotingPower`.

**Recommendation:** This is an owner-privilege finding rather than a direct exploit. Mitigations:
1. Only allow `setStakingVault` when there are no active proposals.
2. Implement a timelock on `setStakingVault`.

---

## Notes

### pHEX (Reward Token) — No Transfer Tax
The PulseChain HEX contract (`0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39`) is a standard ERC-20 with 8 decimals and **no transfer tax or fee-on-transfer logic**. Users receiving pHEX rewards from the StakingVault pay no tax. (OMEGA is the tax token; pHEX is a clean ERC-20.)

### Token Decimals
- OMEGA (staking): 18 decimals
- pHEX (reward): **8 decimals** — all reward calculations must account for 1e8 scale, not 1e18.

---

## Severity Legend

| Severity | Meaning |
|----------|---------|
| HIGH | Direct loss of funds or critical logic bypass |
| MEDIUM | Significant impact under realistic conditions |
| LOW | Minor UX/logic issue, no immediate fund risk |
| INFO | Centralization risk or informational only |
