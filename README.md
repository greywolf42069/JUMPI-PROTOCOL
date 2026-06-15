# JUMPI Protocol v2.0

**Hardened Offset-Based Transfer Router with 0.5% Fee Reaping**

GreyWolf + THEWIRED • 2+2=22 • Flesh is LEGACY

Pure Huff • Callable by anyone • Deployer reaps 0.5% of every transfer

---

## What Is This?

JUMPI Protocol is a minimalist transfer router written in pure Huff assembly. Anyone can call it to route ERC20 tokens or ETH — the contract automatically skims a 0.5% fee to the deployer on every transfer.

**v2.0** adds six hardened safety features: reentrancy guard, pause, token whitelist, fee cap, delegatecall protection, and emergency withdraw.

**v2.1** fixes two bugs found during adversarial audit: nonpayable enforcement and zero-fee transferFrom skip.

**Runtime bytecode:** 1,240 bytes | **Compiler:** huffc 0.3.2 | **EVM Target:** Cancun

---

## How It Works

### Token Routing (`routeToken`)
1. Caller approves JUMPI Protocol for `amount` on any ERC20 token
2. Calls `routeToken(token, recipient, amount)`
3. Contract checks: reentrancy lock, pause, whitelist (if enabled)
4. Computes fee = `amount * 50 / 10000` (0.5%), capped by maxFee if set
5. Executes `transferFrom(caller, recipient, net)` — recipient gets 99.5%
6. Executes `transferFrom(caller, feeRecipient, fee)` — deployer gets 0.5%

### ETH Routing (`routeETH`)
1. Caller sends ETH with `routeETH{value: amount}(recipient)`
2. Contract checks: reentrancy lock, pause
3. Computes fee = `msg.value * 50 / 10000`, capped by maxFee if set
4. Sends `net` ETH to recipient via CALL
5. Fee stays in contract balance (swept later by deployer)

### Fee Sweeping (Emergency Withdraw)
- `sweepETH()` — deployer withdraws all accumulated ETH fees (ETH fees stay in contract balance after routing)
- `sweepToken(token)` — deployer withdraws any ERC20 token balance held by the contract (note: routed ERC20 fees go directly to deployer via `transferFrom` — the protocol never holds them. This function recovers tokens sent to the contract accidentally or via direct transfer)
- Both restricted to deployer only
- **Both work even when paused** — emergency withdraw capability

---

## Safety Features (v2.0)

### 1. Reentrancy Guard
Storage-based mutex lock. Set on entry to `routeToken`/`routeETH`, cleared before return. Revert rolls back the lock automatically.

### 2. Pause
Deployer can pause all routing. `setPaused(true)` stops `routeToken` and `routeETH`. Sweep functions bypass pause (emergency withdraw). View functions work normally when paused.

### 3. Token Whitelist
Deployer can enable a whitelist. When enabled, only whitelisted tokens can be routed. ETH routing is unaffected. Prevents malicious token contracts from being routed through the protocol.

### 4. Fee Cap (maxFee)
Deployer can set a maximum fee per transaction in wei. If computed fee exceeds maxFee, the fee is capped. `maxFee = 0` means no cap (default).

### 5. Delegatecall Protection
Contract stores its own address in constructor. On every call, checks `address == storedSelf`. Delegatecall changes `address` to the caller's context — mismatch → revert.

### 6. Emergency Withdraw
Sweep functions have no pause check. Even if the contract is paused, the deployer can always withdraw accumulated fees. No funds can be permanently locked.

---

## Storage Layout

| Slot | Contents |
|------|----------|
| `0x00` | `feeRecipient` (deployer, immutable) |
| `0x01` | `paused` (0 = active, 1 = paused) |
| `0x02` | `lock` (reentrancy, 0 = unlocked, 1 = locked) |
| `0x03` | `maxFeeWei` (0 = no cap) |
| `0x04` | `whitelistEnabled` (0 = all tokens, 1 = whitelist only) |
| `0x05` | `self` (contract address, for delegatecall guard) |
| `0x06` | `tokenWhitelist[token]` mapping root |

