#!/usr/bin/env bash
# Full demonstration: deposit both assets, then withdraw and redeem.
set -euo pipefail
cd "$(dirname "$0")"
line(){ echo; echo "──────────── $1"; echo; sleep 3; }   # let the relay settle between steps
line "1. starting state";        ./status.sh
line "2. deposit 0.05 HBARX";    ./deposit-hbarx.sh 0.05
line "3. deposit 1 HBAR";        ./deposit-hbar.sh 1
line "4. state after deposits";  ./status.sh
line "5. withdraw 0.02 HBARX";   ./withdraw.sh 0.02
line "6. redeem all shares";     ./redeem.sh all
line "7. final state";           ./status.sh
echo; echo "done."
