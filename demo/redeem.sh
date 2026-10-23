#!/usr/bin/env bash
# Redeem matured shares. Pass "all" to redeem everything claimable.
#   usage: ./redeem.sh all | ./redeem.sh 0.05
#
# While the vault has a withdrawal timelock, the flow is
#   ./request-withdraw.sh <shares>   ->  wait out the timelock  ->  ./redeem.sh all
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
ARG=${1:?usage: ./redeem.sh <all | share amount, e.g. 0.05>}

CLAIMABLE=$(cast call $VAULT "maxRedeem(address)(uint256)" $ME --rpc-url $RPC | num)
if [ "$ARG" = "all" ]; then SHARES=$CLAIMABLE
else SHARES=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e14))" "$ARG"); fi

if [ "$SHARES" = "0" ] || [ "$CLAIMABLE" -lt "$SHARES" ]; then
  echo "claimable right now: $(fmt14 "$CLAIMABLE") ayHBAR"
  read -r S U <<<"$(cast call $VAULT 'withdrawableAt(address)(uint256,uint64)' $ME --rpc-url $RPC | tr '\n' ' ' | sed 's/\[[^]]*\]//g')"
  if [ "${S:-0}" = "0" ]; then
    echo "  no request queued — run ./request-withdraw.sh first"
  else
    echo "  $(fmt14 "$S") ayHBAR queued, claimable at $(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC'))" "$U")"
  fi
  exit 1
fi

echo "redeeming $(fmt14 $SHARES) ayHBAR..."
OUT=$(cast send $VAULT "redeem(uint256,address,address)" $SHARES $ME $ME \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 900000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  HBARX now:  $(fmt8 "$(cast call $HBARX 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)")"
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBAR"
