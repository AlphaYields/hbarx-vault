/**
 * Arbitrage keeper for the ayHBAR vault.
 *
 * Every pass it enumerates every route the vault can execute atomically, asks
 * the chain what each would return, and sends the best one that profits.
 *
 *   venue i -> venue j     sell the asset on one pool, buy it back on another
 *   venue i -> staking     sell on a pool, mint it back at the redemption rate
 *
 * Both pool kinds take part in either leg: constant-product pairs, which the
 * vault swaps against directly, and concentrated-liquidity pools, which it
 * trades through the router. Every ordered combination is tried.
 *
 * Only routes that settle in a single transaction are considered. Redeeming
 * through the staking queue would take days and is deliberately not a route.
 *
 * Profitability is decided by the vault itself, not by this script: each
 * candidate is simulated with `eth_call` against the real contract, so the
 * swap floors, the slippage limit and the end-with-more rule all apply before
 * anything is sent. A route that would lose cannot be submitted, and if one
 * slipped through the contract would revert it.
 *
 * Usage:
 *   CURATOR_ADDRESS=0x... npm run keeper             watch and report, no key
 *   CURATOR_KEY=0x... EXECUTE=1 npm run keeper       watch and send
 *
 * Options (environment):
 *   INTERVAL_SECONDS   seconds between passes                  default 60
 *   MIN_PROFIT_BPS     minimum gain, in bps of the amount      default 5
 *   MAX_TRADE_BPS      largest trade, in bps of idle assets    default 5000
 *   ONCE               run a single pass and exit
 */
import { Contract, formatUnits } from "ethers";
import { AyHbarVault, makeWallet, showAssets, type NetworkConfig } from "../src/index.js";
import { loadConfig, GAS, DECIMALS, gasPriceWei } from "../src/config.js";
import { ERC20_ABI } from "../src/abi.js";
import type { Erc20Contract } from "../src/types.js";

/** Passed as the buy venue to mint the asset back through staking. */
const STAKE_ROUTE = (1n << 256n) - 1n;

const cfg: NetworkConfig = loadConfig();
const interval = Number(process.env.INTERVAL_SECONDS ?? 60);
const minProfitBps = BigInt(process.env.MIN_PROFIT_BPS ?? 5);
const maxTradeBps = BigInt(process.env.MAX_TRADE_BPS ?? 5000);
const execute = process.env.EXECUTE === "1";
const once = process.env.ONCE === "1";

const key = process.env.CURATOR_KEY;
if (execute && !key) {
  console.error("EXECUTE=1 needs CURATOR_KEY — arbitrage is a curator call.");
  process.exit(1);
}
const wallet = key ? makeWallet(key, cfg) : undefined;

/**
 * The address routes are simulated as. It must be the curator or the owner,
 * and it must be an account that exists on Hedera: the relay refuses to
 * simulate for a sender it has never seen.
 */
const curator = wallet?.address ?? process.env.CURATOR_ADDRESS;
if (!curator) {
  console.error("Set CURATOR_ADDRESS to watch, or CURATOR_KEY to watch and send.");
  process.exit(1);
}

// Reads and simulations go through a plain provider. A signer-backed contract
// attaches `from` to every eth_call, and Hedera rejects calls from an account
// it does not know.
const reader = AyHbarVault.readOnly(cfg);
const sender = wallet ? new AyHbarVault(wallet, cfg) : undefined;

interface Route {
  sell: bigint;
  buy: bigint;
  label: string;
}