---

## Fee Constants

| Constant | Hex | Decimal | Meaning |
|----------|-----|---------|---------|
| `FEE_BPS` | `0x32` | 50 | 50 basis points = 0.5% |
| `BPS_DENOMINATOR` | `0x2710` | 10000 | Standard basis point denominator |
| Min fee-bearing amount | — | 200 wei | Below this, fee rounds to 0 (integer division) |

**Formula:** `fee = min(amount * 50 / 10000, maxFee)` (when maxFee > 0)

---

## Function Interface

### Public (User-Facing)

| Function | Mutability | Description |
|----------|------------|-------------|
| `routeToken(address,address,uint256)` | nonpayable | Route ERC20 with 0.5% fee |
| `routeETH(address)` | payable | Route ETH with 0.5% fee |

### Admin (Deployer Only)

| Function | Mutability | Description |
|----------|------------|-------------|
| `sweepETH()` | nonpayable | Withdraw ETH fees (bypasses pause) |
| `sweepToken(address)` | nonpayable | Withdraw token fees (bypasses pause) |
| `setPaused(bool)` | nonpayable | Pause/unpause routing |
| `setWhitelistEnabled(bool)` | nonpayable | Enable/disable token whitelist |
| `whitelistToken(address,bool)` | nonpayable | Add/remove token from whitelist |
| `setMaxFee(uint256)` | nonpayable | Set max fee per tx (0 = no cap) |

### View

| Function | Returns | Description |
|----------|---------|-------------|
| `getFeeRecipient()` | address | Deployer address |
| `getFeeBps()` | uint256 | Fee basis points (50) |
| `isPaused()` | bool | Pause status |
| `isWhitelisted(address)` | bool | Token whitelist status |
| `getMaxFee()` | uint256 | Max fee cap (0 = no cap) |
| `isWhitelistEnabled()` | bool | Whitelist enabled status |

## Events

| Event | Indexed | Data |
|-------|---------|------|
| `TokenRouted(token, from, to, net, fee)` | token, from, to | net, fee |
| `ETHRouted(from, to, net, fee)` | from, to | net, fee |
| `Swept(token, amount)` | token | amount |
| `ETHSwept(amount)` | — | amount |
| `SetPaused(status)` | — | status |
| `SetWhitelistEnabled(status)` | — | status |
| `TokenWhitelistUpdated(token, status)` | token | status |
| `MaxFeeUpdated(maxFee)` | — | maxFee |

---

## Engineer's Anvil Audit

**121 tests. 0 failures. 256 fuzz runs.**

```
Ran 121 tests for test/JumpiProtocol.t.sol:JumpiProtocolTest
[PASS] — all 121
```

### Test Coverage by Category

#### Smoke Tests (8)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_smoke_deployment` | Contract deploys successfully |
| 2 | `test_smoke_hasCode` | extcodesize > 0 |
| 3 | `test_smoke_feeRecipient` | getFeeRecipient() returns deployer |
| 4 | `test_smoke_feeBps` | getFeeBps() returns 50 |
| 5 | `test_smoke_emptyCalldata_reverts` | Empty calldata reverts |
| 6 | `test_smoke_shortCalldata_reverts` | < 4 bytes reverts |
| 7 | `test_smoke_unknownSelector_reverts` | Unknown selector reverts |
| 8 | `test_smoke_directETH_reverts` | Raw ETH transfer reverts |

#### routeToken Unit Tests (12)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_routeToken_basic` | Happy path returns true |
| 2 | `test_routeToken_correctFee` | Fee = amount * 50 / 10000 |
| 3 | `test_routeToken_correctNet` | Net = amount - fee |
| 4 | `test_routeToken_callerDeducted` | Caller loses exact amount |
| 5 | `test_routeToken_zeroToken_reverts` | token = address(0) reverts |
| 6 | `test_routeToken_zeroTo_reverts` | to = address(0) reverts |
| 7 | `test_routeToken_zeroAmount_reverts` | amount = 0 reverts |
| 8 | `test_routeToken_noApproval_reverts` | No approval → revert |
| 9 | `test_routeToken_insufficientBalance_reverts` | Insufficient balance → revert |
| 10 | `test_routeToken_exactFee_10000` | 10000 → fee=50, net=9950 |
| 11 | `test_routeToken_smallAmount_zeroFee` | < 200 → fee = 0 |
| 12 | `test_routeToken_multipleRoutes` | Sequential routes accumulate fees |

