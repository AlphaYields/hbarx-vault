import { getAddress, type Provider, type Signer } from "ethers";

/**
 * Everything you may need to change lives in this file.
 *
 * Each value can also be overridden with an environment variable of the same
 * name, so the scripts run against another deployment without editing code:
 *
 *   VAULT=0x... RPC_URL=https://testnet.hashio.io/api npm run status
 */

export interface NetworkConfig {
  /** JSON-RPC relay endpoint. */
  rpcUrl: string;
  /** 295 = Hedera mainnet, 296 = testnet. */
  chainId: number;
  /** Mirror node REST base, used for token-association checks. */
  mirrorUrl: string;
  /** HashScan base, used to build links. */
  explorer: string;
  /** The ayHBAR vault. */
  vault: string;
  /** HBARX, the vault's underlying asset. */
  hbarx: string;
  /** HBARX token id in Hedera form, for association prompts in a wallet. */
  hbarxTokenId: string;
}

export const MAINNET: NetworkConfig = {
  rpcUrl: "https://mainnet.hashio.io/api",
  chainId: 295,
  mirrorUrl: "https://mainnet.mirrornode.hedera.com",
  explorer: "https://hashscan.io/mainnet",
  vault: "0x33ad9057C2e17Fa5b4Abc119606c9CEC97ed85Db",
  hbarx: "0x00000000000000000000000000000000000cbA44",
  hbarxTokenId: "0.0.834116",
};

export const TESTNET: NetworkConfig = {
  rpcUrl: "https://testnet.hashio.io/api",
  chainId: 296,
  mirrorUrl: "https://testnet.mirrornode.hedera.com",
  explorer: "https://hashscan.io/testnet",
  vault: "0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e",
  hbarx: "0x0000000000000000000000000000000000220cED",
  hbarxTokenId: "0.0.2231533",
};

/**
 * Gas settings. Hedera's relay reserves gasLimit x gasPrice from the sender's
 * balance before execution, and charges the whole limit when a call runs out of
 * gas — so these are set from measured usage with headroom, not guessed.
 *
 * Measured on mainnet: HTS approve 783k, HBAR deposit via the pool 275k,
 * HBARX deposit 165k, requestWithdraw 124k, redeem 169k, accrueFees 111k.
 * The vault's own setters are all under 100k.
 */
export const GAS = {
  approveHts: 900_000n,
  deposit: 900_000n,
  withdraw: 900_000n,
  adminCall: 400_000n,
};

/**
 * Gas price.
 *
 * The relay enforces a minimum and that minimum moves — it went from 114 to
 * 116 tinybar per gas within a day, and anything below it is rejected outright
 * with "Gas price '...' is below configured minimum". Worse, the rejection
 * costs nothing but still advances the relay's cached nonce, so the *next*
 * send fails with WRONG_NONCE even though it is correct.
 *
 * So the price is never hardcoded: it is read from the relay with eth_gasPrice
 * and padded, which absorbs a rise between the read and the send. The relay
 * only reserves gasLimit x gasPrice and refunds what is not used, so paying
 * over the minimum costs nothing but a larger reservation.
 */

/** Padding over the relay's reported minimum, in percent. */
export const GAS_PRICE_PADDING_PCT = 20n;

/** Used only when the relay will not answer. Above every minimum seen so far. */
export const GAS_PRICE_FALLBACK_WEI = 1_400_000_000_000n;

/** How long a reading stays fresh. Short, because the minimum can move. */
const GAS_PRICE_TTL_MS = 30_000;

let cachedGasPrice: { wei: bigint; at: number } | undefined;

/** Discard the cached reading. Mainly for tests. */
export function resetGasPriceCache(): void {
  cachedGasPrice = undefined;
}

/**
 * The gas price to send with, read from the relay and padded.
 *
 * Cached briefly so a multi-transaction script does not re-query per send.
 * Accepts a signer or a provider; falls back to the constant above if neither
 * can answer, so a transient relay failure does not block a send.
 */
export async function gasPriceWei(
  source: Provider | Signer | null | undefined,
  now: number = Date.now(),
): Promise<bigint> {
  if (cachedGasPrice && now - cachedGasPrice.at < GAS_PRICE_TTL_MS) return cachedGasPrice.wei;

  let wei = GAS_PRICE_FALLBACK_WEI;
  const provider = source && "provider" in source ? source.provider : (source as Provider | null);
  if (provider) {
    try {
      const { gasPrice } = await provider.getFeeData();
      if (gasPrice && gasPrice > 0n) wei = (gasPrice * (100n + GAS_PRICE_PADDING_PCT)) / 100n;
    } catch {
      // Keep the fallback: a relay that will not quote is no reason not to send.
    }
  }
  cachedGasPrice = { wei, at: now };
  return wei;
}

/** Decimals, fixed by the contract. */
export const DECIMALS = {
  /** HBARX, and therefore every "assets" amount. */
  asset: 8,
  /** ayHBAR shares: 8 from the asset plus a 6-decimal virtual offset. */
  share: 14,
  /** Native HBAR at the EVM layer. */
  hbar: 18,
};

/** Default slippage allowance for the HBAR -> HBARX conversion, in bps. */
export const DEFAULT_SLIPPAGE_BPS = 100n;

/**
 * Resolve a network, honouring environment overrides.
 *
 * Addresses are normalised to EIP-55 on the way through. Hedera tooling and
 * HashScan print addresses in several different casings, and ethers rejects a
 * mixed-case address whose checksum does not match — so normalise rather than
 * trusting what was pasted in.
 */
export function loadConfig(env: Record<string, string | undefined> = process.env): NetworkConfig {
  const base = (env.NETWORK ?? "mainnet").toLowerCase() === "testnet" ? TESTNET : MAINNET;
  return {
    ...base,
    rpcUrl: env.RPC_URL ?? base.rpcUrl,
    vault: getAddress((env.VAULT ?? base.vault).toLowerCase()),
    hbarx: getAddress((env.HBARX ?? base.hbarx).toLowerCase()),
  };
}
