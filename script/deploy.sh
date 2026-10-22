#!/usr/bin/env bash
# Deploy AyHbarVault. Usage:
#   NETWORK=testnet ./deploy.sh      (default)
#   NETWORK=mainnet ./deploy.sh
# Requires: PRIVATE_KEY (owner/deployer) in the environment.
set -euo pipefail
cd "$(dirname "$0")/.."
NETWORK=${NETWORK:-testnet}
: "${PRIVATE_KEY:?set PRIVATE_KEY (the deployer becomes owner)}"

J=addresses.json
g(){ python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['$1']['evm'])"; }
RPC=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['rpc'])")
EXP=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['explorer'])")
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
TX="--legacy --gas-price 1140000000000"

echo "network   $NETWORK"
echo "deployer  $ME"
echo "balance   $(python3 -c "print(f'{int('$(cast balance $ME --rpc-url $RPC)')/1e18:.2f} HBAR')")"

echo "==> deploying AyHbarVault"
OUT=$(FOUNDRY_PROFILE=default forge create src/AyHbarVault.sol:AyHbarVault \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast $TX --gas-limit 5600000 --json \
  --constructor-args \
    "$(g hbarx)" "$(g pool)" "$(g pair)" "$(g whbarToken)" "$(g whbarWrapper)" \
    "$(g aToken)" "$(g debtToken)" "$(g oracle)" "$(g staking)" "$ME")
VAULT=$(echo "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
echo "VAULT $VAULT"
mkdir -p deployments
echo "$VAULT" > "deployments/vault_${NETWORK}.txt"

echo "==> associating HTS tokens and approving the lending pool"
cast send "$VAULT" "associate()" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $TX --gas-limit 3000000 >/dev/null
echo "    associated = $(cast call "$VAULT" 'associated()(bool)' --rpc-url $RPC)"

echo
echo "deployed: $EXP/address/$VAULT"
echo "next: ./script/configure.sh"
