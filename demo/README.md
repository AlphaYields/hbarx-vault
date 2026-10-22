# Testnet demo scripts

Deposit and withdraw against the live vault on Hedera testnet, from your own machine.

**Vault:** [`0.0.11131621`](https://hashscan.io/testnet/contract/0.0.11131621)

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
| `./status.sh` | Wallet balances, vault TVL, share price, timelock, cap, pending request |
| `./deposit-hbarx.sh 0.05` | Deposit HBARX (approve + deposit) |
| `./deposit-hbar.sh 1` | Deposit **native HBAR** — converted to HBARX inside the vault |
| `./request-withdraw.sh all` | Queue shares for withdrawal and print when they mature |
| `./cancel-request.sh` | Take queued shares back out of the queue |
| `./withdraw.sh 0.02` | Withdraw a HBARX amount from a matured request |
| `./redeem.sh all` | Redeem matured shares; `all` claims everything available |
| `./demo.sh` | Runs the whole sequence end to end |

## Withdrawing

The vault has a **1-day withdrawal timelock**. Exiting is two steps:

```bash
./request-withdraw.sh all     # queue the shares; prints the claimable-at time
#  ... wait out the timelock ...
./redeem.sh all               # burn the matured shares, receive HBARX
```

Queued shares stay in the vault's share supply and keep earning until they are burned, and
`./cancel-request.sh` returns them to you at any time before you claim.

`status.sh` prints the timelock, the deposit cap and any request you have pending.

## Full demonstration

```bash
export PRIVATE_KEY=0x<key>
cd demo
./demo.sh
```

Deposits in both assets, queues the whole balance for withdrawal, shows the pending request and
cancels it — printing state and a HashScan link at every step. It does not wait out the
timelock; run the two withdrawal steps above for a complete exit.

## Notes

`deposit-hbar.sh` quotes the HBAR→HBARX conversion and allows 5% slippage. On testnet the pool
prices HBARX far from its real rate, so the amount of HBARX received per HBAR is not
economically meaningful — the point is that the conversion and share minting work.

Scripts pause a few seconds between transactions: Hedera's JSON-RPC relay lags behind the mined
nonce, and consecutive sends otherwise fail with `Nonce too low`.

All transactions are legacy-type. The relay rejects EIP-1559 fee fields with a misleading
"Insufficient funds for transfer".
