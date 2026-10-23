#!/usr/bin/env bash
# Set roles, fees, timelock and deposit cap. Run after deploy.sh.
# Requires: PRIVATE_KEY (owner), GUARDIAN, CURATOR addresses.
set -euo pipefail
cd "$(dirname "$0")/.."
NETWORK=${NETWORK:-testnet}
: "${PRIVATE_KEY:?set PRIVATE_KEY (owner)}"
: "${GUARDIAN:?set GUARDIAN address}"
: "${CURATOR:?set CURATOR address}"

J=addresses.json
RPC=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['rpc'])")
VAULT=$(cat "deployments/vault_${NETWORK}.txt")
TX="--legacy --gas-price 1140000000000"
# The relay lags the mined nonce, so consecutive sends need a gap or the next
# one is rejected with "Nonce too low". Retry on that, since it is transient.
send(){
  local i out
  for i in 1 2 3 4 5; do
    if out=$(cast send "$VAULT" "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $TX --gas-limit 900000 2>&1); then
      sleep 4; return 0
    fi
    case "$out" in
      *"Nonce too low"*|*"nonce too low"*) sleep 6 ;;
      *) echo "$out" >&2; return 1 ;;
    esac
  done
  echo "still failing after retries:" >&2; echo "$out" >&2; return 1
}

# Deposit cap: 10,000 USD equivalent, priced at run time.
# The HBARX/HBAR rate comes from the staking contract where one is configured
# (mainnet); testnet has no Stader deployment, so a constant stands in there.
STAKING=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['staking']['evm'])")
RATE=1.4356
if [ "$STAKING" != "0x0000000000000000000000000000000000000000" ]; then
  RAW=$(cast call "$STAKING" "getExchangeRate()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  RATE=$(python3 -c "import sys;print(int(sys.argv[1])/1e8)" "$RAW")
fi
echo "HBARX/HBAR rate: $RATE"
CAP=$(python3 -c "
import json,sys,urllib.request
p=json.load(urllib.request.urlopen('https://coins.llama.fi/prices/current/coingecko:hedera-hashgraph',timeout=30))['coins']
hbar=list(p.values())[0]['price']
print(int(10000/(hbar*float(sys.argv[1]))*1e8))" "$RATE")
echo "deposit cap: $CAP raw (= 10,000 USD at today's price)"

echo "==> guardian"; send "setGuardian(address)" "$GUARDIAN"
echo "==> curator";  send "setCurator(address)" "$CURATOR"
echo "==> fees";     send "setFees(uint16,uint16,address)" 2000 0 "$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "==> timelock"; send "setWithdrawTimelock(uint64)" 86400
echo "==> cap";      send "setDepositCap(uint256)" "$CAP"

echo
echo "guardian        $(cast call $VAULT 'guardian()(address)' --rpc-url $RPC)"
echo "curator         $(cast call $VAULT 'curator()(address)' --rpc-url $RPC)"
echo "performanceFee  $(cast call $VAULT 'performanceFee()(uint16)' --rpc-url $RPC) bps"
echo "managementFee   $(cast call $VAULT 'managementFee()(uint16)' --rpc-url $RPC) bps"
echo "withdrawTimelock $(cast call $VAULT 'withdrawTimelock()(uint64)' --rpc-url $RPC) s"
echo "depositCap      $(cast call $VAULT 'depositCap()(uint256)' --rpc-url $RPC)"
