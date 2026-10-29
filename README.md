# ayHBAR

An ERC-4626 vault for HBAR staking on **Hedera**. Deposit HBAR or HBARX, hold one share
token, and the vault does the rest.

**Live on Hedera mainnet: [`0.0.10937629`](https://hashscan.io/mainnet/contract/0.0.10937629)**
— `0x33ad9057C2e17Fa5b4Abc119606c9CEC97ed85Db`

**Web app: [app-dev.alphayields.ai](https://app-dev.alphayields.ai/)** — source at
[AlphaYields/dapp-ayhbar](https://github.com/AlphaYields/dapp-ayhbar)

---

## How it works

HBAR becomes **HBARX**, Stader's liquid staking token, which appreciates against HBAR every
epoch. The vault holds HBARX and the share price follows it.

Converting is not a single route. The vault quotes both minting at the staking protocol's
redemption rate and buying on each registered liquidity pool, then takes whichever returns
more. Pools of both shapes are supported: constant-product pairs, which the vault swaps
against directly, and concentrated-liquidity pools, which it trades through a router.

Where any two of those price HBARX differently, the curator can sell on one and buy back on
the other — pair to pair, pair to concentrated pool, concentrated pool to pair, or either one
back to the staking protocol at its redemption rate. Every combination settles in a single
transaction that must leave the vault holding more than it started with.

A lending leg is built in and the curator enables it: HBARX is supplied as collateral, HBAR is
borrowed against it and converted back, which scales the position. Collateral and debt are both
HBAR-denominated, so this scales the yield rather than adding market exposure beyond the
deposit itself.

```
            ┌── mint at the protocol rate ──┐
HBAR ───────┤                               ├──► HBARX ──► vault
            └── or buy on the best pool ────┘               │
                                                            │ optional
                            ┌───────────────────────────────┘
                            ▼
              collateral ──► borrow HBAR ──► convert ──► collateral
```

## At a glance

| | |
|---|---|
| Share token | `ayHBAR` |
| **Denomination token** | **HBARX** — shares, net assets, yield and fees are all measured in HBARX |
| Accepted deposits | **HBAR or HBARX** |
| Withdrawals | HBARX |
| Standard | ERC-4626 (OpenZeppelin core, inherited unmodified) |
| Performance fee | 20%, charged only above a high-water mark |
| Management fee | 0% |
| Withdrawal timelock | 1 second |
| Network | Hedera mainnet, `0.0.10937629` |
| Web app | [app-dev.alphayields.ai](https://app-dev.alphayields.ai/) |
| Web app source | [AlphaYields/dapp-ayhbar](https://github.com/AlphaYields/dapp-ayhbar) |
| Licence | MIT |

## Deposits and withdrawals

```solidity
// deposit
approve(vault, amount); vault.deposit(assets, receiver);   // HBARX
vault.depositHBAR{value: amount}(receiver, minAssetsOut);  // native HBAR

// withdraw — while a timelock is set
vault.requestWithdraw(shares);                             // queue
// ... wait out the timelock ...
vault.redeem(shares, receiver, owner);                     // or withdraw(assets, ...)
vault.cancelWithdrawRequest();                             // change your mind
```

`withdraw` takes the asset amount you want; `redeem` takes the number of shares to burn. Both
pay out in HBARX. Queued shares stay invested and keep earning right up until they are burned.

Ready-to-run scripts for every flow are in [`demo/`](demo/) as shell, and in
[`sdk/`](sdk/) as a typed TypeScript client for front ends.

## Strategies

The vault denominates in **HBARX**: every strategy below is measured by whether it ends with
more HBARX per share than it started with, and the contract enforces that rule itself rather
than trusting the caller.

| Strategy | Status | What it does | Depends on |
|---|---|---|---|
| **Cross-venue arbitrage** | **Active** | Sells HBARX on the venue paying most and buys it back on the cheaper one, in one transaction. Runs across both pool shapes and in either direction. | Nothing — live today |
| **Best-route deposit conversion** | **Active** | Quotes every constant-product venue on each HBAR deposit and converts at the best price. | Nothing — live today |
| **Arbitrage into staking** | Ready | Sells HBARX on a venue trading above the redemption rate, then mints it back at that rate — capturing the premium without a swap on the return leg. | Stader's staking entry reopening |
| **Deposit routing through staking** | Ready | Adds minting at the redemption rate to the deposit quote, taking it whenever it beats every pool. | Stader's staking entry reopening |
| **HBAR/HBARX looping** | Ready | Supplies HBARX as collateral, borrows HBAR against it, converts and repeats — scaling the staking yield. Collateral and debt are both HBAR-denominated, so this multiplies the yield rather than adding market exposure. | Bonzo's lending market resuming |

**Active** strategies are running on mainnet now. **Ready** strategies are implemented in this
repository, covered by the test suite, and configured on the deployed contract; each waits on
an external protocol rather than on any further work here. No redeployment is needed to switch
one on — the staking routes come alive the moment Stader accepts deposits, and the lending leg
is enabled by the curator once Bonzo's market resumes.

### How arbitrage is run today

Two venues are registered on mainnet: the SaucerSwap V1 HBARX/WHBAR pair and the V2
concentrated-liquidity pool. Every ordered pair of them is a route, as is each venue into
staking.

A keeper bot (`sdk/scripts/keeper.ts`) watches all of them continuously. Each pass it
enumerates every route, tries a ladder of trade sizes, and simulates each against the live
contract with `eth_call` — so profitability is decided by the vault, not by the bot. It submits
only the best route that pays, and passes the simulated profit as the floor, so a route that
decays between simulation and execution reverts rather than settling worse.

Both legs settle in a single transaction. The vault compares its HBARX balance before and
after and reverts unless the balance went up, which is what makes the operation safe by
construction: it can add to the vault and cannot subtract from it, whatever the pools do in
between. Routes that would take days to settle — redeeming through the staking queue, for
instance — are deliberately not routes at all.

## Fees

Both fees are taken by minting shares to the fee recipient, so vault assets are never touched.

**Performance fee** is charged **only on profit, measured in the denomination token**. The
vault records the high-water mark of its HBARX-per-share price; the fee applies to the gain
above that mark and to nothing else. Principal is never charged, and after a drawdown no fee
is taken on the way back to the previous peak — depositors are never billed twice for the same
ground. A deposit does not create a fee, and neither does the HBARX price moving in HBAR or
dollar terms: only more HBARX per share does.

**Management fee** accrues pro-rata over time on assets under management. It is currently set
to zero.

Fees are bounded in the contract: performance cannot exceed 50%, management cannot exceed 5%.

## Roles

| Role | Can |
|---|---|
| **Owner** | Set fees, roles, timelock, strategy configuration and venues; unpause; recover stray tokens |
| **Guardian** | Pause the vault; unwind leverage at any time |
| **Curator** | Run the strategy: supply, withdraw, lever, arbitrage; adjust the deposit cap |
| **Anyone** | Unwind leverage once the position falls below its health threshold; convert stray balances back to the asset |

Ownership transfers in two steps, so it cannot be handed to an address that cannot accept it.
Pausing halts deposits and withdrawals; only the owner can lift it. Unwinding leverage remains
available while paused, so a position can always be brought back to safety.

No role can withdraw depositor funds: the recovery function rejects the vault's asset, its
collateral receipt, its debt token and the borrowed asset.

## Design notes

**Share pricing never trusts a market price.** With no debt outstanding, net assets are simply
idle balance plus collateral and no price is consulted at all. Once debt exists it is valued at
the staking protocol's redemption rate — a figure the staking contract sets, which moves only
as rewards accrue and cannot be pushed by trading. The lending market's oracle is consulted as
a second opinion and the two must agree within a bound, so no single source can move the share
price on its own. If neither answers, or they disagree, pricing refuses rather than falling
back to a figure that could be moved inside a block.

**Swaps are floored against that same rate**, not against the pool's own reserves. A bound
derived from the reserves a swap is about to read bounds nothing; one derived from the
redemption rate catches both a pool that has been pushed and a trade too large for its depth.

**First-depositor protection.** The vault carries a six-decimal virtual share offset, which
makes the classic donation attack uneconomic. This is why `ayHBAR` has 14 decimals: eight from
the underlying asset plus six of offset.

**Conversions are bounded.** A HBAR deposit carries an absolute minimum output supplied by the
depositor, and every swap checks its result against the measured balance change rather than a
returned value, under the operating slippage limit the owner sets within a hard contract
ceiling.

**Withdrawals are self-servicing.** `maxRedeem` reports what the vault can actually pay, which
under leverage is bounded by the position's health rather than by the whole collateral
balance. A withdrawal that needs more than the idle balance unwinds exactly as much leverage as
it needs, so settling never waits on anyone to act.

**Leverage keeps a health floor.** Building leverage must leave the position at or above a
configured health factor. Below a second, lower level anyone may unwind it, so a position never
depends on a single key being available.

**Arbitrage can only add.** Both legs settle in one transaction and the vault must finish
holding more of its asset than it started with, or the call reverts. The contract decides
profitability itself, on every route and in every direction, so an unprofitable trade cannot
be submitted. There is no path by which it moves value out.

**Loop iterations are capped** so a single transaction stays inside Hedera's child-transaction
limit.

## Hedera specifics

A few platform behaviours shape the implementation:

- Tokens must be associated with an account before it can hold them. `associate()` registers
  the vault's tokens and sets its lending allowances in one permissionless call.
- Token approvals cannot be made from a constructor, and very large approval amounts are
  rejected, so the vault approves a bounded amount after deployment.
- Contract-to-contract calls must target a contract's EVM alias rather than its long-zero
  address. Every address in [`addresses.json`](addresses.json) is recorded in the form the
  vault needs.
- Transactions are legacy-type; the JSON-RPC relay does not accept EIP-1559 fee fields.

## Web app

The front end is deployed at **[app-dev.alphayields.ai](https://app-dev.alphayields.ai/)** and
its source is public at
**[github.com/AlphaYields/dapp-ayhbar](https://github.com/AlphaYields/dapp-ayhbar)**. It talks
to the deployed vault through the client in [`sdk/`](sdk/), so the app and this repository read
the same addresses and the same ABI.

## TypeScript SDK

[`sdk/`](sdk/) holds a typed ethers v6 client plus runnable scripts — deposit in
either asset, the withdrawal queue, and a read-only view that needs no key:

```bash
cd sdk && npm install
npm run status
PRIVATE_KEY=0x... npm run deposit-hbar -- 100
```

The client works unchanged in a browser, and [`sdk/README.md`](sdk/README.md)
documents the Hedera behaviours a front end has to respect — legacy
transactions, fixed gas limits, token association, and the two-step withdrawal.

## Build and test

```bash
git submodule update --init --recursive
forge test
```

58 tests covering fees and the high-water mark, role permissions, the withdrawal queue, the
deposit cap, pausing, share-price integrity and value conservation, deposit routing between
venues, the anchored swap floor, arbitrage in every direction across both pool shapes and the
staking protocol, venue registration, the health-factor bounds and withdrawals under
leverage — including fuzz runs over deposit and redemption, fee bounds and cap enforcement.

Against the live testnet deployment, `./script/validate-testnet.sh` walks every feature on
chain and prints a PASS/FAIL line per check, and `./script/verify-bytecode.sh` confirms the
deployed runtime is exactly this source:

```bash
NETWORK=testnet ./script/verify-bytecode.sh
```

## Deploy

```bash
export PRIVATE_KEY=0x...        # becomes owner
NETWORK=testnet ./script/deploy.sh

export GUARDIAN=0x... CURATOR=0x...
NETWORK=testnet ./script/configure.sh
```

`NETWORK=mainnet` switches every address. See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Status

**Live on Hedera mainnet at [`0.0.10937629`](https://hashscan.io/mainnet/contract/0.0.10937629)**
(`0x33ad9057C2e17Fa5b4Abc119606c9CEC97ed85Db`), denominated in HBARX, with deposits and
withdrawals open, and reachable through the web app at
[app-dev.alphayields.ai](https://app-dev.alphayields.ai/).

Cross-venue arbitrage and best-route deposit conversion are the strategies running today, with
the keeper bot watching every route. The staking and lending strategies are built, tested and
configured, and begin earning as soon as Stader and Bonzo reopen — see
[Strategies](#strategies).

Deposits in both assets, the withdrawal queue, a matured claim by both `redeem` and `withdraw`,
fee accrual, role separation, the deposit cap, the configured bounds and pausing have all been
executed on-chain. Every transaction is listed in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md),
and `script/validate-testnet.sh` re-runs the whole set against a live deployment.

`script/verify-bytecode.sh` compares the deployed runtime against what this repository
compiles, so anyone can confirm the live contract is this source.


