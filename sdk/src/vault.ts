import {
  Contract,
  JsonRpcProvider,
  Wallet,
  formatUnits,
  parseUnits,
  ZeroAddress,
  type ContractTransactionReceipt,
  type Provider,
  type Signer,
} from "ethers";
import { ERC20_ABI, STAKING_ABI, VAULT_ABI } from "./abi.js";
import type { Erc20Contract, StakingContract, VaultContract } from "./types.js";
import { DECIMALS, DEFAULT_SLIPPAGE_BPS, GAS, loadConfig, type NetworkConfig } from "./config.js";

/* ──────────────────────────────────────────────────────────── amount helpers */

/** "1.5" -> 150000000n (HBARX and every assets amount, 8 dp). */
export const toAssets = (human: string | number) => parseUnits(String(human), DECIMALS.asset);
/** "1.5" -> 150000000000000n (ayHBAR shares, 14 dp). */
export const toShares = (human: string | number) => parseUnits(String(human), DECIMALS.share);
/** "1.5" -> 1500000000000000000n (native HBAR at the EVM layer, 18 dp). */
export const toHbar = (human: string | number) => parseUnits(String(human), DECIMALS.hbar);

export const fromAssets = (raw: bigint) => formatUnits(raw, DECIMALS.asset);
export const fromShares = (raw: bigint) => formatUnits(raw, DECIMALS.share);
export const fromHbar = (raw: bigint) => formatUnits(raw, DECIMALS.hbar);

/**
 * Hedera settles value in tinybar (1e-8 HBAR), so a weibar amount carrying
 * anything finer is truncated by the network. Round down explicitly rather than
 * letting the relay surprise you.
 */
export const roundToTinybar = (weibar: bigint) => (weibar / 10_000_000_000n) * 10_000_000_000n;

/* ─────────────────────────────────────────────────────────────── connections */

/**
 * A provider configured the way Hedera's relay needs: no request batching, and
 * a fixed network so ethers stops re-checking the chain id on every call.
 */
export function makeProvider(cfg: NetworkConfig = loadConfig()): JsonRpcProvider {
  return new JsonRpcProvider(cfg.rpcUrl, cfg.chainId, {
    staticNetwork: true,
    batchMaxCount: 1,
  });
}

/** A signer from a raw private key, for desktop scripts. */
export function makeWallet(privateKey: string, cfg: NetworkConfig = loadConfig()): Wallet {
  const key = privateKey.startsWith("0x") ? privateKey : `0x${privateKey}`;
  return new Wallet(key, makeProvider(cfg));
}

/* ───────────────────────────────────────────────────────────────── the types */

export interface VaultState {
  symbol: string;
  shareDecimals: number;
  assetDecimals: number;
  totalAssets: bigint;
  totalSupply: bigint;
  /** Assets per whole share, scaled by 1e8. 100000000 means 1.00000000. */
  pricePerShare: bigint;
  depositCap: bigint;
  /** Seconds. 0 means withdrawals need no request and are immediate. */
  withdrawTimelock: bigint;
  paused: boolean;
  /** False means the vault cannot hold its tokens yet and deposits revert. */
  associated: boolean;
  performanceFeeBps: number;
  managementFeeBps: number;
  maxSlippageBps: number;
  owner: string;
  guardian: string;
  curator: string;
  feeRecipient: string;
  /** Zero address means HBAR deposits convert through the pool, not Stader. */
  staking: string;
}

export interface Position {
  /** Shares held in the wallet, transferable. */
  shares: bigint;
  /** What those shares are worth in HBARX right now. */
  shareValue: bigint;
  /** Shares sitting in the withdrawal queue. Still earning. */
  queuedShares: bigint;
  /** Unix seconds from which the queued shares can be claimed. */
  unlockAt: number;
  /** True once the queue has matured. */
  claimable: boolean;
  /** Shares claimable this instant, after timelock, pause and liquidity. */
  maxRedeem: bigint;
  /** Assets claimable this instant. */
  maxWithdraw: bigint;
  /** HBARX in the wallet. */
  hbarxBalance: bigint;
  /** Native HBAR in the wallet, in weibar. */
  hbarBalance: bigint;
  /**
   * False when the address has no Hedera account yet. An EVM address only
   * becomes an account once something funds it, and the HBARX facade reverts
   * for an address that does not exist — so a UI should treat this as "new
   * user, needs HBAR first" rather than as an error.
   */
  accountExists: boolean;
}

export interface Quote {
  /** Which conversion the vault will perform. */
  route: "stader" | "pool";
  /** HBAR going in, in weibar. */
  hbarIn: bigint;
  /** HBARX expected out, raw. */
  expectedAssets: bigint;
  /** The floor to pass as minAssetsOut. */
  minAssetsOut: bigint;
  slippageBps: bigint;
}

export interface TxResult {
  hash: string;
  url: string;
  status: "success" | "failed";
  gasUsed: bigint;
  receipt: ContractTransactionReceipt;
}

