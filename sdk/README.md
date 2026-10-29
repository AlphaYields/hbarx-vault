# ayHBAR SDK

A typed client for the ayHBAR vault, plus runnable scripts. Everything a front
end needs is in [`src/vault.ts`](src/vault.ts); the scripts in
[`scripts/`](scripts) are thin wrappers that double as working examples.

Written against **ethers v6**. The same client works in Node and in the browser —
it takes any ethers `Provider` or `Signer`.

## Run it on a desktop

```bash
cd sdk
npm install
npm run status                                  # vault only, no key needed
ADDRESS=0x... npm run status                     # inspect any address
export PRIVATE_KEY=0x...                         # the only secret required
npm run status
```

| Command | What it does |
|---|---|
| `npm run status` | Vault settings, share price, and your position |
| `npm run deposit-hbar -- 100` | Deposit 100 native HBAR; the vault converts it |
| `npm run deposit-hbarx -- 10` | Deposit 10 HBARX (`all` for the whole balance); approves first |
| `npm run request-withdraw -- 10` | Queue 10 shares for withdrawal (`all` also works) |
| `npm run cancel-request` | Take queued shares back |
| `npm run claim -- all` | Claim a matured request by share count |
| `npm run claim -- 10 assets` | Claim by HBARX amount instead |
| `npm run typecheck` | `tsc --noEmit` |

Every script refuses before sending when something is wrong — no key, nothing
queued, a request that has not matured, over the cap, the vault paused or not
yet associated — so a mistake costs nothing.

## Point it somewhere else

All of it lives at the top of [`src/config.ts`](src/config.ts): RPC, chain id,
mirror node, explorer, vault and HBARX addresses, gas limits and decimals. Edit
that file, or override per run:

```bash
NETWORK=testnet npm run status
VAULT=0x... RPC_URL=https://testnet.hashio.io/api npm run status
```

Addresses are normalised to EIP-55 on the way in, so any casing works — worth
knowing, because Hedera tools print addresses several different ways and ethers
rejects a mixed-case address whose checksum does not match.

## Using it in a front end

```ts
import { BrowserProvider } from "ethers";
import { AyHbarVault, toHbar, toAssets, showAssets } from "./sdk/src";

const provider = new BrowserProvider(window.ethereum);
const signer = await provider.getSigner();
const vault = new AyHbarVault(signer);

// read
const state = await vault.state();          // fees, cap, timelock, price, pause
const me = await signer.getAddress();
const pos = await vault.position(me);       // shares, value, queue, claimable

// deposit HBAR — quote first so the user sees what they get
const quote = await vault.quoteHbarDeposit(toHbar("100"));
showAssets(quote.expectedAssets);           // "69.54513051"
const res = await vault.depositHbar(quote.hbarIn, { receiver: me });
if (res.status !== "success") { /* show res.url */ }

// deposit HBARX — handles the approve when the allowance is short
await vault.depositHbarx(toAssets("10"), { receiver: me, owner: me });

// withdraw, two steps
await vault.requestWithdraw(pos.shares);
// ... wait out state.withdrawTimelock ...
await vault.redeem(pos.shares, me, me);
```

A read-only client needs no wallet at all — useful for a landing page:

```ts
const vault = AyHbarVault.readOnly();
```

For wallet connection: EVM wallets (MetaMask and friends) work directly against
the Hashio relay — add the network with chain id 295 and
`https://mainnet.hashio.io/api`. HashPack and Blade connect through Hedera's
WalletConnect integration; either way you end up with an EIP-1193 provider that
`BrowserProvider` accepts.

## Eight things about Hedera that will bite otherwise

The client already handles all of these. They are listed because a front end
that bypasses it will hit every one.

**1. Transactions must be legacy (type 0).** The relay rejects EIP-1559 fee
fields, and the error it returns is a misleading "Insufficient funds for
transfer". Every write in this client sets `type: 0` with an explicit
`gasPrice`.

**2. Gas limits are set, not estimated.** The relay reserves
`gasLimit × gasPrice` from the sender's balance before execution, and charges
the **whole limit** when a call runs out of gas. The measured figures are in
`GAS` in `config.ts`: an HTS approve costs ~783k, an HBAR deposit ~275k, an
HBARX deposit ~165k, a claim ~169k.

**2a. The gas price is read from the relay, never hardcoded.** The relay
enforces a minimum and that minimum moves — it went from 114 to 116 tinybar per
gas within a day. A send below it is rejected with:

```
Gas price '1140000000000' is below configured minimum
```

