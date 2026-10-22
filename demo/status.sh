#!/usr/bin/env bash
# Show wallet and vault state.
set -euo pipefail
cd "$(dirname "$0")"; source ./config.sh

echo "wallet $ME"
echo "  HBAR   $(python3 -c "import sys;print(f'{int(sys.argv[1])/1e18:.4f}')" "$(cast balance $ME --rpc-url $RPC)")"
echo "  HBARX  $(fmt8 "$(cast call $HBARX 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)")"
echo "  shares $(fmt14 "$(cast call $VAULT 'balanceOf(address)(uint256)' $ME --rpc-url $RPC | num)") ayHBAR"
echo
echo "vault $VAULT"
echo "  totalAssets  $(fmt8 "$(cast call $VAULT 'totalAssets()(uint256)' --rpc-url $RPC | num)") HBARX"
echo "  totalSupply  $(fmt14 "$(cast call $VAULT 'totalSupply()(uint256)' --rpc-url $RPC | num)") ayHBAR"
# Share price: what one whole share (1e14 units) is worth in HBARX (1e8 units).
# Starts at 1.00000000 and rises as the strategy earns.
PPS=$(cast call $VAULT "convertToAssets(uint256)(uint256)" 100000000000000 --rpc-url $RPC | num)
echo "  share price  $(fmt8 "$PPS") HBARX per ayHBAR"
echo "  paused       $(cast call $VAULT 'paused()(bool)' --rpc-url $RPC)"
echo "  timelock     $(cast call $VAULT 'withdrawTimelock()(uint64)' --rpc-url $RPC | num) s"
echo "  deposit cap  $(fmt8 "$(cast call $VAULT 'depositCap()(uint256)' --rpc-url $RPC | num)") HBARX"
REQ=$(cast call $VAULT "withdrawableAt(address)(uint256,uint64)" $ME --rpc-url $RPC | head -1 | num)
[ "$REQ" != "0" ] && echo "  your request $(fmt14 "$REQ") ayHBAR queued"
echo
echo "  $EXPLORER/contract/0.0.11131621"
