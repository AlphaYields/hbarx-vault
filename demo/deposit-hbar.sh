#!/usr/bin/env bash
# Deposit native HBAR. It is converted to HBARX inside the vault.
#   usage: ./deposit-hbar.sh 1
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh
AMT_HUMAN=${1:?usage: ./deposit-hbar.sh <amount in HBAR, e.g. 1>}
WEI=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e18))" "$AMT_HUMAN")
TINY=$(python3 -c "import sys;print(int(float(sys.argv[1])*1e8))" "$AMT_HUMAN")

# Quote the conversion and allow 5% slippage.
EXPECTED=$(cast call $VAULT "quoteWhbarToAsset(uint256)(uint256)" $TINY --rpc-url $RPC | num)
MINOUT=$(python3 -c "import sys;print(int(int(sys.argv[1])*0.95))" "$EXPECTED")
echo "depositing $AMT_HUMAN HBAR"
echo "  expected $(fmt8 $EXPECTED) HBARX, min accepted $(fmt8 $MINOUT) (5% slippage)"

OUT=$(cast send $VAULT "depositHBAR(address,uint256)" $ME $MINOUT --value $WEI \
  --rpc-url $RPC --private-key $PRIVATE_KEY $TXFLAGS --gas-limit 3500000)
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}')
echo "$OUT" | awk '/^status/{print "  status:",$2,$3}'
echo "  tx: $EXPLORER/transaction/$TX"
sleep 3
echo "  shares now: $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBARX"
