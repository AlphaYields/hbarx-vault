import { DECIMALS } from "./config.js";

/**
 * Exact fixed-point formatting. ethers' formatUnits drops trailing zeros, which
 * makes a share price of 1.00000000 print as "1.0" — fine for maths, poor for a
 * UI. This keeps every place, and never goes through a float, so it stays exact
 * at any size.
 */
export function fixed(raw: bigint, decimals: number, places = decimals): string {
  const negative = raw < 0n;
  const value = negative ? -raw : raw;
  const base = 10n ** BigInt(decimals);
  const whole = value / base;
  const rest = (value % base).toString().padStart(decimals, "0");
  const frac = places <= decimals ? rest.slice(0, places) : rest.padEnd(places, "0");
  const sign = negative ? "-" : "";
  return places > 0 ? `${sign}${whole}.${frac}` : `${sign}${whole}`;
}

/** HBARX and every assets amount, to 8 places. */
export const showAssets = (raw: bigint) => fixed(raw, DECIMALS.asset, 8);
/** ayHBAR shares, to 8 places — the remaining 6 are the virtual offset. */
export const showShares = (raw: bigint) => fixed(raw, DECIMALS.share, 8);
/** Native HBAR, to 4 places. */
export const showHbar = (raw: bigint) => fixed(raw, DECIMALS.hbar, 4);
/** A share price, which the contract scales by 1e8. */
export const showPrice = (raw: bigint) => fixed(raw, DECIMALS.asset, 8);

/** Basis points as a percentage: 2000 -> "20%". */
export const showBps = (bps: number | bigint) => `${Number(bps) / 100}%`;

/** A unix timestamp as a readable UTC stamp. */
export const showTime = (unixSeconds: number) =>
  `${new Date(unixSeconds * 1000).toISOString().replace("T", " ").slice(0, 16)} UTC`;