#### routeETH Unit Tests (10)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_routeETH_basic` | Happy path returns true |
| 2 | `test_routeETH_correctFee` | Fee retained in contract |
| 3 | `test_routeETH_correctNet` | Net sent to recipient |
| 4 | `test_routeETH_callerDeducted` | Caller balance decreased |
| 5 | `test_routeETH_zeroTo_reverts` | to = address(0) reverts |
| 6 | `test_routeETH_zeroValue_reverts` | msg.value = 0 reverts |
| 7 | `test_routeETH_exactFee_10000wei` | 10000 wei → fee = 50 |
| 8 | `test_routeETH_smallAmount_zeroFee` | < 200 wei → fee = 0 |
| 9 | `test_routeETH_multipleRoutes_feeAccumulates` | Fees accumulate |
| 10 | `test_routeETH_largeAmount` | 100 ETH routes correctly |

#### Sweep Tests (8)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_sweepETH_basic` | Deployer receives full balance |
| 2 | `test_sweepETH_nonDeployer_reverts` | Non-deployer can't sweep |
| 3 | `test_sweepETH_nothingToSweep_reverts` | Zero balance → revert |
| 4 | `test_sweepETH_afterMultipleRoutes` | Accumulated fees swept |
| 5 | `test_sweepToken_basic` | Token balance transferred |
| 6 | `test_sweepToken_nonDeployer_reverts` | Non-deployer can't sweep |
| 7 | `test_sweepToken_nothingToSweep_reverts` | Zero balance → revert |
| 8 | `test_sweepToken_zeroAddress_reverts` | token = 0 reverts |

#### Event Tests (6)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_event_tokenRouted` | TokenRouted emission |
| 2 | `test_event_ethRouted` | ETHRouted emission |
| 3 | `test_event_swept` | Swept emission |
| 4 | `test_event_ethSwept` | ETHSwept emission |
| 5 | `test_event_tokenRouted_multipleEmissions` | Multiple events |
| 6 | `test_event_ethRouted_multipleEmissions` | Multiple events |

#### Fee Math Tests (6)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_feeMath_exact05percent` | 1M → fee = 5000 |
| 2 | `test_feeMath_roundDown` | Integer division truncation |
| 3 | `test_feeMath_zeroFeeForTinyAmount` | < 200 → fee = 0 |
| 4 | `test_feeMath_netPlusFeeEqualsAmount` | Conservation |
| 5 | `test_feeMath_oneWei` | 1 wei → fee = 0 |
| 6 | `test_feeMath_largeAmount` | 1 ETH → fee = 0.005 ETH |

#### Fuzz Tests (6 × 256 runs)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_fuzz_routeToken(uint256)` | Random amounts: balances correct |
| 2 | `test_fuzz_routeETH(uint256)` | Random ETH values: balances correct |
| 3 | `test_fuzz_feePlusNetEqualsAmount(uint256)` | net + fee = amount always |
| 4 | `test_fuzz_feeNeverExceedsHalfPercent(uint256)` | fee ≤ 0.5% always |
| 5 | `test_fuzz_multipleRoutes(uint8)` | 1-10 random routes |
| 6 | `test_fuzz_routeETH_differentAmounts(uint128,uint128)` | Two random amounts |

#### Chaos Tests (8)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_chaos_routeTokenToSelf` | Self-route loses only fee |
| 2 | `test_chaos_routeTokenToFeeRecipient` | Deployer gets full amount |
| 3 | `test_chaos_routeETHToSelf` | Self-route ETH |
| 4 | `test_chaos_routeETHToFeeRecipient` | Deployer gets net |
| 5 | `test_chaos_multipleTokens` | Two tokens, correct fees |
| 6 | `test_chaos_mixedTokenAndETH` | Interleaved routing |
| 7 | `test_chaos_maxApproval` | Max uint approval works |
| 8 | `test_chaos_routeToContract` | ETHReceiver contract |