and the rejection costs nothing but still advances the relay's cached nonce, so
the *next* send fails with `WRONG_NONCE` even though it is correct. `config.ts`
exposes `gasPriceWei(signerOrProvider)`, which calls `eth_gasPrice`, pads it by
`GAS_PRICE_PADDING_PCT` (20%), and caches the reading for 30 seconds so a
multi-transaction script does not re-query per send. Every write in this client
goes through it. If the relay will not answer, `GAS_PRICE_FALLBACK_WEI` is used
so a transient failure does not block a send.

A front end that builds its own transactions must do the same — call
`eth_gasPrice` and pay over it. Paying over the minimum costs nothing: the relay
refunds whatever the transaction does not use, so only the reservation is
larger. `npm run status` prints the price the client would send with.

**3. A reverted transaction still returns a receipt.** `status` is the only
thing that tells you what happened — never treat "the call returned" as
success. Every write here returns `status: "success" | "failed"` and the scripts
exit non-zero on a failure.

**4. Never approve `uint256` max.** Hedera's token service rejects very large
approval amounts. `depositHbarx` approves exactly the deposit, which also leaves
no standing allowance.

**5. Tokens need association before they can be received.** Withdrawals pay in
HBARX, so an account that cannot hold HBARX cannot be paid. Check with
`vault.canReceiveHbarx(address)` before offering a withdrawal — it answers from
the mirror node, free and without gas. Most wallets have unlimited automatic
association and are fine.

**6. An EVM address is not an account until it is funded.** The HBARX facade
reverts for an address that has never existed. `position()` returns
`accountExists: false` instead of throwing, so a new user reads as "needs HBAR
first" rather than as an error.

**7. The relay lags the mined nonce.** Two sends in quick succession fail with
"Nonce too low". `depositHbarx` waits between its approve and its deposit; add
the same gap anywhere you chain writes.

**8. Value is settled in tinybar.** Anything finer than 1e-8 HBAR in a `value`
field is truncated by the network. `roundToTinybar` does it explicitly so the
amount you quote is the amount that moves.

## Decimals

| | Decimals | 1 unit |
|---|---|---|
| HBARX, and every `assets` amount | 8 | `100000000` |
| `ayHBAR` shares | 14 | `100000000000000` |
| Native HBAR in a `value` field | 18 | `1000000000000000000` |

Shares carry 14 because the vault adds a 6-decimal virtual offset to the asset's
8 — the first-depositor protection. Use `toAssets`, `toShares`, `toHbar` to
parse and `showAssets`, `showShares`, `showHbar`, `showPrice` to display.
`showPrice` keeps all eight places, so a share price of exactly 1 prints as
`1.00000000` rather than `1.0`.

`pricePerShare()` is HBARX per whole share, scaled by 1e8: `100000000` is
1.00000000 and it only rises as the strategy earns.

## Withdrawals are two steps

While `withdrawTimelock` is non-zero — one day in the live configuration —
exiting is `requestWithdraw(shares)`, then `redeem` or `withdraw` once the
request matures. Calling `redeem` without a matured request reverts with
`NoMaturedRequest`.

Queued shares leave the holder's balance and sit with the vault, but they stay
in `totalSupply` and keep earning right up to the moment they are burned.
`cancelWithdrawRequest()` returns them at any point before a claim. Adding to an
existing request restarts the clock on the whole of it.

`position()` gives a UI everything it needs for this: `queuedShares`,
`unlockAt`, `claimable`, and `maxRedeem` / `maxWithdraw`, which are the amounts
claimable this instant after the timelock, the pause state and available
liquidity have all been applied. Both read `0` while the vault is paused.

## Errors worth handling by name

The ABI includes the vault's custom errors, so ethers decodes a revert into a
name rather than a hex blob.

| Error | Meaning for the user |
|---|---|
| `CapExceeded` | Deposit is over the cap; show `maxDeposit` |
| `NoMaturedRequest` | Nothing queued — send them through `requestWithdraw` |
| `TimelockNotElapsed` | Queued but too early; show `unlockAt` |
| `NotAuthorized` | An admin-only call from the wrong address |
| `InvalidParam` | Zero amount, a bad address, or a conversion below `minAssetsOut` |
| `EnforcedPause` | The vault is paused; deposits and withdrawals are both halted |

## Notes on the live deployment

`staking()` returning the zero address means HBAR deposits convert through the
SaucerSwap pool rather than staking at Stader's protocol rate.
`quoteHbarDeposit` follows whichever route is configured, so a UI does not need
to care — but the quote is worth showing, since the two routes price
differently. `state().staking` exposes it if you want to label the route.
