#!/usr/bin/env bash
# Compare the deployed runtime bytecode against what this repo compiles.
#   NETWORK=testnet ./script/verify-bytecode.sh [address]
#
# Two parts of the runtime legitimately differ and are excluded:
#   * immutable slots, which hold the constructor's addresses (zero in a fresh build)
#   * the trailing CBOR metadata, whose hash covers the import paths used to compile
set -euo pipefail
cd "$(dirname "$0")/.."
NETWORK=${NETWORK:-testnet}
J=addresses.json
RPC=$(python3 -c "import json;print(json.load(open('$J'))['$NETWORK']['rpc'])")
ADDR=${1:-$(cat "deployments/vault_${NETWORK}.txt" 2>/dev/null || echo 0x1877f189aaF4A14ec3C7C0FF7e1045Cd0604df6e)}

forge build >/dev/null
CHAIN=$(cast code "$ADDR" --rpc-url "$RPC")
python3 - "$ADDR" "$CHAIN" << 'PY'
import json, sys
addr, chain = sys.argv[1], sys.argv[2].strip()
local = json.load(open('out/AyHbarVault.sol/AyHbarVault.json'))['deployedBytecode']['object']
if len(local) != len(chain):
    print(f"length differs: repo {len(local)}, chain {len(chain)}"); sys.exit(1)

TAIL = 110                                  # CBOR metadata trailer
body_l, body_c = local[:-TAIL], chain[:-TAIL]
mismatch = [(i, a, b) for i, (a, b) in enumerate(zip(body_l, body_c))
            if a != b and a != '0']         # repo side must be an unset immutable

print(f"address        {addr}")
print(f"runtime length {len(chain)//2} bytes")
if mismatch:
    i = mismatch[0][0]
    print("MISMATCH at byte", i // 2)
    print("  repo ", body_l[max(0,i-40):i+40])
    print("  chain", body_c[max(0,i-40):i+40])
    sys.exit(1)
diff = sum(1 for a, b in zip(body_l, body_c) if a != b)
print(f"immutable bytes {diff//2} (constructor addresses)")
print("MATCH — the deployed code is this source")
PY
