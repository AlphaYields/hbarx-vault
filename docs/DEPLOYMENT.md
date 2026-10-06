# HbarxLoopVault — custom ERC-4626 vault for HBAR/HBARX looping on Hedera

*Deployed and exercised on Hedera testnet (chain 296), 2026-10-05.*

**Vault: `0.0.10879010`** · https://hashscan.io/testnet/contract/0.0.10879010

---

## What it does

ERC-4626 vault whose asset is HBARX. It accepts **both HBAR and HBARX** as deposits —
native HBAR is converted on the way in — and runs the HBARX-collateral / WHBAR-borrow
leverage loop against Bonzo Lend, swapping on SaucerSwap.

| Requirement | Status |
|---|---|
| ERC-4626 standard | yes — OpenZeppelin `ERC4626` inherited |
| HBARX depositable | yes — demonstrated |
| **HBAR depositable** | **yes — demonstrated** |
| Looping strategy | implemented; not exercisable on testnet (no active lending market) |
| Security verified | 13 tests, all passing, incl. 768 fuzz runs |
| Testnet + mainnet | same bytecode, addresses are constructor arguments |

---

## Demonstrated on testnet

| Flow | Result | Transaction |
|---|---|---|
| Deploy | vault live | [`0x37726121…`](https://hashscan.io/testnet/transaction/0x37726121d515f4fe7d43f207e1724e5770a0f8afb6ff894d151e6cc84377dcd7) |
| `associate()` | HBARX + WHBAR associated, pool approved | [`0x29a1d12e…`](https://hashscan.io/testnet/transaction/0x29a1d12e41ec77982277bbb6eec1f04a7ccde0bdb78f5086f8c004d4cb7005a1) |
| **Deposit HBARX** 0.3 | 3.0e13 shares minted | [`0xc33c12c7…`](https://hashscan.io/testnet/transaction/0xc33c12c705706634636f646d04e1c179171d820063a257e42beec4b6b5acb293) |
| **Deposit HBAR** 2.0 | wrapped → swapped → 0.1305 HBARX → shares | [`0xc3198cb2…`](https://hashscan.io/testnet/transaction/0xc3198cb227b6398cb0f12b1801227deedae2dd728465055ad7fc0f65bd5bb95a) |
| **Withdraw** 0.1 HBARX | asset-denominated exit | [`0x60133a2e…`](https://hashscan.io/testnet/transaction/0x60133a2e5bf314930f4774b9f291784caf23e93eda3948fb7ee03b8c3f08e890) |
| **Redeem** half of shares | share-denominated exit | [`0xc0adc3c9…`](https://hashscan.io/testnet/transaction/0xc0adc3c98cb5752b97431772c2294dcae0e54f780f22047c98bb9d10f08ca74f) |

All confirmed `SUCCESS` on the mirror node. Vault is left funded: `totalAssets = 16,527,765`
(0.165 HBARX), so liquidity is testable.

---

## Security

### How NAV is priced — the part that matters most

Every earlier version valued WHBAR debt at the SaucerSwap mid-price. That is manipulable
within a single block: move the pair, mint or burn shares against a false NAV. This version
does not do that.

```
debt == 0   ->  NAV = idle + collateral.  No price is consulted at all.
debt  > 0   ->  priced ONLY by the lending market's own oracle.
                If that oracle cannot answer, totalAssets() REVERTS.
```

Three consequences worth stating plainly:

- On testnet debt is always zero (borrowing is impossible there), so the vault is fully
  functional **and** has no price dependency — there is no manipulation surface at all.
- On mainnet the oracle is live — verified: HBARX `1.4298`, WHBAR `1.0` — and it is the same
  oracle that decides liquidation, so NAV and liquidation can never disagree.
- Reverting is deliberate. A vault that cannot price itself must not mint or burn shares.
  It is not a lock-in: `deleverage()` reads balances only and never calls `totalAssets()`,
  so the position can always be unwound back to zero debt.

### A real vulnerability the tests caught

OpenZeppelin's `_decimalsOffset()` defaults to **0**, which leaves the first-depositor /
donation inflation attack viable. The test reproduced it: a 1-wei first deposit plus a
500-token direct transfer rounded the next depositor's shares to **zero**.

Overriding the offset to 6 fixes it — the attack now needs roughly 10⁶× more capital than it
can extract. This is why the vault's share token has 14 decimals (8 asset + 6 offset).

### Test results

```
VaultSecurityTest
  [PASS] test_inflationAttackIsMitigated        donation attack cannot strip a victim
  [PASS] test_noDebtNeedsNoOracle               no debt -> no price dependency
  [PASS] test_debtWithDeadOracleReverts         fail-safe, never fail-open
  [PASS] test_ammManipulationDoesNotMoveNav     violent reserve move leaves NAV untouched
  [PASS] test_ownerCannotSweepUserFunds         owner cannot touch asset/aToken/debt
  [PASS] test_strategyIsPermissioned            loop controls are not public
  [PASS] test_pauseBlocksDepositsNotExits       users can always exit
  [PASS] test_roundTripConservesValue           no value leak
  [PASS] test_loopBoundsEnforced                loop count and slippage bounded
  [PASS] test_withdrawPullsFromCollateral       unwinds collateral when idle is short

VaultInvariantTest  (256 fuzz runs each)
  [PASS] testFuzz_depositRedeemNeverProfits     nobody extracts more than they put in
  [PASS] testFuzz_twoDepositorsFairShare        depositors cannot dilute each other
  [PASS] testFuzz_navIdentityNoDebt             NAV == idle + collateral when debt is zero

13 passed, 0 failed.
```

### Other protections

| Attack | Mitigation |
|---|---|
| Sandwich on HBAR deposit or loop swaps | Caller-supplied `minOut`, computed from live reserves, verified by measured balance delta |
| Owner rug | `sweep()` reverts on the asset, aToken and debt token — the owner can lever and unwind but cannot withdraw user funds |
| Reentrancy | `nonReentrant` on every external state-changing entry point |
| Emergency | Deposits pausable; **withdrawals are not** — exits can never be blocked |
| Ownership mistakes | `Ownable2Step` — ownership transfer must be accepted |

---

## Testnet vs mainnet

The same bytecode runs on both. Every address is a constructor argument, and two of them
differ by environment:

| | Testnet (deployed) | Mainnet |
|---|---|---|
| Oracle | `address(0)` — not required while debt is zero | `0x2e78BedD…` — live and verified |
| Staking | `address(0)` — no Stader on testnet, so HBAR routes through the SaucerSwap pair | Stader `0.0.1412503`, rate `1.43471473` — HBAR mints HBARX at protocol rate, zero slippage |
| HBARX | `0.0.2231533` | `0.0.834116` |
| WHBAR | `0.0.15058` | `0.0.1456986` |

Both are settable afterwards by the owner (`setOracle`, `setStaking`), so a mainnet deployment
can start conservatively and enable staking once confirmed.

**Mainnet leverage parameters:** HBARX LTV 62.98% / LT 68.28% → ceiling 2.70×, not the 3.33×
testnet suggests.

---

## Status of the loop

The loop is implemented (`leverUp`, `deleverage`) and bounded, but **has not executed on
testnet**. Opening a leveraged position needs an active lending market with live price feeds,
and the testnet lending environment does not currently provide one.

On mainnet the lending market is funded and in production use, so the supply and borrow
mechanics are available there. Our specific sequence has not run yet, and we intend to
exercise it against a mock lending pool before any mainnet deployment — that is the
recommended next step and it does not depend on external availability.

---

## Files

```
src/HbarxLoopVault.sol        the vault — 330 custom lines
test/VaultSecurity.t.sol      13 tests incl. fuzz
data/                         addresses, deployment records
```
