#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J heat2d_rw_4n192
#SBATCH --time=00:15:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

# 192 tarefas/nó = 192 núcleos físicos/nó (2 x EPYC 9684X de 96 cores).
SRUN=(srun --nodes=4 --ntasks=768 --ntasks-per-node=192 --cpus-per-task=1 --cpu-bind=threads)

NX=${NX:-8192}
NY=${NY:-8192}
STEPS=${STEPS:-10000}
REPS=${REPS:-10}
WARMUP=${WARMUP:-1}
POLICY=${POLICY:-cost}
BETA=${BETA:-1.0}
RUN_SUPPORT_CONTROL=${RUN_SUPPORT_CONTROL:-1}

# Injeção opcional de atraso. Zero = medir apenas o sistema real.
INJECT_DELAY_US=${INJECT_DELAY_US:-0}
INJECT_EVERY=${INJECT_EVERY:-0}
INJECT_NODE=${INJECT_NODE:--1}
INJECT_LOCAL_RANK=${INJECT_LOCAL_RANK:--1}

mkdir -p results/raw
STAMP="${SLURM_JOB_ID}_nx${NX}_ny${NY}_s${STEPS}"
JOBDIR="results/raw/${SLURM_JOB_ID}"
mkdir -p "$JOBDIR"

COMMON=(--nx "$NX" --ny "$NY" --steps "$STEPS" \
        --inject-delay-us "$INJECT_DELAY_US" --inject-every "$INJECT_EVERY" \
        --inject-node "$INJECT_NODE" --inject-local-rank "$INJECT_LOCAL_RANK")

run_naive () {
    local label=$1
    echo "=== RUN naive $label ==="
    "${SRUN[@]}" ./heat2d_naive "${COMMON[@]}" \
      | tee "${JOBDIR}/${STAMP}_${label}_naive.txt"
}

run_support_wait () {
    local label=$1
    echo "=== RUN support+WAIT $label ==="
    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy wait \
      | tee "${JOBDIR}/${STAMP}_${label}_support_wait.txt"
}

run_rec () {
    local label=$1
    echo "=== RUN recompute/$POLICY $label ==="
    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy "$POLICY" --beta "$BETA" \
      | tee "${JOBDIR}/${STAMP}_${label}_recompute_${POLICY}.txt"
}

# Warm-up de ambas as variantes na mesma alocação.
for ((w=1; w<=WARMUP; ++w)); do
    run_naive "warmup${w}"
    if (( RUN_SUPPORT_CONTROL )); then run_support_wait "warmup${w}"; fi
    run_rec   "warmup${w}"
done

# Ordem AB/BA alternada para reduzir viés temporal dentro da alocação.
for ((r=1; r<=REPS; ++r)); do
    if (( r % 2 == 1 )); then
        run_naive "rep${r}"
        if (( RUN_SUPPORT_CONTROL )); then run_support_wait "rep${r}"; fi
        run_rec   "rep${r}"
    else
        run_rec   "rep${r}"
        if (( RUN_SUPPORT_CONTROL )); then run_support_wait "rep${r}"; fi
        run_naive "rep${r}"
    fi
done

echo "=== RESUMO ==="
python3 ./analyze_results.py "$JOBDIR" --exclude-warmup || true
