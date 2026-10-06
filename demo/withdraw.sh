#!/usr/bin/env bash
# Withdraw a HBARX amount.   usage: ./withdraw.sh 0.05
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
AMT_HUMAN=${1:?usage: ./withdraw.sh <amount in HBARX, e.g. 0.05>}
AMT=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e8))" "$AMT_HUMAN")

MAXW=$(cast call $VAULT "maxWithdraw(address)(uint256)" $ME --rpc-url $RPC | num)
[ "$MAXW" -lt "$AMT" ] && { echo "can withdraw at most $(fmt8 $MAXW) HBARX"; exit 1; }

echo "withdrawing $AMT_HUMAN HBARX..."
OUT=$(cast send $VAULT "withdraw(uint256,address,address)" $AMT $ME $ME \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 3000000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  HBARX now:  $(fmt8 "$(cast call $HBARX 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)")"
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBARX"
