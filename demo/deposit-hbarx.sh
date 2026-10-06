#!/usr/bin/env bash
# Deposit HBARX.   usage: ./deposit-hbarx.sh 0.1
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
AMT_HUMAN=${1:?usage: ./deposit-hbarx.sh <amount in HBARX, e.g. 0.1>}
AMT=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e8))" "$AMT_HUMAN")

BAL=$(cast call $HBARX "balanceOf(address)(uint256)" $ME --rpc-url $RPC | num)
[ "$BAL" -lt "$AMT" ] && { echo "not enough HBARX: have $(fmt8 $BAL), need $AMT_HUMAN"; exit 1; }

echo "approving $AMT_HUMAN HBARX..."
cast send $HBARX "approve(address,uint256)" $VAULT $AMT \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 900000 >/dev/null
# The Hedera relay lags behind the mined nonce; give it a moment or the next
# send fails with "Nonce too low".
sleep 4

echo "depositing..."
OUT=$(cast send $VAULT "deposit(uint256,address)" $AMT $ME \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 3000000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBARX"
