#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J heat2d_delay_sweep
#SBATCH --time=01:00:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh
SRUN=(srun --nodes=4 --ntasks=768 --ntasks-per-node=192 --cpus-per-task=1 --cpu-bind=threads)

NX=${NX:-24576}; NY=${NY:-4096}; STEPS=${STEPS:-100}; REPS=${REPS:-3}
JOBDIR="results/delay/${SLURM_JOB_ID}"
mkdir -p "$JOBDIR"

# Atrasamos todos os ranks do nó lógico 1 a cada 10 passos.
# Use isto só depois do teste sem injeção.
for D in 0 5 10 20 50 100; do
  for ((r=1; r<=REPS; ++r)); do
    COMMON=(--nx "$NX" --ny "$NY" --steps "$STEPS" \
      --inject-delay-us "$D" --inject-every 10 --inject-node 1 --inject-local-rank -1)
    if (( r % 2 == 1 )); then
      "${SRUN[@]}" ./heat2d_naive "${COMMON[@]}" | tee "$JOBDIR/d${D}_r${r}_naive.txt"
      "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy always | tee "$JOBDIR/d${D}_r${r}_recompute.txt"
    else
      "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy always | tee "$JOBDIR/d${D}_r${r}_recompute.txt"
      "${SRUN[@]}" ./heat2d_naive "${COMMON[@]}" | tee "$JOBDIR/d${D}_r${r}_naive.txt"
    fi
  done
done
python3 ./analyze_results.py "$JOBDIR" || true
