#!/usr/bin/env bash
# Exercise every vault feature against a live testnet deployment and print a
# PASS/FAIL line per check. Testnet tool: it pauses and unpauses the vault,
# moves the deposit cap and briefly shortens the withdrawal timelock, restoring
# each setting afterwards. Never point it at mainnet.
#
#   export OWNER_KEY=0x... GUARDIAN_KEY=0x... CURATOR_KEY=0x...
#   export VAULT=0x...                      # defaults to deployments/vault_testnet.txt
#   CONFIRM=yes ./script/validate-testnet.sh
#
# The owner account needs about 8 HBAR for gas and ~0.15 HBARX to deposit; the
# guardian and curator accounts need about 1 HBAR each. Hedera's relay reserves
# gasLimit x gasPrice up front, so a balance below that reserve is refused even
# when the transaction itself would be cheap.
set -uo pipefail
cd "$(dirname "$0")/.."
[ "${CONFIRM:-}" = "yes" ] || { echo "This mutates vault settings. Re-run with CONFIRM=yes."; exit 1; }
: "${OWNER_KEY:?set OWNER_KEY}"; : "${GUARDIAN_KEY:?set GUARDIAN_KEY}"; : "${CURATOR_KEY:?set CURATOR_KEY}"

J=addresses.json
RPC=$(python3 -c "import json;print(json.load(open('$J'))['testnet']['rpc'])")
HBARX=$(python3 -c "import json;print(json.load(open('$J'))['testnet']['hbarx']['evm'])")
V=${VAULT:-$(cat deployments/vault_testnet.txt)}
ME=$(cast wallet address --private-key "$OWNER_KEY")
TX="--legacy --gas-price 1140000000000"
PASS=0; FAIL=0
GAS=400000                     # comfortably above the heaviest call (~273k)
num(){ awk '{print $1}'; }
call(){ cast call "$V" "$@" --rpc-url "$RPC" | num; }
pass(){ echo "  PASS  $1${2:+  $2}"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL  $1${2:+  $2}"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "(got $2, want $3)"; fi; }
# Run a send; echo "ok <hash>", "revert", or "error ...". Hedera's relay returns
# success for a reverted transaction, so the receipt status is what counts.
run(){ local key=$1; shift; local o
  o=$(cast send "$V" "$@" --rpc-url "$RPC" --private-key "$key" $TX --gas-limit $GAS 2>&1)
  if   echo "$o" | grep -qE "^status +1"; then echo "ok $(echo "$o" | awk '/^transactionHash/{print $2}')"
  elif echo "$o" | grep -qE "^status +0"; then echo "revert"
  else echo "error $(echo "$o" | tr '\n' ' ' | cut -c1-100)"; fi
  sleep 3; }
want_ok(){  local l=$1; shift; local r; r=$(run "$@"); case "$r" in ok*) pass "$l" "${r#ok }";; *) fail "$l" "($r)";; esac; }
want_rev(){ local l=$1; shift; local r; r=$(run "$@"); case "$r" in revert) pass "$l";; ok*) fail "$l" "(succeeded)";; *) fail "$l" "($r)";; esac; }

# However this run ends, put the withdrawal timelock back where it was.
TL0=$(cast call "$V" 'withdrawTimelock()(uint64)' --rpc-url "$RPC" | num)
restore(){ local now; now=$(cast call "$V" 'withdrawTimelock()(uint64)' --rpc-url "$RPC" | num)
  if [ "$now" != "$TL0" ]; then echo "  restoring the withdrawal timelock to $TL0 s"
    cast send "$V" "setWithdrawTimelock(uint64)" "$TL0" --rpc-url "$RPC" --private-key "$OWNER_KEY" $TX --gas-limit $GAS >/dev/null 2>&1
  fi; }
trap restore EXIT

