#!/usr/bin/env bash
# Take queued shares back out of the withdrawal queue.
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
OUT=$(cast send $VAULT "cancelWithdrawRequest()" \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 900000)
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$(echo "$OUT"|awk '/^transactionHash/{print $2}')"
sleep 3
echo "  shares returned: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBAR"
