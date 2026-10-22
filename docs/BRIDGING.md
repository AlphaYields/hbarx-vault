# Getting funds onto Hedera

The vault accepts **HBAR** or **HBARX**, both native to Hedera. Funds held elsewhere need to
reach a Hedera account first.

## Routes

| Route | Good for | Notes |
|---|---|---|
| **Centralised exchange** | Most users, any size | Buy HBAR, withdraw to your Hedera address. Usually the cheapest and quickest path; HBAR is widely listed. |
| **HashPort bridge** | Moving existing assets from Ethereum, BNB Chain, Polygon, Avalanche, Optimism | The official Hedera bridge: [hashport.network](https://www.hashport.network). Bridge USDC or another supported asset, then swap to HBAR on-chain. |
| **Already on Hedera** | — | Nothing to do; deposit directly. |

## Addresses

A Hedera account has two forms: the native ID (`0.0.123456`) and a 20-byte EVM address
(`0x…`). The vault is an EVM contract and works with EVM addresses, which is what wallets such
as MetaMask show. HashPack and Blade show both.

Withdrawing from a centralised exchange usually asks for the `0.0.x` form. Both refer to the
same account.

## Token association

Hedera requires an account to associate a token before it can receive it. This matters in two
places:

- To hold **HBARX**, associate `0.0.834116` (mainnet).
- To receive **ayHBAR** shares, no association is needed — the share token is a standard
  ERC-20 contract rather than a native Hedera token.

Wallets expose this as "Add token" or "Associate token". Native HBAR never needs association.

## Depositing

Once HBAR is in your account:

```solidity
// deposit HBAR directly — converted to HBARX inside the vault
vault.depositHBAR{value: amount}(receiver, minAssetsOut);
```

Or acquire HBARX first (by staking with Stader, or swapping on SaucerSwap) and deposit it:

```solidity
hbarx.approve(vault, amount);
vault.deposit(assets, receiver);
```

Keep a small HBAR balance for transaction fees — a few HBAR is ample.

## Connecting a wallet

| | Mainnet | Testnet |
|---|---|---|
| Network name | Hedera Mainnet | Hedera Testnet |
| RPC URL | `https://mainnet.hashio.io/api` | `https://testnet.hashio.io/api` |
| Chain ID | 295 | 296 |
| Currency | HBAR | HBAR |
| Explorer | `https://hashscan.io/mainnet` | `https://hashscan.io/testnet` |

Testnet HBAR is free from the [Hedera portal faucet](https://portal.hedera.com/faucet).
