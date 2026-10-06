#!/usr/bin/env bash
# Hedera testnet configuration for the HbarxLoopVault demo.
# Everything below is public; the key is supplied via PRIVATE_KEY in the environment.
export RPC=${RPC:-https://testnet.hashio.io/api}
export VAULT=0x6f66561eFF738A77a58df5005FC6e76a71788524   # 0.0.10879010
export HBARX=0x0000000000000000000000000000000000220cED   # 0.0.2231533
export EXPLORER=https://hashscan.io/testnet

# Hedera needs legacy transactions; the relay rejects EIP-1559 fee fields.
export TXFLAGS="--legacy --gas-price 1140000000000"

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "PRIVATE_KEY is not set."
  echo "  export PRIVATE_KEY=0x...   then re-run"
  exit 1
fi
export ME=$(cast wallet address --private-key "$PRIVATE_KEY")

# Pretty-print an 8-decimal token amount.
fmt8() { python3 -c "import sys;print(f'{int(sys.argv[1])/1e8:.8f}')" "$1"; }
# Pretty-print a 14-decimal share amount.
fmt14() { python3 -c "import sys;print(f'{int(sys.argv[1])/1e14:.8f}')" "$1"; }
# Strip cast's trailing annotation, e.g. "123 [1.2e2]" -> "123"
num() { awk '{print $1}'; }
