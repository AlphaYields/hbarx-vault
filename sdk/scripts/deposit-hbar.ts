/**
 * Deposit native HBAR. The vault converts it to HBARX itself.
 *
 *   PRIVATE_KEY=0x... npm run deposit-hbar -- 100
 *   PRIVATE_KEY=0x... SLIPPAGE_BPS=200 npm run deposit-hbar -- 100
 */
import { toHbar } from "../src/index.js";
import { connect, fmt, report } from "./_common.js";

const { vault, me, cfg } = connect();
const arg = process.argv[2];
if (!arg) {
  console.error("usage: npm run deposit-hbar -- <amount in HBAR>");
  process.exit(1);
}
const slippageBps = BigInt(process.env.SLIPPAGE_BPS ?? 100);

const state = await vault.state();
if (!state.associated) {
  console.error("the vault has not run associate() yet — deposits will revert");
  process.exit(1);
}
if (state.paused) {
  console.error("the vault is paused — deposits are halted");
  process.exit(1);
}

const quote = await vault.quoteHbarDeposit(toHbar(arg), slippageBps);
console.log(`depositing ${arg} HBAR via the ${quote.route} route`);
console.log(`  expected   ${fmt.assets(quote.expectedAssets)} HBARX`);
console.log(`  floor      ${fmt.assets(quote.minAssetsOut)} HBARX (${slippageBps} bps below)`);

const r = await vault.depositHbar(quote.hbarIn, { receiver: me, slippageBps });
report("deposit", r);

const p = await vault.position(me);
console.log(`  shares now ${fmt.shares(p.shares)} (worth ${fmt.assets(p.shareValue)} HBARX)`);
console.log(`  vault      ${cfg.explorer}/contract/${cfg.vault}`);