/* ───────────────────────────────────────────────────────────────── the client */

export class AyHbarVault {
  readonly cfg: NetworkConfig;
  readonly vault: VaultContract;
  readonly hbarx: Erc20Contract;
  private readonly runner: Provider | Signer;

  constructor(runner: Provider | Signer, cfg: NetworkConfig = loadConfig()) {
    this.cfg = cfg;
    this.runner = runner;
    this.vault = new Contract(cfg.vault, VAULT_ABI, runner) as unknown as VaultContract;
    this.hbarx = new Contract(cfg.hbarx, ERC20_ABI, runner) as unknown as Erc20Contract;
  }

  /** Convenience: a client backed by a private key, ready to send. */
  static fromPrivateKey(privateKey: string, cfg: NetworkConfig = loadConfig()): AyHbarVault {
    return new AyHbarVault(makeWallet(privateKey, cfg), cfg);
  }

  /** Read-only client, no key needed. */
  static readOnly(cfg: NetworkConfig = loadConfig()): AyHbarVault {
    return new AyHbarVault(makeProvider(cfg), cfg);
  }

  private link(hash: string) {
    return `${this.cfg.explorer}/transaction/${hash}`;
  }

  /** Hedera needs legacy (type 0) transactions with an explicit gas limit. */
  private txOpts(gasLimit: bigint, value?: bigint) {
    return { type: 0, gasPrice: GAS.priceWei, gasLimit, ...(value === undefined ? {} : { value }) };
  }

  private async settle(tx: { hash: string; wait: () => Promise<ContractTransactionReceipt | null> }): Promise<TxResult> {
    const receipt = await tx.wait();
    if (!receipt) throw new Error(`no receipt for ${tx.hash} — check ${this.link(tx.hash)}`);
    return {
      hash: receipt.hash,
      url: this.link(receipt.hash),
      // The relay returns a receipt for reverted calls too, so always read this.
      status: receipt.status === 1 ? "success" : "failed",
      gasUsed: receipt.gasUsed,
      receipt,
    };
  }

  /* ─────────────────────────────────────────────────────────────────── reads */

  async state(): Promise<VaultState> {
    const v = this.vault;
    const [
      symbol, shareDecimals, totalAssets, totalSupply, pricePerShare, depositCap,
      withdrawTimelock, paused, associated, performanceFee, managementFee,
      maxSlippageBps, owner, guardian, curator, feeRecipient, staking,
    ] = await Promise.all([
      v.symbol(), v.decimals(), v.totalAssets(), v.totalSupply(), v.pricePerShare(),
      v.depositCap(), v.withdrawTimelock(), v.paused(), v.associated(), v.performanceFee(),
      v.managementFee(), v.maxSlippageBps(), v.owner(), v.guardian(), v.curator(),
      v.feeRecipient(), v.staking(),
    ]);
    return {
      symbol, shareDecimals: Number(shareDecimals), assetDecimals: DECIMALS.asset,
      totalAssets, totalSupply, pricePerShare, depositCap,
      withdrawTimelock, paused, associated,
      performanceFeeBps: Number(performanceFee), managementFeeBps: Number(managementFee),
      maxSlippageBps: Number(maxSlippageBps),
      owner, guardian, curator, feeRecipient, staking,
    };
  }

  async position(who: string): Promise<Position> {
    const provider = "provider" in this.runner ? this.runner.provider : this.runner;
    if (!provider) throw new Error("no provider attached");
    const [shares, queued, maxRedeem, maxWithdraw, hbarxBalance, hbarBalance] = await Promise.all([
      this.vault.balanceOf(who),
      this.vault.withdrawableAt(who),
      this.vault.maxRedeem(who),
      this.vault.maxWithdraw(who),
      // Reverts when the address has no Hedera account yet; that is a state, not a fault.
      this.hbarx.balanceOf(who).catch(() => null),
      provider.getBalance(who),
    ]);
    const [queuedShares, unlockAt] = queued;
    const shareValue = shares > 0n ? await this.vault.convertToAssets(shares) : 0n;
    return {
      shares,
      shareValue,
      queuedShares,
      unlockAt: Number(unlockAt),
      claimable: queuedShares > 0n && Date.now() / 1000 >= Number(unlockAt),
      maxRedeem,
      maxWithdraw,
      hbarxBalance: hbarxBalance ?? 0n,
      hbarBalance,
      accountExists: hbarxBalance !== null || hbarBalance > 0n,
    };
  }

