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
echo "balance   $(python3 -c "import sys;print('%.2f HBAR' % (int(sys.argv[1])/1e18))" "$(cast balance $ME --rpc-url $RPC)")"

# Install dependencies before deploying, so their clone output cannot land in
# the middle of the deploy command's own output.
git submodule update --init --recursive >/dev/null 2>&1 || true

# Recovery path: VAULT=0x... skips the deployment and only finishes the setup.
# Useful if a deployment succeeded but the run was interrupted afterwards.
if [ -n "${VAULT:-}" ]; then
  echo "==> using the existing vault $VAULT (skipping deployment)"
else

# The vault links against VaultMath, which holds the pricing and routing
# arithmetic. Deploying it separately is what keeps the vault inside the 24 KB
# contract-code limit, so it goes first and its address is linked in.
echo "==> deploying VaultMath"
LIBOUT=$(forge create src/VaultMath.sol:VaultMath \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast $TX --gas-limit 1500000 --json)
LIB=$(printf '%s' "$LIBOUT" | python3 -c "
import json,re,sys
raw=sys.stdin.read()
for line in raw.splitlines():
    line=line.strip()
    if line.startswith('{'):
        try:
            a=json.loads(line).get('deployedTo')
            if a: print(a); break
        except ValueError: pass
else:
    m=re.search(r'Deployed to:\s*(0x[0-9a-fA-F]{40})', raw)
    print(m.group(1) if m else '')")
if [ -z "$LIB" ]; then echo "VaultMath deployment could not be parsed"; echo "$LIBOUT"; exit 1; fi
echo "LIBRARY $LIB"
mkdir -p deployments
echo "$LIB" > "deployments/vaultmath_${NETWORK}.txt"
sleep 4

echo "==> deploying AyHbarVault"
OUT=$(FOUNDRY_PROFILE=default forge create src/AyHbarVault.sol:AyHbarVault \
  --libraries src/VaultMath.sol:VaultMath:"$LIB" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast $TX --gas-limit 5600000 --json \
  --constructor-args \
    "$(g hbarx)" "$(g pool)" "$(g pair)" "$(g whbarToken)" "$(g whbarWrapper)" \
    "$(g aToken)" "$(g debtToken)" "$(g oracle)" "$(g staking)" "$ME")
VAULT=$(printf '%s' "$OUT" | python3 -c "
import json,re,sys
raw = sys.stdin.read()
addr = None
for line in raw.splitlines():                       # --json puts one object on a line
    line = line.strip()
    if line.startswith('{'):
        try: addr = json.loads(line).get('deployedTo') or addr
        except ValueError: pass
if not addr:                                        # fall back to the human-readable form
    m = re.search(r'Deployed to:\s*(0x[0-9a-fA-F]{40})', raw)
    addr = m.group(1) if m else None
if not addr:
    sys.stderr.write('could not read the deployed address from forge output:\n' + raw + '\n')
    sys.exit(1)
print(addr)") || VAULT=""
if [ -z "$VAULT" ]; then
  echo "Deployment output could not be parsed. Before re-running, check whether a contract"
  echo "was in fact created, which costs ~5.3 HBAR to repeat:"
  echo "  curl -s \"https://${NETWORK}.mirrornode.hedera.com/api/v1/accounts/$ME?limit=5&order=desc\""
  echo "Look for an ETHEREUMTRANSACTION whose entity_id is a new 0.0.x - that is the vault."
  exit 1
fi
echo "VAULT $VAULT"
fi
mkdir -p deployments
echo "$VAULT" > "deployments/vault_${NETWORK}.txt"

if [ "$(cast call "$VAULT" 'associated()(bool)' --rpc-url "$RPC")" = "true" ]; then
  echo "==> already associated"
else
  echo "==> associating HTS tokens and approving the lending pool"
  cast send "$VAULT" "associate()" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $TX --gas-limit 3000000 >/dev/null
fi
echo "    associated = $(cast call "$VAULT" 'associated()(bool)' --rpc-url $RPC)"

echo
echo "deployed: $EXP/address/$VAULT"
echo "next: ./script/configure.sh"
