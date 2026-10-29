#!/usr/bin/env bash
# Deposit HBAR and/or HBARX into the vault from the signing account.
#
# Usage:
#   NETWORK=mainnet ./script/deposit.sh                  5 HBAR and 5 HBARX
#   AMOUNT_HBAR=10 AMOUNT_HBARX=0 ./script/deposit.sh    HBAR only
#   AMOUNT_HBAR=0 AMOUNT_HBARX=2.5 ./script/deposit.sh   HBARX only
#
# The amounts are AMOUNT_HBAR and AMOUNT_HBARX, not HBAR and HBARX: those two
# names commonly hold token addresses in an operator's shell.
#
# Requires PRIVATE_KEY. VAULT defaults to deployments/vault_<network>.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
NETWORK=${NETWORK:-testnet}
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
IN_HBAR=${AMOUNT_HBAR:-5}
IN_ASSET=${AMOUNT_HBARX:-5}

# Amounts are decimal numbers. Checked here because a stray address or unit
# suffix would otherwise surface as an arithmetic error halfway through.
for pair in "AMOUNT_HBAR=$IN_HBAR" "AMOUNT_HBARX=$IN_ASSET"; do
  case "${pair#*=}" in
    ''|*[!0-9.]*|*.*.*) echo "$pair is not a decimal amount" >&2; exit 1 ;;
  esac
done

J=addresses.json
g(){ python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['$1']['evm'])"; }
RPC=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['rpc'])")
EXP=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['explorer'])")
VAULT=${VAULT:-$(cat "deployments/vault_${NETWORK}.txt")}
ASSET=$(g hbarx)
ME=$(cast wallet address --private-key "$PRIVATE_KEY")

# Read the gas price and pay over it: the network minimum moves, and a price
# under it is rejected with INSUFFICIENT_TX_FEE - which costs nothing but still
# advances the relay's cached nonce, so the next send fails with WRONG_NONCE.
GP=$(cast gas-price --rpc-url "$RPC" 2>/dev/null || echo "")
case "$GP" in ''|*[!0-9]*) GP=1300000000000 ;; *) GP=$(python3 -c "print(int($GP*12//10))") ;; esac
TX="--legacy --gas-price $GP"
# 900000 covers any single HTS token movement; an undersized limit is charged
# in full when the call runs out of gas.
GAS=900000

send(){
  local i out
  for i in 1 2 3 4 5; do
    if out=$(cast send "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $TX --gas-limit $GAS 2>&1); then
      case "$out" in
        *"status               1"*) printf '%s\n' "$out" | awk '/^transactionHash/{print "    tx " $2}'; sleep 4; return 0 ;;
        *) echo "    reverted on chain:" >&2; printf '%s\n' "$out" | grep -E '^(status|transactionHash)' >&2; return 1 ;;
      esac
    fi
    case "$out" in
      # The relay's view of the account disagrees with consensus. Nothing was
      # charged and the cache resyncs within seconds.
      *"Nonce too low"*|*"nonce too low"*|*WRONG_NONCE*) sleep 8 ;;
      *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
  done
  echo "still failing after retries" >&2; return 1
}

# A read can fail rather than return zero: querying an HTS balance for an
# account that does not exist on Hedera, or is not associated with the token,
# reverts. Report that as zero and let the preflight say what is wrong.
num(){
  local out
  out=$(cast call "$1" "$2" ${3:+$3} --rpc-url "$RPC" 2>/dev/null) || { echo 0; return 0; }
  printf '%s\n' "$out" | awk '{print $1}'
}

RATE=$(num "$VAULT" "assetPriceInWhbar()(uint256)")
if [ "$RATE" = "0" ]; then
  echo "the vault will not price itself: assetPriceInWhbar() did not answer." >&2
  echo "check oracle() and staking() are set and that the two sources agree." >&2
  exit 1