  /**
   * What a given amount of HBAR converts to, by whichever route the vault is
   * configured for. Use `minAssetsOut` from the result when depositing.
   */
  async quoteHbarDeposit(hbarWeibar: bigint, slippageBps = DEFAULT_SLIPPAGE_BPS): Promise<Quote> {
    const hbarIn = roundToTinybar(hbarWeibar);
    const tinybar = hbarIn / 10_000_000_000n;
    const staking = await this.vault.staking();

    let expectedAssets: bigint;
    let route: Quote["route"];
    if (staking !== ZeroAddress) {
      // Stader pays the protocol rate: HBARX out = tinybar / rate, rate is 1e8-scaled.
      const stader = new Contract(staking, STAKING_ABI, this.runner) as unknown as StakingContract;
      const rate = await stader.getExchangeRate();
      expectedAssets = (tinybar * 100_000_000n) / rate;
      route = "stader";
    } else {
      expectedAssets = await this.vault.quoteWhbarToAsset(tinybar);
      route = "pool";
    }
    return {
      route,
      hbarIn,
      expectedAssets,
      minAssetsOut: (expectedAssets * (10_000n - slippageBps)) / 10_000n,
      slippageBps,
    };
  }

  /**
   * Whether an account can receive HBARX. Hedera requires a token to be
   * associated before it can be held, and withdrawals pay in HBARX — so check
   * this before offering a withdrawal in a UI. Answered by the mirror node,
   * which is free and needs no gas.
   */
  async canReceiveHbarx(who: string): Promise<{ ok: boolean; reason: string }> {
    const res = await fetch(`${this.cfg.mirrorUrl}/api/v1/accounts/${who}`);
    if (!res.ok) {
      return { ok: false, reason: `no Hedera account for ${who} yet — it needs funding first` };
    }
    const acct = (await res.json()) as {
      account?: string;
      max_automatic_token_associations?: number;
    };
    const slots = acct.max_automatic_token_associations ?? 0;
    if (slots === -1) return { ok: true, reason: "unlimited automatic association" };

    const rel = await fetch(
      `${this.cfg.mirrorUrl}/api/v1/accounts/${who}/tokens?token.id=${this.cfg.hbarxTokenId}`,
    );
    const body = (await rel.json()) as { tokens?: unknown[] };
    const tokens = body.tokens ?? [];
    if (tokens.length > 0) return { ok: true, reason: "HBARX already associated" };
    if (slots > 0) return { ok: true, reason: `${slots} automatic association slots free` };
    return {
      ok: false,
      reason: `HBARX (${this.cfg.hbarxTokenId}) is not associated and there are no automatic slots — associate it in the wallet first`,
    };
  }

  /* ────────────────────────────────────────────────────────────────── writes */

  /** Deposit native HBAR. The vault converts it to HBARX itself. */
  async depositHbar(
    hbarWeibar: bigint,
    opts: { receiver: string; slippageBps?: bigint; minAssetsOut?: bigint },
  ): Promise<TxResult & { quote: Quote }> {
    const quote = await this.quoteHbarDeposit(hbarWeibar, opts.slippageBps ?? DEFAULT_SLIPPAGE_BPS);
    const floor = opts.minAssetsOut ?? quote.minAssetsOut;
    const tx = await this.vault.depositHBAR(
      opts.receiver,
      floor,
      this.txOpts(GAS.deposit, quote.hbarIn),
    );
    return { ...(await this.settle(tx)), quote };
  }

  /**
   * Deposit HBARX. Sends the approve first when the allowance is short, and
   * approves exactly the deposit so nothing is left standing afterwards.
   */
  async depositHbarx(
    assets: bigint,
    opts: { receiver: string; owner: string },
  ): Promise<{ approve?: TxResult; deposit: TxResult }> {
    const allowance = await this.hbarx.allowance(opts.owner, this.cfg.vault);
    let approve: TxResult | undefined;
    if (allowance < assets) {
      // Never approve uint256 max: Hedera's token service rejects very large values.
      const tx = await this.hbarx.approve(this.cfg.vault, assets, this.txOpts(GAS.approveHts));
      approve = await this.settle(tx);
      if (approve.status !== "success") return { approve, deposit: approve };
      await sleep(4000); // the relay lags the mined nonce
    }
    const tx = await this.vault.deposit(assets, opts.receiver, this.txOpts(GAS.deposit));
    return { approve, deposit: await this.settle(tx) };
  }

  /** Queue shares for withdrawal. Required whenever the timelock is non-zero. */
  async requestWithdraw(shares: bigint): Promise<TxResult> {
    const tx = await this.vault.requestWithdraw(shares, this.txOpts(GAS.withdraw));
    return this.settle(tx);
  }

  /** Take queued shares back out of the queue. Allowed any time before a claim. */
  async cancelWithdrawRequest(): Promise<TxResult> {
    const tx = await this.vault.cancelWithdrawRequest(this.txOpts(GAS.withdraw));
    return this.settle(tx);
  }

  /** Claim a matured request by share count. */
  async redeem(shares: bigint, receiver: string, owner: string): Promise<TxResult> {
    const tx = await this.vault.redeem(shares, receiver, owner, this.txOpts(GAS.withdraw));
    return this.settle(tx);
  }

  /** Claim a matured request by asset amount. */
  async withdraw(assets: bigint, receiver: string, owner: string): Promise<TxResult> {
    const tx = await this.vault.withdraw(assets, receiver, owner, this.txOpts(GAS.withdraw));
    return this.settle(tx);
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
