#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J beta_same_nodes
#SBATCH --time=00:25:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail

cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

SRUN=(srun --nodes=4 --ntasks=768 --ntasks-per-node=192 --cpus-per-task=1 --cpu-bind=threads)

NX=${NX:-8192}
NY=${NY:-8192}
STEPS=${STEPS:-10000}
REPS=${REPS:-10}
WARMUP=${WARMUP:-1}

INJECT_DELAY_US=0
INJECT_EVERY=0
INJECT_NODE=-1
INJECT_LOCAL_RANK=-1

BETAS=(0.5 1.0 2.0 4.0)

JOBDIR="results/raw/${SLURM_JOB_ID}_beta_sweep"
BASE="$JOBDIR/baseline"

mkdir -p "$BASE"

for beta in "${BETAS[@]}"; do
    tag=${beta/./p}
    mkdir -p "$JOBDIR/b${tag}"
done

STAMP="${SLURM_JOB_ID}_nx${NX}_ny${NY}_s${STEPS}"

COMMON=(--nx "$NX" --ny "$NY" --steps "$STEPS" \
        --inject-delay-us "$INJECT_DELAY_US" \
        --inject-every "$INJECT_EVERY" \
        --inject-node "$INJECT_NODE" \
        --inject-local-rank "$INJECT_LOCAL_RANK")

run_naive () {
    local label=$1

    echo "=== RUN naive $label ==="

    "${SRUN[@]}" ./heat2d_naive "${COMMON[@]}" \
        | tee "$BASE/${STAMP}_${label}_naive.txt"
}

run_support () {
    local label=$1

    echo "=== RUN support+WAIT $label ==="

    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" --policy wait \
        | tee "$BASE/${STAMP}_${label}_support_wait.txt"
}

run_beta () {
    local beta=$1
    local label=$2
    local tag=${beta/./p}
    local dir="$JOBDIR/b${tag}"

    echo "=== RUN recompute/cost beta=$beta $label ==="

    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" \
        --policy cost --beta "$beta" \
        | tee "$dir/${STAMP}_${label}_recompute_cost_b${tag}.txt"
}

echo "=============================================="
echo "JOB        = $SLURM_JOB_ID"
echo "NODES      = $SLURM_JOB_NODELIST"
echo "NX x NY    = $NX x $NY"
echo "STEPS      = $STEPS"
echo "REPS       = $REPS"
echo "BETAS      = ${BETAS[*]}"
echo "=============================================="

for ((w=1; w<=WARMUP; ++w)); do
    label="warmup${w}"

    run_naive "$label"
    run_support "$label"

    for beta in "${BETAS[@]}"; do
        run_beta "$beta" "$label"
    done
done

for ((r=1; r<=REPS; ++r)); do

    label="rep${r}"

    echo
    echo "=============================================="
    echo "REPETICAO $r"
    echo "=============================================="

    if (( r % 2 == 1 )); then

        run_naive "$label"
        run_support "$label"

        for beta in "${BETAS[@]}"; do
            run_beta "$beta" "$label"
        done

    else

        for ((i=${#BETAS[@]}-1; i>=0; --i)); do
            run_beta "${BETAS[i]}" "$label"
        done

        run_support "$label"
        run_naive "$label"

    fi
done

echo
echo "=============================================="
echo "ANALISE POR BETA"
echo "=============================================="

for beta in "${BETAS[@]}"; do

    tag=${beta/./p}
    dir="$JOBDIR/b${tag}"

    cp "$BASE"/*_naive.txt "$dir"/
    cp "$BASE"/*_support_wait.txt "$dir"/

    echo
    echo "=============================================="
    echo "BETA = $beta"
    echo "=============================================="

    python3 ./analyze_results.py "$dir" --exclude-warmup \
        | tee "$JOBDIR/summary_b${tag}.txt" || true
done

echo
echo "=============================================="
echo "FIM"
echo "Resultados em: $JOBDIR"
echo "=============================================="
