import { getAddress } from "ethers";

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
  vault: "0x226E4AeC419F92e819AEd5E8b38EfbcA56FF3Fe9",
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
  /** 114 tinybar per gas, expressed in weibar. The relay rejects lower. */
  priceWei: 1_140_000_000_000n,
  approveHts: 900_000n,
  deposit: 900_000n,
  withdraw: 900_000n,
  adminCall: 400_000n,
};

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
