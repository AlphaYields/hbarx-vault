import type { Contract, ContractTransactionResponse, Overrides } from "ethers";

/**
 * Typed views of the two contracts. ethers builds its methods dynamically from
 * the ABI, so without these a call site gets `any | undefined` instead of real
 * types. Declaring them here means a front end gets completion and type errors
 * on every call.
 */
export interface VaultMethods {
  // identity and accounting
  symbol(): Promise<string>;
  name(): Promise<string>;
  decimals(): Promise<bigint>;
  asset(): Promise<string>;
  totalAssets(): Promise<bigint>;
  totalSupply(): Promise<bigint>;
  balanceOf(who: string): Promise<bigint>;
  pricePerShare(): Promise<bigint>;
  convertToAssets(shares: bigint): Promise<bigint>;
  convertToShares(assets: bigint): Promise<bigint>;
  previewDeposit(assets: bigint): Promise<bigint>;
  previewRedeem(shares: bigint): Promise<bigint>;
  previewWithdraw(assets: bigint): Promise<bigint>;

  // limits and state
  maxDeposit(who: string): Promise<bigint>;
  maxRedeem(who: string): Promise<bigint>;
  maxWithdraw(who: string): Promise<bigint>;
  depositCap(): Promise<bigint>;
  withdrawTimelock(): Promise<bigint>;
  paused(): Promise<boolean>;
  associated(): Promise<boolean>;
  performanceFee(): Promise<bigint>;
  managementFee(): Promise<bigint>;
  feeRecipient(): Promise<string>;
  maxSlippageBps(): Promise<bigint>;
  owner(): Promise<string>;
  guardian(): Promise<string>;
  curator(): Promise<string>;
  staking(): Promise<string>;
  oracle(): Promise<string>;
  assetPriceInWhbar(): Promise<bigint>;
  venues(i: bigint): Promise<[string, bigint, boolean, bigint]>;
  swapRouter(): Promise<string>;
  whbar(): Promise<string>;
  /** Carries ethers' `staticCall`, so a route can be simulated before it is sent. */
  arbitrage: {
    (sellVenue: bigint, buyVenue: bigint, amountIn: bigint, minProfit: bigint,
     o?: Overrides): Promise<ContractTransactionResponse>;
    staticCall(sellVenue: bigint, buyVenue: bigint, amountIn: bigint, minProfit: bigint,
               o?: Overrides): Promise<bigint>;
  };
  withdrawableAt(who: string): Promise<[bigint, bigint]>;

  // writes
  deposit(assets: bigint, receiver: string, o?: Overrides): Promise<ContractTransactionResponse>;
  depositHBAR(receiver: string, minAssetsOut: bigint, o?: Overrides): Promise<ContractTransactionResponse>;
  requestWithdraw(shares: bigint, o?: Overrides): Promise<ContractTransactionResponse>;
  cancelWithdrawRequest(o?: Overrides): Promise<ContractTransactionResponse>;
  redeem(shares: bigint, receiver: string, owner: string, o?: Overrides): Promise<ContractTransactionResponse>;
  withdraw(assets: bigint, receiver: string, owner: string, o?: Overrides): Promise<ContractTransactionResponse>;
}

export interface Erc20Methods {
  balanceOf(who: string): Promise<bigint>;
  allowance(owner: string, spender: string): Promise<bigint>;
  decimals(): Promise<bigint>;
  approve(spender: string, value: bigint, o?: Overrides): Promise<ContractTransactionResponse>;
}

export interface StakingMethods {
  getExchangeRate(): Promise<bigint>;
}

export type VaultContract = Contract & VaultMethods;
export type Erc20Contract = Contract & Erc20Methods;
export type StakingContract = Contract & StakingMethods;