echo "vault $V"
echo "=== configuration ==="
check "share token is ayHBAR" "$(cast call "$V" 'symbol()(string)' --rpc-url "$RPC")" '"ayHBAR"'
check "14 decimals"           "$(call 'decimals()(uint8)')"        14
check "performance fee 20%"   "$(call 'performanceFee()(uint16)')" 2000
check "management fee 0%"     "$(call 'managementFee()(uint16)')"  0
check "withdrawal timelock 1 day" "$(call 'withdrawTimelock()(uint64)')" 86400
check "operating slippage limit 1%" "$(call 'maxSlippageBps()(uint16)')" 100
check "running, not paused"   "$(call 'paused()(bool)')"           false
CAP=$(call 'depositCap()(uint256)')
[ "$CAP" != "0" ] && [ "$CAP" != "$(python3 -c 'print(2**256-1)')" ] && pass "deposit cap set" "($CAP)" || fail "deposit cap" "($CAP)"

echo "=== deposits ==="
cast send "$HBARX" "approve(address,uint256)" "$V" 100000000000000000 --rpc-url "$RPC" --private-key "$OWNER_KEY" $TX --gas-limit $GAS >/dev/null 2>&1; sleep 3
want_ok "deposit 0.1 HBARX" "$OWNER_KEY" "deposit(uint256,address)" 10000000 "$ME"
Q=$(call "quoteWhbarToAsset(uint256)(uint256)" 100000000)
want_ok "deposit 1 native HBAR" "$OWNER_KEY" "depositHBAR(address,uint256)" "$ME" "$((Q*95/100))" --value 1000000000000000000
echo "  share price now $(call 'pricePerShare()(uint256)'), assets $(call 'totalAssets()(uint256)')"

echo "=== withdrawal queue ==="
SH=$(call "balanceOf(address)(uint256)" "$ME")
want_rev "redeem without a request is rejected" "$OWNER_KEY" "redeem(uint256,address,address)" 100000000000 "$ME" "$ME"
want_ok  "queue a withdrawal"                   "$OWNER_KEY" "requestWithdraw(uint256)" 100000000000
check "shares escrowed out of the holder's balance" "$(call "balanceOf(address)(uint256)" "$ME")" "$((SH-100000000000))"
check "queued shares stay in totalSupply and keep earning" "$(call 'totalSupply()(uint256)')" "$SH"
want_rev "redeem before the timelock elapses is rejected" "$OWNER_KEY" "redeem(uint256,address,address)" 100000000000 "$ME" "$ME"
want_ok  "cancel the request"                             "$OWNER_KEY" "cancelWithdrawRequest()"
check "cancelled shares returned in full" "$(call "balanceOf(address)(uint256)" "$ME")" "$SH"

echo "=== roles ==="
want_rev "curator cannot change fees"         "$CURATOR_KEY"  "setFees(uint16,uint16,address)" 500 0 "$ME"
want_rev "guardian cannot change fees"        "$GUARDIAN_KEY" "setFees(uint16,uint16,address)" 500 0 "$ME"
want_rev "curator cannot change the timelock" "$CURATOR_KEY"  "setWithdrawTimelock(uint64)" 0
want_rev "guardian cannot unpause"            "$GUARDIAN_KEY" "unpause()"
want_ok  "curator can set the deposit cap"    "$CURATOR_KEY"  "setDepositCap(uint256)" "$CAP"

echo "=== bounds ==="
want_rev "performance fee above 50% is rejected" "$OWNER_KEY" "setFees(uint16,uint16,address)" 5001 0 "$ME"
want_rev "management fee above 5% is rejected"   "$OWNER_KEY" "setFees(uint16,uint16,address)" 2000 501 "$ME"
want_rev "timelock above 30 days is rejected"    "$OWNER_KEY" "setWithdrawTimelock(uint64)" 2592001
want_rev "slippage limit above 5% is rejected"   "$OWNER_KEY" "setMaxSlippageBps(uint16)" 501

echo "=== depositor funds are out of reach ==="
for t in "$HBARX" \
         "$(python3 -c "import json;print(json.load(open('$J'))['testnet']['aToken']['evm'])")" \
         "$(python3 -c "import json;print(json.load(open('$J'))['testnet']['debtToken']['evm'])")" \
         "$(python3 -c "import json;print(json.load(open('$J'))['testnet']['whbarToken']['evm'])")"; do
  want_rev "sweep rejects $t" "$OWNER_KEY" "sweep(address,address,uint256)" "$t" "$ME" 1
done

