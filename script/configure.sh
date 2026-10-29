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
# Gas price: read from the relay and padded, because the network minimum moves.
# A price under the current minimum is rejected with INSUFFICIENT_TX_FEE, and
# that rejection costs nothing but still advances the relay's cached nonce - so
# the next send fails with WRONG_NONCE. Paying over the minimum avoids both.
gas_price(){
  local p
  p=$(cast gas-price --rpc-url "$RPC" 2>/dev/null) || p=
  case "$p" in ''|*[!0-9]*) echo 1300000000000; return ;; esac
  python3 -c "print(int($p * 12 // 10))"
}
TX="--legacy --gas-price $(gas_price)"
# The relay lags the mined nonce, so consecutive sends need a gap or the next
# one is rejected with "Nonce too low". Retry on that, since it is transient.
# GAS is per-call: 900k covers anything that touches one HTS token, but an HTS
# approve alone costs about 783k, so a call making two of them needs more.
send(){
  local i out gas=${GAS:-900000}
  for i in 1 2 3 4 5; do
    if out=$(cast send "$VAULT" "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $TX --gas-limit "$gas" 2>&1); then
      sleep 4; return 0
    fi
    case "$out" in
      # All three mean the relay's view of the account disagrees with consensus.
      # Nothing was charged; the cache resyncs within a few seconds.
      *"Nonce too low"*|*"nonce too low"*|*WRONG_NONCE*) sleep 8 ;;
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

echo "==> roles";    send "setRoles(address,address)" "$GUARDIAN" "$CURATOR"
echo "==> fees";     send "setFees(uint16,uint16,address)" 2000 0 "$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "==> timelock"; send "setWithdrawTimelock(uint64)" 86400
echo "==> cap";      send "setDepositCap(uint256)" "$CAP"

# Strategy references and bounds: oracle, staking contract, 1% swap slippage,
# 1% oracle-agreement tolerance, health floor 1.4, permissionless unwind at 1.15.
ORACLE=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['oracle']['evm'])")
STAKE=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['staking']['evm'])")
echo "==> strategy"
send "configureStrategy(address,address,uint16,uint16,uint256,uint256)" \
     "$ORACLE" "$STAKE" 100 100 1400000000000000000 1150000000000000000

# Concentrated-liquidity venue. Registered where the network has one: the
# router has to be set first, because a concentrated venue is traded through it.
ROUTER=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK'].get('swapRouter',{}).get('evm',''))")
CLPAIR=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK'].get('concentratedPair',{}).get('evm',''))")
CLFEE=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK'].get('concentratedPair',{}).get('feeTier',0))")
if [ -n "$ROUTER" ] && [ -n "$CLPAIR" ]; then
  echo "==> swap router"; GAS=2000000 send "setSwapRouter(address)" "$ROUTER"
  echo "==> concentrated venue"
  if send "addVenue(address,uint16,uint8)" "$CLPAIR" "$CLFEE" 1; then :; else
    echo "    already registered, or rejected - continuing"
  fi
fi

echo
echo "guardian        $(cast call $VAULT 'guardian()(address)' --rpc-url $RPC)"
echo "curator         $(cast call $VAULT 'curator()(address)' --rpc-url $RPC)"
echo "performanceFee  $(cast call $VAULT 'performanceFee()(uint16)' --rpc-url $RPC) bps"
echo "managementFee   $(cast call $VAULT 'managementFee()(uint16)' --rpc-url $RPC) bps"
echo "withdrawTimelock $(cast call $VAULT 'withdrawTimelock()(uint64)' --rpc-url $RPC) s"
echo "depositCap      $(cast call $VAULT 'depositCap()(uint256)' --rpc-url $RPC)"
echo "maxSlippageBps  $(cast call $VAULT 'maxSlippageBps()(uint16)' --rpc-url $RPC)"
echo "assetPrice      $(cast call $VAULT 'assetPriceInWhbar()(uint256)' --rpc-url $RPC)"
echo "swapRouter      $(cast call $VAULT 'swapRouter()(address)' --rpc-url $RPC)"
for i in 0 1 2 3; do
  V=$(cast call $VAULT "venues(uint256)(address,uint16,bool,uint8)" $i --rpc-url $RPC 2>/dev/null) || break
  echo "venue $i         $(echo $V | tr '\n' ' ')"
done
