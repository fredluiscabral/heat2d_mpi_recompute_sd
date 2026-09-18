#!/bin/bash
set -euo pipefail
# Uso:
#   ./submit_4n192.sh                 # se sua conta não exigir --account
#   ./submit_4n192.sh NOME_DO_PROJETO # se exigir
if [[ $# -ge 1 && -n "$1" ]]; then
  sbatch --account="$1" run_compare_4n192.sbatch
else
  sbatch run_compare_4n192.sbatch
fi
