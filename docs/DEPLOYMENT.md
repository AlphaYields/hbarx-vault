# Deployment

## Live on Hedera mainnet

**Vault `0.0.10937454`** — [HashScan](https://hashscan.io/mainnet/contract/0.0.10937454)
`0x147455820BD5Bc74C3ef849628a56aF8ABA1156f`

| Setting | Value |
|---|---|
| Share token | `ayHBAR`, 14 decimals |
| Underlying asset | HBARX (`0.0.834116`) |
| Performance fee | 20% (2000 bps), high-water mark |
| Management fee | 0% |
| Withdrawal timelock | 86,400 s (1 day) |
| Deposit cap | 100,000 HBARX |
| Slippage limit | 1% operating, 5% contract ceiling |
| Owner | `0x400682786dEe019d002a7900841c0586Cb0440C7` |
| Guardian | `0xb76150B158C747a75787143E9a0C85E20A0134b7` |
| Curator and fee recipient | `0xADa452b96C65A931dB47Af71b55257646b2Fa94F` |
| Linked library | `VaultMath` [`0.0.10937449`](https://hashscan.io/mainnet/contract/0.0.10937449) — `0x55FA8bA02c637B72FF9a9D3096a2730D6cc75a32` |

The deployed runtime is byte-for-byte what this repository compiles, which
`script/verify-bytecode.sh` reproduces against the linked library above.

## Live on Hedera testnet

**Vault `0.0.11131621`** — [HashScan](https://hashscan.io/testnet/contract/0.0.11131621)
`0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e`

| Setting | Value |
|---|---|
| Share token | `ayHBAR`, 14 decimals |
| Underlying asset | HBARX (`0.0.2231533`) |
| Performance fee | 20% (2000 bps), high-water mark |
| Management fee | 0% |
| Withdrawal timelock | 86,400 s (1 day) |
| Deposit cap | 87,874 HBARX (≈ 10,000 USD at deployment) |
| Slippage limit | 1% operating, 5% contract ceiling |
| Owner | `0x2A7e1187…` |
| Guardian | `0x5C72f1Cf…` |
| Curator | `0x49c8a1dC…` |

## Verified on-chain

Every feature was exercised against the live deployment. `tx` links to HashScan.

| Flow | Result |
|---|---|
| Deploy | [`0x9afd5fb9…`](https://hashscan.io/testnet/transaction/0x9afd5fb9a1477cfe4766bf74580bc43782d059de7cd5313a4d407aa61b35afec) |
| `associate()` | [`0x7cc91e14…`](https://hashscan.io/testnet/transaction/0x7cc91e143b99dac842e08aef3069b5db25687224b638f450cd9e046754911f47) — HTS tokens registered, pool allowances set |
| Deposit HBARX | [`0xc6a463f7…`](https://hashscan.io/testnet/transaction/0xc6a463f7b4cf397a3d7d58b1264bd7bf5fa1eeea1143bb8990deeb630bc473e6) — 0.1 HBARX at price 1.00000000 |
| Deposit native HBAR | [`0x750c15d2…`](https://hashscan.io/testnet/transaction/0x750c15d2cd278652eeb24d240bf3073506493d182f744ac400628c59fe6fd92c) — 1 HBAR converted and minted in one call |
| Request withdrawal | [`0xe21d3c88…`](https://hashscan.io/testnet/transaction/0xe21d3c8856ecfd42e17a67d07121271bc330566b72110b0dbecad5857e78d6cc) — shares escrowed, `totalSupply` unchanged so they keep earning |
| Redeem before maturity | rejected |
| Cancel request | [`0x57bb1572…`](https://hashscan.io/testnet/transaction/0x57bb15728424c0506cff82209127252c6a863459e6d810665a1e559d772db485) — shares returned in full |
| Redeem a matured request | [`0x7eb6770a…`](https://hashscan.io/testnet/transaction/0x7eb6770ae9e13ca81e772f92ce1ceab3f080591fc28377f0898f0261cfe5be0b) — 5,484,043 raw HBARX for 5.0e12 shares |
| Withdraw a matured request | [`0x96f0561e…`](https://hashscan.io/testnet/transaction/0x96f0561e871f755a6c58495d61c5ce154e746f2b486e112ab2a85bd038a6cdcf) — paid 5,484,044 against 5,484,044 asked, exact to the unit |
| Performance fee | [`0xb42b9a6f…`](https://hashscan.io/testnet/transaction/0xb42b9a6fe676dc18259dc6cf35c917171a6383137574a55724c751bbf5d9d52a) — 2,000,000 raw of yield, fee worth 399,998 (20.00%); share price 1.00000000 → 1.09680879, depositors kept the rest |
| Guardian pause | [`0x9f5ed7c0…`](https://hashscan.io/testnet/transaction/0x9f5ed7c0152cb29a31e2dc50bc8d60e741c3075212ad2bb767d78d24e90bd3f7) — deposits, withdrawals and redemptions all halted; `maxDeposit` and `maxRedeem` report 0 |
| Unwind while paused | [`0x9219f148…`](https://hashscan.io/testnet/transaction/0x9219f14891a27c017e465db6dcb4e039aa76efcdd4dadc83c216a9535c493ab1) — available to the guardian throughout |
| Owner unpause | [`0x690ea0dc…`](https://hashscan.io/testnet/transaction/0x690ea0dc7ca8e5028bcee68cd95040956b46ba07f5e1b159455480d2497e26db) |
| Guardian unpause | rejected — owner only |
| Curator or guardian changing fees | rejected — owner only |
| Curator changing the timelock | rejected — owner only |
| Curator setting the deposit cap | [`0xb702e8ca…`](https://hashscan.io/testnet/transaction/0xb702e8ca0c381d471391011820e9fe5208ef68467c82a4a91984afbd182c90d2) — permitted |
| An address with no role pausing, capping or sweeping | rejected |
| `sweep` of the asset, collateral receipt, debt token or borrowed asset | rejected in all four cases |
| Fee above 50%, management above 5%, timelock above 30 days, slippage above 5% | rejected in all four cases |

## Re-running the checks

Every row above is reproducible against a live testnet deployment:

```bash
export OWNER_KEY=0x... GUARDIAN_KEY=0x... CURATOR_KEY=0x...
CONFIRM=yes ./script/validate-testnet.sh
```

It prints a PASS/FAIL line per check and exits non-zero if any fail. The run temporarily
shortens the withdrawal timelock so a matured claim can be demonstrated in one pass, and
restores it on the way out. The owner account needs about 8 HBAR of gas and 0.15 HBARX; the
guardian and curator accounts about 1 HBAR each. Testnet only.

## Confirming the deployed code

```bash
NETWORK=testnet ./script/verify-bytecode.sh
```

It compiles this repository and compares the result byte for byte against the runtime code on
chain, excluding only the immutable slots that hold the constructor's addresses and the
trailing metadata hash, which covers the import paths used at compile time.

```
address        0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e
runtime length 21618 bytes
immutable bytes 687 (constructor addresses)
MATCH — the deployed code is this source
```

## Operating the vault

Every call below is a plain `cast send`. Hedera needs legacy transactions, and the gas limit
should sit near the estimate — see *Gas notes*. On macOS, run `setopt interactive_comments`
first if you paste shell comments into an interactive zsh.

```bash
export RPC=https://testnet.hashio.io/api      # mainnet: https://mainnet.hashio.io/api
export VAULT=0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e
export TXFLAGS="--legacy --gas-price 1140000000000 --gas-limit 900000"
send(){ cast send $VAULT "$@" --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS; }
```

**Owner**

| Action | Command |
|---|---|
| Set fees and recipient | `send "setFees(uint16,uint16,address)" 2000 0 $RECIPIENT` |
| Set both delegate roles | `send "setRoles(address,address)" $GUARDIAN $CURATOR` |
| Set strategy references and bounds | `send "configureStrategy(address,address,uint16,uint16,uint256,uint256)" $ORACLE $STAKING 100 100 1400000000000000000 1150000000000000000` |
| Register a liquidity venue | `send "addVenue(address,uint16)" $PAIR 997` |
| Take a venue out of routing | `send "setVenueActive(uint256,bool)" 1 false` |
| Set withdrawal timelock | `send "setWithdrawTimelock(uint64)" 86400` |
| Unpause | `send "unpause()"` |
| Recover a stray token | `send "sweep(address,address,uint256)" $TOKEN $TO $AMOUNT` |
| Begin ownership transfer | `send "transferOwnership(address)" $NEW_OWNER` |
| Accept ownership (from the new owner) | `send "acceptOwnership()"` |

Fees are capped in the contract at 50% performance and 5% management; the timelock at 30 days,
the slippage limit at 5% and the oracle tolerance at 5%. Supplying collateral marks the reserve
as collateral on every call, so it cannot be left unset. `sweep` rejects the vault's asset, its collateral receipt, its
debt token and the borrowed asset.

**Guardian**

| Action | Command |
|---|---|
| Pause (halts deposits and withdrawals) | `send "pause()"` |
| Unwind leverage | `send "deleverage(uint8,uint256,uint16)" 3 $WITHDRAW_PER_LOOP 100` |
| Convert a stray borrowed balance back | `send "recoverWhbar()"` (anyone) |

`deleverage` stays available while paused, so a position can always be brought back to safety.

**Curator**

| Action | Command |
|---|---|
| Set the deposit cap | `send "setDepositCap(uint256)" $CAP` |
| Supply idle assets as collateral | `send "supplyToPool(uint256)" $AMOUNT` |
| Withdraw collateral to idle | `send "withdrawFromPool(uint256)" $AMOUNT` |
| Build leverage | `send "leverUp(uint8,uint256,uint16)" 3 $BORROW_PER_LOOP 100` |
| Sell on one venue, buy back on another | `send "arbitrage(uint256,uint256,uint256,uint256)" 1 0 $AMOUNT $MIN_PROFIT` |
| Sell on a venue, mint back through staking | `send "arbitrage(uint256,uint256,uint256,uint256)" 0 $MAX_UINT $AMOUNT $MIN_PROFIT` |

**Anyone**

| Action | Command |
|---|---|
| Register HTS tokens and lending allowances | `send "associate()"` |
| Accrue fees up to now | `send "accrueFees()"` |

**Reading state**

```bash
cast call $VAULT "totalAssets()(uint256)"            --rpc-url $RPC
cast call $VAULT "pricePerShare()(uint256)"          --rpc-url $RPC
cast call $VAULT "performanceFee()(uint16)"          --rpc-url $RPC
cast call $VAULT "withdrawTimelock()(uint64)"        --rpc-url $RPC
cast call $VAULT "depositCap()(uint256)"             --rpc-url $RPC
cast call $VAULT "paused()(bool)"                    --rpc-url $RPC
cast call $VAULT "owner()(address)"                  --rpc-url $RPC
cast call $VAULT "guardian()(address)"               --rpc-url $RPC
cast call $VAULT "curator()(address)"                --rpc-url $RPC
cast call $VAULT "withdrawableAt(address)(uint256,uint64)" $USER --rpc-url $RPC
```

## Mainnet checklist

1. **Fund the deployer.** Roughly 25 HBAR covers the library (≈1.5), the vault (≈6) and
   `associate()` (≈3.3) with headroom for configuration.
2. **Deploy**, then **configure** with the real guardian and curator addresses.
3. **Recompute the deposit cap** — `configure.sh` prices it at run time, but confirm the HBARX
   rate it uses is current.
4. **Confirm the oracle and staking contract.** Both come from `addresses.json` and are set at
   deployment on mainnet — the live price oracle (`0x2e78BedD7175dEC675949f50a2604bC835A47a03`),
   required before any leverage is taken, and Stader (`0.0.1412503`). Read both back with
   `oracle()` and `staking()`.
5. **Register the conversion venues.** Deposits are routed automatically: the vault quotes
   minting at the staking protocol's rate and buying on each registered pool, and takes the
   better. The first venue is set at deployment from `addresses.json`; register any others
   with `addVenue(pair, feeNum)`, where `feeNum` is the pool's fee numerator out of 1000 —
   997 for a 0.30% pool. Read the current rate the vault prices against with:

   ```bash
   cast call $VAULT "assetPriceInWhbar()(uint256)" --rpc-url $RPC
   cast call $VAULT "venues(uint256)(address,uint16,bool)" 0 --rpc-url $RPC
   ```

6. **Verify roles** read back correctly before announcing the vault, and confirm the guardian
   and curator accounts exist on mainnet and hold HBAR — an address stored in the contract
   cannot sign anything until its account is funded.
7. **Transfer ownership** to its final holder if the deployer is not it. Ownership moves in two
   steps: `transferOwnership` then `acceptOwnership` from the new address.

## Gas notes

Hedera's JSON-RPC relay reserves `gasLimit × gasPrice` up front, so an oversized gas limit can
be rejected for insufficient funds even when the transaction would cost little. Estimate first
and set the limit close to the estimate. Typical costs at 114 tinybar/gas:

| Operation | Gas | Cost |
|---|---:|---:|
| Deploy `VaultMath` | ~1,300,000 | ≈1.5 HBAR |
| Deploy the vault | ~5,300,000 | ≈6.0 HBAR |
| `associate()` | 2,858,664 | ≈3.3 HBAR |
| Deposit HBARX | 165,161 | ≈0.19 HBAR |
| Deposit HBAR (wrap + swap) | 273,214 | ≈0.31 HBAR |
| Deposit HBAR (stake route) | ~800,000+ | ≈0.90 HBAR |
| Request withdrawal | 124,446 | ≈0.14 HBAR |
| Redeem | 168,737 | ≈0.19 HBAR |
| `accrueFees()` | 111,166 | ≈0.13 HBAR |

Measured on the deployment above; a deploy needs its limit set near 5.6M and `associate()`
near 3M, both of which the deploy script sets.

All transactions are legacy-type; the relay does not accept EIP-1559 fee fields.
