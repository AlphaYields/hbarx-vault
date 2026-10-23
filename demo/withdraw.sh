#!/usr/bin/env bash
# Withdraw a HBARX amount from a matured request.   usage: ./withdraw.sh 0.05
#
# While the vault has a withdrawal timelock, the flow is
#   ./request-withdraw.sh <shares>   ->  wait out the timelock  ->  ./withdraw.sh <assets>
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
AMT_HUMAN=${1:?usage: ./withdraw.sh <amount in HBARX, e.g. 0.05>}
AMT=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e8))" "$AMT_HUMAN")

MAXW=$(cast call $VAULT "maxWithdraw(address)(uint256)" $ME --rpc-url $RPC | num)
if [ "$MAXW" -lt "$AMT" ]; then
  echo "can withdraw at most $(fmt8 $MAXW) HBARX right now"
  read -r S U <<<"$(cast call $VAULT 'withdrawableAt(address)(uint256,uint64)' $ME --rpc-url $RPC | tr '\n' ' ' | sed 's/\[[^]]*\]//g')"
  if [ "${S:-0}" = "0" ]; then
    echo "  no request queued — run ./request-withdraw.sh first"
  elif [ "$MAXW" = "0" ]; then
    echo "  $(fmt14 "$S") ayHBAR queued, claimable at $(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC'))" "$U")"
  fi
  exit 1
fi

echo "withdrawing $AMT_HUMAN HBARX..."
OUT=$(cast send $VAULT "withdraw(uint256,address,address)" $AMT $ME $ME \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 900000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  HBARX now:  $(fmt8 "$(cast call $HBARX 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)")"
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBAR"