#### Monkey Tests (6)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_monkey_fullTokenLifecycle` | Route → verify all balances |
| 2 | `test_monkey_fullETHLifecycle` | Route → sweep → verify |
| 3 | `test_monkey_multiUserRouting` | Multiple callers |
| 4 | `test_monkey_repeatedSweeps` | Route → sweep × 2 |
| 5 | `test_monkey_tokenAndETHCombined` | Mixed lifecycle |
| 6 | `test_monkey_stressRouting` | 20 sequential routes |

#### Invariant Tests (4)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_invariant_feePlusNetEqualsAmount` | Conservation: no dust |
| 2 | `test_invariant_ethFeePlusNetEqualsValue` | ETH conservation |
| 3 | `test_invariant_feeRecipientNeverChanges` | Slot 0 immutable |
| 4 | `test_invariant_protocolNeverHoldsTokensFromRouting` | No stuck tokens |

#### Pause Tests (8)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_pause_setPaused` | Deployer can pause |
| 2 | `test_pause_setUnpaused` | Deployer can unpause |
| 3 | `test_pause_revert_notDeployer` | Non-deployer can't pause |
| 4 | `test_pause_routeToken_reverts` | Token routing blocked when paused |
| 5 | `test_pause_routeETH_reverts` | ETH routing blocked when paused |
| 6 | `test_pause_sweepETH_worksWhenPaused` | Emergency ETH withdraw |
| 7 | `test_pause_sweepToken_worksWhenPaused` | Emergency token withdraw |
| 8 | `test_pause_event` | SetPaused event emitted |

#### Whitelist Tests (10)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_whitelist_enableWhitelist` | Enable whitelist |
| 2 | `test_whitelist_disableWhitelist` | Disable whitelist |
| 3 | `test_whitelist_addToken` | Add token to whitelist |
| 4 | `test_whitelist_removeToken` | Remove from whitelist |
| 5 | `test_whitelist_routeToken_whitelisted` | Whitelisted token routes |
| 6 | `test_whitelist_routeToken_notWhitelisted_reverts` | Non-whitelisted reverts |
| 7 | `test_whitelist_routeETH_unaffected` | ETH unaffected by whitelist |
| 8 | `test_whitelist_revert_notDeployer` | Access control |
| 9 | `test_whitelist_revert_zeroAddress` | Zero address rejected |
| 10 | `test_whitelist_event` | TokenWhitelistUpdated emitted |

#### Max Fee Tests (7)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_maxFee_setMaxFee` | Set and read back |
| 2 | `test_maxFee_revert_notDeployer` | Access control |
| 3 | `test_maxFee_capToken` | Token fee capped at maxFee |
| 4 | `test_maxFee_capETH` | ETH fee capped at maxFee |
| 5 | `test_maxFee_noCap` | maxFee=0 means no cap |
| 6 | `test_maxFee_belowCap` | Fee below cap unchanged |
| 7 | `test_maxFee_event` | MaxFeeUpdated emitted |

#### Reentrancy Tests (2)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_reentrancy_routeETH_reverts` | Reentrant call blocked |
| 2 | `test_reentrancy_lockReleasedAfterSuccess` | Lock freed after return |

#### Delegatecall Tests (2)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_delegatecall_reverts` | Delegatecall detected and reverted |
| 2 | `test_delegatecall_normalCallWorks` | Normal calls unaffected |

#### Admin Tests (4)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_admin_setWhitelistEnabled_onlyDeployer` | Access control |
| 2 | `test_admin_allViewsDefaultCorrectly` | Defaults: unpaused, no whitelist, no cap |
| 3 | `test_admin_deployerCanDoEverything` | Full admin lifecycle |
| 4 | `test_admin_pauseDoesNotAffectViews` | Views work when paused |

