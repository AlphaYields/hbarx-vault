#!/usr/bin/env bash
# Redeem shares. Pass "all" to exit fully.   usage: ./redeem.sh all | ./redeem.sh 0.05
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
ARG=${1:?usage: ./redeem.sh <all | share amount, e.g. 0.05>}

HELD=$(cast call $VAULT "balanceOf(address)(uint256)" $ME --rpc-url $RPC | num)
if [ "$ARG" = "all" ]; then SHARES=$HELD
else SHARES=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e14))" "$ARG"); fi
[ "$SHARES" = "0" ] && { echo "no shares held"; exit 1; }

echo "redeeming $(fmt14 $SHARES) ayHBARX..."
OUT=$(cast send $VAULT "redeem(uint256,address,address)" $SHARES $ME $ME \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 3000000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  HBARX now:  $(fmt8 "$(cast call $HBARX 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)")"
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBARX"