interface Candidate extends Route {
  amountIn: bigint;
  profit: bigint;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const stamp = () => new Date().toISOString().replace("T", " ").slice(0, 19);

/** Read the venues the vault will route through. */
async function venues(): Promise<{ index: bigint; pair: string; feeNum: bigint; kind: bigint }[]> {
  const out: { index: bigint; pair: string; feeNum: bigint; kind: bigint }[] = [];
  for (let i = 0n; i < 8n; i++) {
    try {
      const [pair, feeNum, active, kind] = await reader.vault.venues(i);
      if (active) out.push({ index: i, pair, feeNum, kind });
    } catch {
      break; // past the end of the array
    }
  }
  return out;
}

/**
 * Every route that settles in one transaction: each ordered pair of venues,
 * plus selling on a venue and minting back through the staking protocol.
 */
function routes(registered: { index: bigint; kind: bigint }[]): Route[] {
  const name = (v: { index: bigint; kind: bigint }) =>
    `venue ${v.index}${v.kind === 1n ? " (cl)" : ""}`;
  const out: Route[] = [];
  for (const a of registered) {
    for (const b of registered) {
      if (a.index === b.index) continue;
      out.push({ sell: a.index, buy: b.index, label: `${name(a)} -> ${name(b)}` });
    }
    out.push({ sell: a.index, buy: STAKE_ROUTE, label: `${name(a)} -> staking` });
  }
  return out;
}

/** Trade sizes to try, as a fraction of what the vault has idle. */
function sizes(idle: bigint): bigint[] {
  const ladder = [25n, 50n, 100n, 250n, 500n, 1000n, 2500n, 5000n];
  const out = ladder
    .filter((bps) => bps <= maxTradeBps)
    .map((bps) => (idle * bps) / 10_000n)
    .filter((v) => v > 0n);
  return [...new Set(out)];
}

/**
 * Ask the chain what a route would return, without sending anything.
 *
 * A revert means the route is unavailable or unprofitable — the staking entry
 * being down, a pool too thin, the swap floor, or the end-with-more rule. All
 * of those are reasons to skip, not to report an error.
 */
async function simulate(route: Route, amountIn: bigint): Promise<bigint | null> {
  try {
    return await reader.vault.arbitrage.staticCall(route.sell, route.buy, amountIn, 0n, {
      from: curator,
    });
  } catch {
    return null;
  }
}

/** The most profitable route and size the vault can execute right now. */
async function best(idle: bigint): Promise<Candidate | null> {
  const registered = await venues();
  if (registered.length === 0) return null;

  let winner: Candidate | null = null;
  for (const route of routes(registered)) {
    for (const amountIn of sizes(idle)) {
      const profit = await simulate(route, amountIn);
      if (profit === null || profit === 0n) continue;
      if (profit * 10_000n < amountIn * minProfitBps) continue; // below the floor
      if (!winner || profit > winner.profit) winner = { ...route, amountIn, profit };
    }
  }
  return winner;
}

async function pass(): Promise<void> {
  const asset = new Contract(cfg.hbarx, ERC20_ABI, reader.vault.runner) as unknown as Erc20Contract;
  const idle = await asset.balanceOf(cfg.vault);
  const registered = await venues();

  if (idle === 0n) {
    console.log(`${stamp()}  vault holds nothing to trade with`);
    return;
  }
  if (registered.length === 0) {
    console.log(`${stamp()}  no venues registered`);
    return;
  }

  const candidate = await best(idle);
  const routeCount = routes(registered).length * sizes(idle).length;

  if (!candidate) {
    console.log(
      `${stamp()}  no profitable route  ` +
        `(${routeCount} checked, ${registered.length} venue${registered.length === 1 ? "" : "s"}, ` +
        `idle ${showAssets(idle)} HBARX)`,
    );
    return;
  }

  const gainBps = (candidate.profit * 10_000n) / candidate.amountIn;
  console.log(
    `${stamp()}  ${candidate.label}  ` +
      `in ${showAssets(candidate.amountIn)} -> profit ${showAssets(candidate.profit)} HBARX (${gainBps} bps)`,
  );

  if (!execute) {
    console.log("          not sent — set EXECUTE=1 to act on it");
    return;
  }

  // The floor passed to the contract is what was simulated, so a route that
  // decays between simulation and execution reverts rather than settling worse.
  const tx = await sender!.vault.arbitrage(
    candidate.sell,
    candidate.buy,
    candidate.amountIn,
    candidate.profit,
    { type: 0, gasPrice: await gasPriceWei(wallet), gasLimit: GAS.deposit },
  );
  const receipt = await tx.wait();
  const ok = receipt?.status === 1;
  console.log(
    `          ${ok ? "settled" : "FAILED"}  ${cfg.explorer}/transaction/${tx.hash}` +
      `  gas ${receipt?.gasUsed ?? "?"}`,
  );

  if (ok) {
    const [ta, ts] = await Promise.all([reader.vault.totalAssets(), reader.vault.totalSupply()]);
    console.log(
      `          vault now ${showAssets(ta)} HBARX, ` +
        `share price ${formatUnits((ta * 10n ** 18n) / (ts / 10n ** BigInt(DECIMALS.share - DECIMALS.asset)), 8)}`,
    );
  }
}

async function main(): Promise<void> {
  console.log(`ayHBAR arbitrage keeper`);
  console.log(`  vault     ${cfg.vault}`);
  console.log(`  curator   ${curator}${wallet ? "" : "  (watching only, no key)"}`);
  console.log(`  mode      ${execute ? "EXECUTING" : "watching only"}`);
  console.log(`  threshold ${minProfitBps} bps, max trade ${maxTradeBps} bps of idle`);
  console.log(`  interval  ${once ? "single pass" : `${interval}s`}\n`);

  for (;;) {
    try {
      await pass();
    } catch (err) {
      console.error(`${stamp()}  pass failed:`, (err as Error).message);
    }
    if (once) return;
    await sleep(interval * 1000);
  }
}

await main();