#### Fix 1: Nonpayable Enforcement (5)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_fix1_routeToken_withETH_reverts` | routeToken with ETH reverts |
| 2 | `test_fix1_routeToken_withETH_ethReturnedOnRevert` | Revert returns ETH to caller |
| 3 | `test_fix1_sweepETH_withETH_reverts` | sweepETH with ETH reverts |
| 4 | `test_fix1_setPaused_withETH_reverts` | setPaused with ETH reverts |
| 5 | `test_fix1_viewFunction_withETH_reverts` | View functions with ETH revert |

#### Fix 2: Zero-Fee Skip (2)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_fix2_zeroFee_zeroRevertToken_succeeds` | Zero-revert token routes correctly when fee=0 |
| 2 | `test_fix2_zeroFee_noDeployerBalance` | Fee transfer skipped when fee=0 |

#### ETH Rejection Coverage (1)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_routeETH_rejecting_recipient_reverts` | Recipient rejection reverts tx; no ETH stuck |

#### Hardened Integration Tests (6)

| # | Test | Verifies |
|---|------|----------|
| 1 | `test_hardened_pauseUnpauseRoute` | Pause → fail → unpause → succeed |
| 2 | `test_hardened_whitelistLifecycle` | Add → route → remove → fail |
| 3 | `test_hardened_maxFeeAndWhitelist` | Both active simultaneously |
| 4 | `test_hardened_pauseSweepUnpauseRoute` | Emergency sweep while paused |
| 5 | `test_hardened_fullSecurityStack` | All features active together |
| 6 | `test_hardened_nonWhitelistedToken2_reverts` | Per-token granularity |

---

## Bugs Found & Fixed

### Bug 1: routeETH Sends ETH to Wrong Address (CRITICAL) — v1.0

**Problem:** `dup7` grabbed `fee` instead of `to` because `dup5` shifted all stack positions by 1.

**Fix:** Changed `dup7` to `dup8`.

**Verified by:** All 10 routeETH tests.

### Bug 2: Integration Test Tries to Sweep Zero-Balance Tokens (MEDIUM) — v2.0

**Problem:** `test_hardened_fullSecurityStack` tried to `sweepToken` after token routing. But token fees go directly to deployer via `transferFrom` — the protocol never holds routed tokens. `sweepToken` reverted on zero balance.

**Fix:** Removed invalid sweep calls, added assertion that protocol holds zero tokens.

### Bug 3: Nonpayable Functions Accept ETH (MEDIUM) — v2.1

**Problem:** Huff's `nonpayable` keyword in `#define function` is documentation only — the compiler does not inject a callvalue check. All functions except `routeETH` silently accepted ETH, which accumulated in the contract balance until the deployer swept it. A user calling `routeToken{value: X}()` (e.g., via a frontend bug) would lose that ETH permanently.

**Fix:** Added `callvalue fail jumpi` at the entry point of every non-payable function (13 guards total). `callvalue fail jumpi` reverts if any ETH is attached; `routeETH` retains its original `callvalue iszero fail jumpi` check that requires ETH to be present.

**Verified by:** 5 new tests (`test_fix1_*`).

### Bug 4: Zero-Fee `transferFrom` Breaks Tokens That Reject Zero Amounts (LOW) — v2.1

**Problem:** When routing amounts below 200 units (where `amount * 50 / 10000` truncates to 0), the protocol still executed a second `transferFrom(caller, feeRecipient, 0)`. Tokens that enforce `require(amount > 0)` on transfers — including BNT, LEND, and several governance tokens — would always revert for these small amounts, making them unroutable even when whitelisted.

**Fix:** Added `dup2 iszero rt_skip_fee jumpi` before Call 2. When `effective_fee == 0`, the fee transfer is skipped entirely and execution jumps directly to event emission.

**Verified by:** 2 new tests (`test_fix2_*`), including a `ZeroRevertToken` mock that enforces `require(amount > 0)`.

---

## Security Notes

