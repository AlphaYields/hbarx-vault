/**
 * Vault and wallet state.
 *
 *   npm run status                          vault only
 *   PRIVATE_KEY=0x... npm run status        vault plus that wallet
 *   ADDRESS=0x... npm run status            vault plus any address, no key
 */
import { AyHbarVault, makeWallet, showBps, showPrice, showTime } from "../src/index.js";
import { loadConfig } from "../src/config.js";
import { fmt } from "./_common.js";

const cfg = loadConfig();
const key = process.env.PRIVATE_KEY;
const me = process.env.ADDRESS ?? (key ? makeWallet(key, cfg).address : undefined);
const vault = AyHbarVault.readOnly(cfg);

const s = await vault.state();
console.log(`vault ${cfg.vault}`);
console.log(`  ${cfg.explorer}/contract/${cfg.vault}\n`);
console.log(`  share token      ${s.symbol}, ${s.shareDecimals} decimals`);
console.log(`  total assets     ${fmt.assets(s.totalAssets)} HBARX`);
console.log(`  total supply     ${fmt.shares(s.totalSupply)} ${s.symbol}`);
console.log(`  share price      ${showPrice(s.pricePerShare)} HBARX per share`);
console.log(`  deposit cap      ${fmt.assets(s.depositCap)} HBARX`);
console.log(`  withdraw delay   ${s.withdrawTimelock} s`);
console.log(`  performance fee  ${showBps(s.performanceFeeBps)}`);
console.log(`  management fee   ${showBps(s.managementFeeBps)}`);
console.log(`  slippage limit   ${showBps(s.maxSlippageBps)}`);
console.log(`  paused           ${s.paused}`);
console.log(`  associated       ${s.associated}${s.associated ? "" : "   <- deposits revert until this is true"}`);
console.log(`  HBAR route       ${s.staking === "0x0000000000000000000000000000000000000000" ? "pool swap" : `staking via ${s.staking}`}`);
console.log(`\n  owner            ${s.owner}`);
console.log(`  guardian         ${s.guardian}`);
console.log(`  curator          ${s.curator}`);
console.log(`  fee recipient    ${s.feeRecipient}`);

if (me) {
  const p = await vault.position(me);
  console.log(`\nwallet ${me}`);
  if (!p.accountExists) {
    console.log("  no Hedera account yet — send it some HBAR and it will be created");
  }
  console.log(`  HBAR             ${fmt.hbar(p.hbarBalance)}`);
  console.log(`  HBARX            ${fmt.assets(p.hbarxBalance)}`);
  console.log(`  shares           ${fmt.shares(p.shares)} ${s.symbol}  (worth ${fmt.assets(p.shareValue)} HBARX)`);
  if (p.queuedShares > 0n) {
    console.log(`  queued           ${fmt.shares(p.queuedShares)} ${s.symbol}, claimable from ${showTime(p.unlockAt)}`);
  }
  console.log(`  claimable now    ${fmt.shares(p.maxRedeem)} shares = ${fmt.assets(p.maxWithdraw)} HBARX`);

  const recv = await vault.canReceiveHbarx(me);
  console.log(`  can receive HBARX ${recv.ok ? "yes" : "NO"} — ${recv.reason}`);
}
