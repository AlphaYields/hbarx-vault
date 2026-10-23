/**
 * Take queued shares back out of the queue. Allowed any time before a claim.
 *
 *   PRIVATE_KEY=0x... npm run cancel-request
 */
import { connect, fmt, report } from "./_common.js";

const { vault, me } = connect();
const p0 = await vault.position(me);
if (p0.queuedShares === 0n) {
  console.log("nothing queued");
  process.exit(0);
}
console.log(`cancelling a request for ${fmt.shares(p0.queuedShares)} shares`);
report("cancelWithdrawRequest", await vault.cancelWithdrawRequest());

const p = await vault.position(me);
console.log(`  shares back in wallet: ${fmt.shares(p.shares)}`);