- **Reentrancy guard** — storage-based mutex on `routeToken` and `routeETH`. Revert automatically releases the lock.
- **Delegatecall protection** — `address` vs stored self check at top of dispatcher. Cannot be used as implementation behind a proxy.
- **Pause** — deployer-only kill switch. Sweep functions bypass pause for emergency fund recovery.
- **Token whitelist** — optional allowlist prevents malicious tokens. ETH routing is never affected.
- **Fee cap** — deployer can set per-tx maximum fee. Protects users from excessive fees on large amounts.
- **Nonpayable enforcement** — every function except `routeETH` has an explicit `callvalue fail jumpi` guard. ETH sent to any nonpayable function reverts immediately; no funds can be silently captured.
- **Zero-fee skip** — when `effective_fee == 0` (amounts < 200 wei), the second `transferFrom` to the fee recipient is skipped. Tokens that revert on zero-amount transfers remain fully routable for small amounts.
- **Integer division truncation** — amounts < 200 wei produce 0 fee. By design.
- **Deployer is permanent** — no admin transfer. Slot 0 is immutable after constructor.
- **No receive/fallback** — contract cannot accept raw ETH transfers.

### ETH Fee Retention (Verified)

When `routeETH` executes, the fee is the implicit remainder: `msg.value - net` stays in the contract after the CALL sends `net` to the recipient. If the recipient CALL fails, the entire transaction reverts — the caller gets all ETH back, no fee is lost or stuck. The `gas call` pattern forwards all remaining gas (minus EIP-150 1/64th retention), giving recipient contracts sufficient gas to execute `receive()` or `fallback()`. If the recipient consumes excessive gas but succeeds, and remaining gas is insufficient for the event emission, the entire tx reverts cleanly. **No edge case exists where ETH fees are lost.**

### Non-Standard ERC20 Tokens (Known Limitation)

The `routeToken` path checks CALL success (`iszero fail jumpi`) but does **not** inspect the return data bool. This means:

- **Standard ERC20s** (revert on failure): Fully safe. CALL returns 0 on revert, caught by our check.
- **USDT-style** (no return data): CALL succeeds, no bool to check. Works correctly in practice because USDT reverts on failure — it just omits the `true` return on success.
- **Non-reverting tokens** (return `false` on failure): **Unsafe.** CALL returns 1 (external call didn't revert), but the transfer silently failed. Funds would not move but the protocol would behave as if they did.

**Mitigation:** Use the token whitelist to restrict routing to known-good ERC20 tokens. A full SafeTransferFrom pattern (`returndatasize` check + `mload` validation) would add ~20 bytes per call and is a candidate for v3 if non-standard token support is required.

### For Huff Learners: Tracing Execution

To trace what happens inside each jump at the opcode level:

```bash
# Deploy to local Anvil, then trace a routeToken call
cast rpc debug_traceCall '{"to":"0x...","data":"0x..."}' '"latest"' --rpc-url http://localhost:8545

# Or run Forge with max verbosity for stack traces
forge test -vvvv --match-test test_routeToken_basic
```

The `-vvvv` flag in Forge shows every opcode executed, including stack state at each step. This is the best way to understand how the dispatcher, reentrancy guard, whitelist check, fee computation, and dual `transferFrom` calls flow through the contract. Each `jumpi` corresponds to a labeled section in the Huff source — trace the stack on paper alongside the `-vvvv` output to build intuition for offset-based EVM programming.

---

## Build & Test

```bash
# Compile Huff to bytecode
huffc JumpiProtocol.huff -b > bytecode.txt

# Run all 113 tests
forge test -vv

# Run with gas reporting
forge test -vv --gas-report

# Fuzz with more runs
forge test -vv --fuzz-runs 1024
```

---

## Stack

- **Language:** Huff 0.3.2
- **Testing:** Foundry (Forge) with Solidity test harness
- **EVM Target:** Cancun
- **Fuzz Runs:** 256 per fuzz test

---

**4 bugs found. 4 bugs fixed. 0 remaining.**

**121 tests. 0 failures. The hardened router is live.**

**2+2=22. Flesh is LEGACY.**
