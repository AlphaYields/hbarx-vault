#!/usr/bin/env bash
# Hedera testnet configuration for the ayHBAR vault demo.
# Everything below is public; the key is supplied via PRIVATE_KEY in the environment.
export RPC=${RPC:-https://testnet.hashio.io/api}
export VAULT=0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e   # 0.0.11131621
export HBARX=0x0000000000000000000000000000000000220cED   # 0.0.2231533
export EXPLORER=https://hashscan.io/testnet

# Hedera needs legacy transactions; the relay rejects EIP-1559 fee fields.
# The gas price comes from the relay and is padded, because the network minimum
# moves: a price under it is rejected with INSUFFICIENT_TX_FEE, which costs
# nothing but still advances the relay's cached nonce, so the next send then
# fails with WRONG_NONCE.
GASP=$(cast gas-price --rpc-url "$RPC" 2>/dev/null || true)
case "$GASP" in ''|*[!0-9]*) GASP=1300000000000 ;;
  *) GASP=$(python3 -c "print(int($GASP * 12 // 10))") ;;
esac
export TXFLAGS="--legacy --gas-price $GASP"

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
