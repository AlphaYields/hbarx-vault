/**
 * Deposit HBARX already held in the wallet. Approves first when needed.
 *
 *   PRIVATE_KEY=0x... npm run deposit-hbarx -- 10
 *   PRIVATE_KEY=0x... npm run deposit-hbarx -- all
 */
import { toAssets } from "../src/index.js";
import { amountOrAll, connect, fmt, report } from "./_common.js";

const { vault, me } = connect();
const p0 = await vault.position(me);
const amount = amountOrAll(process.argv[2], p0.hbarxBalance, toAssets);

if (amount <= 0n || amount > p0.hbarxBalance) {
  console.error(`wallet holds ${fmt.assets(p0.hbarxBalance)} HBARX`);
  process.exit(1);
}
const state = await vault.state();
if (!state.associated) {
  console.error("the vault has not run associate() yet — deposits will revert");
  process.exit(1);
}
const headroom = await vault.vault.maxDeposit(me);
if (amount > headroom) {
  console.error(`over the deposit cap — at most ${fmt.assets(headroom)} HBARX can go in`);
  process.exit(1);
}

console.log(`depositing ${fmt.assets(amount)} HBARX`);
const { approve, deposit } = await vault.depositHbarx(amount, { receiver: me, owner: me });
if (approve) report("approve", approve);
report("deposit", deposit);

const p = await vault.position(me);
console.log(`  shares now ${fmt.shares(p.shares)} (worth ${fmt.assets(p.shareValue)} HBARX)`);
