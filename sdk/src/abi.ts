/** The parts of the vault a front end needs. Human-readable ABI, for ethers v6. */
export const VAULT_ABI = [
  // identity and accounting
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function decimals() view returns (uint8)",
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function pricePerShare() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function previewWithdraw(uint256 assets) view returns (uint256)",
  "function liquidAssets() view returns (uint256)",

  // limits and state
  "function maxDeposit(address) view returns (uint256)",
  "function maxRedeem(address) view returns (uint256)",
  "function maxWithdraw(address) view returns (uint256)",
  "function depositCap() view returns (uint256)",
  "function withdrawTimelock() view returns (uint64)",
  "function paused() view returns (bool)",
  "function associated() view returns (bool)",
  "function performanceFee() view returns (uint16)",
  "function managementFee() view returns (uint16)",
  "function feeRecipient() view returns (address)",
  "function maxSlippageBps() view returns (uint16)",
  "function owner() view returns (address)",
  "function guardian() view returns (address)",
  "function curator() view returns (address)",
  "function staking() view returns (address)",
  "function oracle() view returns (address)",

  // conversion quotes
  "function quoteWhbarToAsset(uint256 tinybar) view returns (uint256)",

  // deposits
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function depositHBAR(address receiver, uint256 minAssetsOut) payable returns (uint256)",

  // withdrawal queue
  "function requestWithdraw(uint256 shares)",
  "function cancelWithdrawRequest()",
  "function withdrawableAt(address owner) view returns (uint256 shares, uint64 unlockAt)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",

  // events a UI may want to follow
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
  "event DepositedHBAR(address indexed caller, address indexed receiver, uint256 hbarIn, uint256 assets, uint256 shares)",
  "event WithdrawRequested(address indexed owner, uint256 shares, uint64 unlockAt)",
  "event WithdrawRequestCancelled(address indexed owner, uint256 shares)",
  "event FeesAccrued(uint256 performanceAssets, uint256 managementAssets, uint256 sharesMinted)",

  // custom errors, so ethers can decode a revert into a name
  "error NotAuthorized()",
  "error CapExceeded()",
  "error NoMaturedRequest()",
  "error TimelockNotElapsed()",
  "error InvalidParam()",
] as const;

/** HBARX behaves as an ERC-20 through Hedera's token facade. */
export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 value) returns (bool)",
  "function decimals() view returns (uint8)",
] as const;

/** Stader, when the vault is configured to stake rather than swap. */
export const STAKING_ABI = ["function getExchangeRate() view returns (uint256)"] as const;
