# HbarxLoopVault

ERC-4626 vault for the HBARX/WHBAR leverage loop on **Hedera**, accepting **both HBAR and
HBARX** as deposits.

Deployed on Hedera testnet: [`0.0.10879010`](https://hashscan.io/testnet/contract/0.0.10879010)

## What it does

Deposit HBAR or HBARX, receive `ayHBARX` shares. Native HBAR is converted to HBARX on the way
in — by staking at the protocol rate where a staking contract is configured, otherwise by
swapping on SaucerSwap. Withdrawals are in HBARX.

Capital is supplied to a lending market as collateral and the position can be levered by
borrowing WHBAR, swapping it back to HBARX and re-supplying, up to a bounded number of
iterations.

## Design notes

**ERC-4626 core is OpenZeppelin's**, inherited unmodified — share conversion, rounding, ERC-20
behaviour. `_decimalsOffset()` is overridden to 6: OpenZeppelin defaults it to 0, which leaves
the first-depositor / donation inflation attack viable. Hence the share token carries 14
decimals (8 asset + 6 offset).

**NAV never trusts an AMM.** With no debt outstanding, net assets are simply idle + collateral
and no price is consulted. Once debt exists it is valued only by the lending market's own
oracle — the same oracle that decides liquidation — and `totalAssets()` reverts rather than
fall back to a spot price that can be moved within a block. That is not a lock-in:
`deleverage()` reads balances only, so a position can always be unwound to zero debt.

**Hedera specifics** are handled explicitly: HTS association (HIP-719) before any token can be
held, approvals deferred out of the constructor, the HTS approve ceiling, EVM-alias addressing
for contract-to-contract calls, and loop iterations capped for the child-transaction limit.
See `docs/hedera_findings.json`.

## Build and test

```bash
git submodule update --init --recursive
forge test
```

13 tests, including 768 fuzz runs covering share accounting, NAV identity and dilution.

## Security properties under test

| Property | Test |
|---|---|
| Donation / inflation attack cannot strip a depositor | `test_inflationAttackIsMitigated` |
| No price dependency while debt is zero | `test_noDebtNeedsNoOracle` |
| Dead oracle fails safe, never fails open | `test_debtWithDeadOracleReverts` |
| AMM manipulation cannot move NAV | `test_ammManipulationDoesNotMoveNav` |
| Owner cannot withdraw user funds | `test_ownerCannotSweepUserFunds` |
| Exits can never be paused | `test_pauseBlocksDepositsNotExits` |
| Nobody extracts more than deposited | `testFuzz_depositRedeemNeverProfits` |
| Depositors cannot dilute each other | `testFuzz_twoDepositorsFairShare` |

## Status

The vault — deposits in both assets, withdrawals, share accounting — is deployed and exercised
on testnet; see `docs/DEPLOYMENT.md` for transactions.

The leverage functions are implemented and bounded but **have not been exercised**, because
opening a position requires an active lending market with live price feeds. They are unaudited
and should be run against a mock lending pool before any mainnet use.

**This code has not been audited.**

## Licence

MIT
