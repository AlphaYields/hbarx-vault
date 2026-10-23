/**
 * Queue shares for withdrawal. Step one of two whenever the vault has a
 * timelock; `claim` is step two.
 *
 *   PRIVATE_KEY=0x... npm run request-withdraw -- 10
 *   PRIVATE_KEY=0x... npm run request-withdraw -- all
 */
import { showTime, toShares } from "../src/index.js";
import { amountOrAll, connect, fmt, report } from "./_common.js";

const { vault, me } = connect();
const p0 = await vault.position(me);
const shares = amountOrAll(process.argv[2], p0.shares, toShares);

if (shares <= 0n || shares > p0.shares) {
  console.error(`wallet holds ${fmt.shares(p0.shares)} shares`);
  process.exit(1);
}

const state = await vault.state();
console.log(`queueing ${fmt.shares(shares)} shares (worth ${fmt.assets(await vault.vault.convertToAssets(shares))} HBARX)`);
if (state.withdrawTimelock === 0n) {
  console.log("  note: the timelock is 0, so redeem and withdraw also work without a request");
}

report("requestWithdraw", await vault.requestWithdraw(shares));

const p = await vault.position(me);
console.log(`  queued      ${fmt.shares(p.queuedShares)} shares`);
console.log(`  claimable   ${showTime(p.unlockAt)}`);
console.log(`  then run    npm run claim -- all`);
