#!/usr/bin/env bash
# Full demonstration: deposit both assets, queue a withdrawal, then release it.
#
# The live vault has a 1-day withdrawal timelock, so this script queues a request,
# shows the pending state, and cancels it again. To complete a real exit, run
# ./request-withdraw.sh, wait out the timelock, then ./redeem.sh all.
set -euo pipefail
cd "$(dirname "$0")"
line(){ echo; echo "──────────── $1"; echo; sleep 3; }   # let the relay settle between steps
line "1. starting state";              ./status.sh
line "2. deposit 0.05 HBARX";          ./deposit-hbarx.sh 0.05
line "3. deposit 1 HBAR";              ./deposit-hbar.sh 1
line "4. state after deposits";        ./status.sh
line "5. queue all shares for exit";   ./request-withdraw.sh all
line "6. state with request pending";  ./status.sh
line "7. cancel the request";          ./cancel-request.sh
line "8. final state";                 ./status.sh
echo; echo "done."
