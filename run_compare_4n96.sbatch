#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=96
#SBATCH --ntasks=384
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J heat2d_rw_4n96
#SBATCH --time=00:40:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

# Controle de meia densidade: 96 ranks/nó em um nó com 192 núcleos físicos.
SRUN=(srun --nodes=4 --ntasks=384 --ntasks-per-node=96 --cpus-per-task=1 --cpu-bind=cores --hint=nomultithread)

NX=${NX:-12288}
NY=${NY:-4096}
STEPS=${STEPS:-100}
REPS=${REPS:-6}
WARMUP=${WARMUP:-1}
POLICY=${POLICY:-always}
BETA=${BETA:-1.0}

JOBDIR="results/raw/${SLURM_JOB_ID}_4n96"
mkdir -p "$JOBDIR"
STAMP="${SLURM_JOB_ID}_96r_nx${NX}_ny${NY}_s${STEPS}"
COMMON=(--nx "$NX" --ny "$NY" --steps "$STEPS")

run_naive () { local label=$1; "${SRUN[@]}" ./heat2d_naive "${COMMON[@]}" | tee "$JOBDIR/${STAMP}_${label}_naive.txt"; }
run_rec () { local label=$1; "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy "$POLICY" --beta "$BETA" | tee "$JOBDIR/${STAMP}_${label}_recompute_${POLICY}.txt"; }

for ((w=1; w<=WARMUP; ++w)); do run_naive "warmup${w}"; run_rec "warmup${w}"; done
for ((r=1; r<=REPS; ++r)); do
  if (( r % 2 == 1 )); then run_naive "rep${r}"; run_rec "rep${r}"; else run_rec "rep${r}"; run_naive "rep${r}"; fi
done
python3 ./analyze_results.py "$JOBDIR" --exclude-warmup || true