fi
CAP=$(num "$VAULT" "depositCap()(uint256)")
TA=$(num "$VAULT" "totalAssets()(uint256)")
BAL_HBAR=$(cast balance "$ME" --rpc-url "$RPC")
BAL_ASSET=$(num "$ASSET" "balanceOf(address)(uint256)" "$ME")
SHARES_BEFORE=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME")

read -r WEI RAW_HBAR MIN RAW_ASSET <<EOF
$(python3 - "$IN_HBAR" "$IN_ASSET" "$RATE" << 'PY'
import sys
hbar, hbarx, rate = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
tinybar = int(round(hbar * 1e8))
# --value is weibar (18 dp); msg.value reaches the contract in tinybar (8 dp).
# The floor is 1% under the vault's own anchored rate, so a pushed pool or the
# trade's own price impact cannot fill the deposit worse than that.
floor = tinybar * 10**8 // rate * 99 // 100 if rate else 0
print(tinybar * 10**10, tinybar, floor, int(round(hbarx * 1e8)))
PY
)
EOF

echo "network     $NETWORK"
echo "vault       $VAULT"
echo "depositor   $ME"
python3 - "$BAL_HBAR" "$BAL_ASSET" "$RATE" "$CAP" "$TA" "$RAW_HBAR" "$RAW_ASSET" "$GP" "$GAS" << 'PY'
import sys
b,a,rate,cap,ta,rh,ra,gp,gas = (int(x) for x in sys.argv[1:10])
res = gas*gp
print(f"balance     {b/1e18:,.2f} HBAR, {a/1e8:,.4f} HBARX")
print(f"rate        {rate/1e8:.6f} WHBAR per HBARX")
print(f"cap         {ta/1e8:,.2f} / {cap/1e8:,.2f} HBARX used")
print(f"depositing  {rh/1e8:g} HBAR and {ra/1e8:g} HBARX")
sends = (1 if rh else 0) + (2 if ra else 0)
need = rh*10**10 + res*max(sends,1)
if rh and rh*10**10 + res > b:
    sys.exit(f"not enough HBAR: {rh/1e8:g} plus {res/1e18:,.2f} reserved for gas exceeds {b/1e18:,.2f}")
if ra and a == 0:
    sys.exit("no HBARX balance readable for this account - associate the token first, "
             "or set HBARX=0 to deposit HBAR only")
if ra > a:
    sys.exit(f"not enough HBARX: want {ra/1e8:g}, hold {a/1e8:,.4f}")
if ta + rh*10**8//rate + ra > cap:
    sys.exit("deposit would exceed the cap")
if need > b:
    print(f"warning: {need/1e18:,.2f} HBAR needed including gas, {b/1e18:,.2f} held")
PY
echo

if [ "$RAW_HBAR" -gt 0 ]; then
  echo "==> depositing $IN_HBAR HBAR (floor $MIN HBARX)"
  send "$VAULT" "depositHBAR(address,uint256)" "$ME" "$MIN" --value "$WEI"
fi

if [ "$RAW_ASSET" -gt 0 ]; then
  echo "==> approving $IN_ASSET HBARX"
  send "$ASSET" "approve(address,uint256)" "$VAULT" "$RAW_ASSET"
  echo "==> depositing $IN_ASSET HBARX"
  send "$VAULT" "deposit(uint256,address)" "$RAW_ASSET" "$ME"
fi

echo
SHARES_AFTER=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME")
python3 - "$SHARES_BEFORE" "$SHARES_AFTER" "$(num "$VAULT" 'totalAssets()(uint256)')" \
         "$(num "$VAULT" 'convertToAssets(uint256)(uint256)' "$SHARES_AFTER")" << 'PY'
import sys
before, after, ta, worth = (int(x) for x in sys.argv[1:5])
print(f"shares      {before/1e14:,.6f} -> {after/1e14:,.6f} ayHBAR  (+{(after-before)/1e14:,.6f})")
print(f"worth       {worth/1e8:,.4f} HBARX")
print(f"vault       {ta/1e8:,.4f} HBARX total")
PY
echo "explorer    $EXP/address/$VAULT"
