# Testnet demo scripts

Deposit and withdraw against the live vault on Hedera testnet, from your own machine.

**Vault:** [`0.0.10879010`](https://hashscan.io/testnet/contract/0.0.10879010)

## Requirements

Foundry (`cast`) and Python 3.

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

## Setup

```bash
export PRIVATE_KEY=0x<key>
cd demo
./status.sh            # confirm it can see your balances
```

## Scripts

| Script | What it does |
|---|---|
| `./status.sh` | Wallet balances, vault TVL, share supply |
| `./deposit-hbarx.sh 0.05` | Deposit HBARX (approve + deposit) |
| `./deposit-hbar.sh 1` | Deposit **native HBAR** — converted to HBARX inside the vault |
| `./withdraw.sh 0.02` | Withdraw a HBARX amount |
| `./redeem.sh all` | Redeem shares; `all` exits fully, or pass an amount |
| `./demo.sh` | Runs the whole sequence end to end |

## Full demonstration

```bash
export PRIVATE_KEY=0x<key>
cd demo
./demo.sh
```

Deposits in both assets, then a withdraw and a full redeem, printing state and a HashScan link
at every step.

## Notes

`deposit-hbar.sh` quotes the HBAR→HBARX conversion and allows 5% slippage. On testnet the pool
prices HBARX far from its real rate, so the amount of HBARX received per HBAR is not
economically meaningful — the point is that the conversion and share minting work.

Scripts pause a few seconds between transactions: Hedera's JSON-RPC relay lags behind the mined
nonce, and consecutive sends otherwise fail with `Nonce too low`.

All transactions are legacy-type. The relay rejects EIP-1559 fee fields with a misleading
"Insufficient funds for transfer".
