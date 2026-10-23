import { AyHbarVault, makeWallet, showAssets, showHbar, showShares } from "../src/index.js";
import { loadConfig } from "../src/config.js";

/** Build a signing client from PRIVATE_KEY, and fail clearly when it is absent. */
export function connect() {
  const cfg = loadConfig();
  const key = process.env.PRIVATE_KEY;
  if (!key) {
    console.error("PRIVATE_KEY is not set.\n  export PRIVATE_KEY=0x...   then re-run");
    process.exit(1);
  }
  const wallet = makeWallet(key, cfg);
  return { cfg, wallet, me: wallet.address, vault: new AyHbarVault(wallet, cfg) };
}

export function readOnly() {
  const cfg = loadConfig();
  return { cfg, vault: AyHbarVault.readOnly(cfg) };
}

export const fmt = { assets: showAssets, shares: showShares, hbar: showHbar };

/** Print a transaction result and exit non-zero if the receipt says it failed. */
export function report(label: string, r: { hash: string; url: string; status: string; gasUsed: bigint }) {
  console.log(`  ${label}: ${r.status}  gas ${r.gasUsed}`);
  console.log(`  ${r.url}`);
  if (r.status !== "success") {
    console.error(`\n${label} did not succeed. Open the link above, or read the call trace:`);
    console.error(`  curl -s "<mirror>/api/v1/contracts/results/${r.hash}/actions"`);
    process.exit(1);
  }
}

/** Resolve "all" or a decimal string against a balance. */
export function amountOrAll(arg: string | undefined, all: bigint, parse: (s: string) => bigint): bigint {
  if (!arg) {
    console.error("missing amount — pass a number, or 'all'");
    process.exit(1);
  }
  return arg.toLowerCase() === "all" ? all : parse(arg);
}
