#!/usr/bin/env bash
# Queue shares for withdrawal.   usage: ./request-withdraw.sh 0.05 | ./request-withdraw.sh all
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
ARG=${1:?usage: ./request-withdraw.sh <all | share amount>}
HELD=$(cast call $VAULT "balanceOf(address)(uint256)" $ME --rpc-url $RPC | num)
if [ "$ARG" = "all" ]; then SHARES=$HELD
else SHARES=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e14))" "$ARG"); fi
[ "$SHARES" = "0" ] && { echo "no shares held"; exit 1; }

echo "requesting withdrawal of $(fmt14 $SHARES) ayHBAR..."
OUT=$(cast send $VAULT "requestWithdraw(uint256)" $SHARES \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 900000)
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$(echo "$OUT"|awk '/^transactionHash/{print $2}')"
sleep 3
read -r S U <<<"$(cast call $VAULT 'withdrawableAt(address)(uint256,uint64)' $ME --rpc-url $RPC | tr '\n' ' ' | sed 's/\[[^]]*\]//g')"
echo "  queued  : $(fmt14 "$S") ayHBAR"
echo "  claimable at: $(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.UTC).strftime('%Y-%m-%d %H:%M UTC'))" "$U")"