echo "=== pause halts both directions ==="
want_ok  "guardian can pause"                   "$GUARDIAN_KEY" "pause()"
check "vault reports paused" "$(call 'paused()(bool)')" true
want_rev "deposits rejected while paused"       "$OWNER_KEY" "deposit(uint256,address)" 1000000 "$ME"
want_rev "redemptions rejected while paused"    "$OWNER_KEY" "redeem(uint256,address,address)" 1000000000 "$ME" "$ME"
want_rev "withdrawals rejected while paused"    "$OWNER_KEY" "withdraw(uint256,address,address)" 1000000 "$ME" "$ME"
check "maxDeposit reports 0 while paused" "$(call "maxDeposit(address)(uint256)" "$ME")" 0
check "maxRedeem reports 0 while paused"  "$(call "maxRedeem(address)(uint256)" "$ME")" 0
want_ok  "guardian can still unwind leverage while paused" "$GUARDIAN_KEY" "deleverage(uint8,uint256,uint16)" 1 1000000 100
want_ok  "owner can unpause"                    "$OWNER_KEY" "unpause()"
check "vault reports running again" "$(call 'paused()(bool)')" false

echo "=== performance fee ==="
FR=$(cast call "$V" 'feeRecipient()(address)' --rpc-url "$RPC")
TA0=$(call 'totalAssets()(uint256)'); PPS0=$(call 'pricePerShare()(uint256)'); FS0=$(call "balanceOf(address)(uint256)" "$FR")
cast send "$HBARX" "transfer(address,uint256)" "$V" 2000000 --rpc-url "$RPC" --private-key "$OWNER_KEY" $TX --gas-limit $GAS >/dev/null 2>&1; sleep 4
want_ok "accrueFees mints the fee as shares" "$OWNER_KEY" "accrueFees()"
TA1=$(call 'totalAssets()(uint256)'); PPS1=$(call 'pricePerShare()(uint256)'); FS1=$(call "balanceOf(address)(uint256)" "$FR")
FEE=$(call "convertToAssets(uint256)(uint256)" "$((FS1-FS0))")
R=$(python3 -c "
g=$TA1-$TA0; f=$FEE; p=f/g*100 if g else 0
print('ok' if 19.5<=p<=20.5 else 'no', f'{f} of {g} raw = {p:.2f}% of the gain')")
[ "${R%% *}" = "ok" ] && pass "performance fee is 20% of the gain" "(${R#* })" || fail "performance fee" "(${R#* })"
[ "$PPS1" -gt "$PPS0" ] && pass "share price rose for depositors" "($PPS0 -> $PPS1)" || fail "share price did not rise"

echo "=== a matured request can be claimed ==="
want_ok "shorten the timelock to 60 s for this check" "$OWNER_KEY" "setWithdrawTimelock(uint64)" 60
want_ok "queue 0.1 ayHBAR"                            "$OWNER_KEY" "requestWithdraw(uint256)" 10000000000000
U=$(cast call "$V" "withdrawableAt(address)(uint256,uint64)" "$ME" --rpc-url "$RPC" | tail -1 | num)
echo "  waiting out the timelock..."
while [ "$(date -u +%s)" -lt "$((U+5))" ]; do sleep 5; done
B0=$(cast call "$HBARX" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | num)
want_ok "redeem half the matured request" "$OWNER_KEY" "redeem(uint256,address,address)" 5000000000000 "$ME" "$ME"
B1=$(cast call "$HBARX" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | num)
[ "$((B1-B0))" -gt 0 ] && pass "HBARX paid out on redeem" "($((B1-B0)) raw)" || fail "nothing received on redeem"
W=$(call "maxWithdraw(address)(uint256)" "$ME")
want_ok "withdraw the rest by asset amount" "$OWNER_KEY" "withdraw(uint256,address,address)" "$W" "$ME" "$ME"
B2=$(cast call "$HBARX" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | num)
check "withdraw paid exactly the amount asked" "$((B2-B1))" "$W"
want_ok "restore the original timelock" "$OWNER_KEY" "setWithdrawTimelock(uint64)" "$TL0"
LEFT=$(cast call "$V" "withdrawableAt(address)(uint256,uint64)" "$ME" --rpc-url "$RPC" | head -1 | num)
[ "$LEFT" != "0" ] && want_ok "clear the rounding remainder from the queue" "$OWNER_KEY" "cancelWithdrawRequest()"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
