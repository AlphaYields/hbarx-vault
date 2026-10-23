/**
 * Claim a matured request and receive HBARX. Step two of two.
 *
 *   PRIVATE_KEY=0x... npm run claim -- all          (by share count)
 *   PRIVATE_KEY=0x... npm run claim -- 10           (10 shares)
 *   PRIVATE_KEY=0x... npm run claim -- 10 assets    (10 HBARX)
 */
import { showTime, toAssets, toShares } from "../src/index.js";
import { amountOrAll, connect, fmt, report } from "./_common.js";

const { vault, me } = connect();
const byAssets = (process.argv[3] ?? "").toLowerCase() === "assets";
const p0 = await vault.position(me);

if (p0.maxRedeem === 0n) {
  if (p0.queuedShares === 0n) {
    console.error("nothing queued — run `npm run request-withdraw -- all` first");
  } else {
    console.error(`${fmt.shares(p0.queuedShares)} shares are queued but mature at ${showTime(p0.unlockAt)}`);
  }
  process.exit(1);
}

const hbarx = await vault.canReceiveHbarx(me);
if (!hbarx.ok) {
  console.error(`this account cannot receive HBARX: ${hbarx.reason}`);
  process.exit(1);
}

if (byAssets) {
  const assets = amountOrAll(process.argv[2], p0.maxWithdraw, toAssets);
  if (assets > p0.maxWithdraw) {
    console.error(`at most ${fmt.assets(p0.maxWithdraw)} HBARX is claimable right now`);
    process.exit(1);
  }
  console.log(`withdrawing ${fmt.assets(assets)} HBARX`);
  report("withdraw", await vault.withdraw(assets, me, me));
} else {
  const shares = amountOrAll(process.argv[2], p0.maxRedeem, toShares);
  if (shares > p0.maxRedeem) {
    console.error(`at most ${fmt.shares(p0.maxRedeem)} shares are claimable right now`);
    process.exit(1);
  }
  console.log(`redeeming ${fmt.shares(shares)} shares`);
  report("redeem", await vault.redeem(shares, me, me));
}

const p = await vault.position(me);
console.log(`  HBARX now   ${fmt.assets(p.hbarxBalance)}`);
console.log(`  shares left ${fmt.shares(p.shares)}`);
if (p.queuedShares > 0n) console.log(`  still queued ${fmt.shares(p.queuedShares)}`);
