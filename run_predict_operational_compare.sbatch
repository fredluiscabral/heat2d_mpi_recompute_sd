#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J predict_op_compare
#SBATCH --time=00:05:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail

cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

SRUN=(srun \
      --nodes=4 \
      --ntasks=768 \
      --ntasks-per-node=192 \
      --cpus-per-task=1 \
      --cpu-bind=threads)

NX=8256
NY=8256
STEPS=1000
ETA=0.5
KAPPA=1.0
BUDGET_FLOOR=1e-30
REPS=10

JOBDIR="results/raw/${SLURM_JOB_ID}_predict_operational_compare"
mkdir -p "$JOBDIR"

COMMON_ARGS=(
    --nx "$NX"
    --ny "$NY"
    --steps "$STEPS"
    --policy wait
    --eta "$ETA"
    --kappa "$KAPPA"
    --budget-floor "$BUDGET_FLOOR"
    --inject-delay-us 0
    --inject-every 0
    --inject-node -1
    --inject-local-rank -1
)

run_one() {
    local mode="$1"
    local rep="$2"
    local enable=0
    if [[ "$mode" == "predict" ]]; then
        enable=1
    fi

    echo "--------------------------------------------------"
    echo "RUN rep=$rep mode=$mode enable_predict=$enable"
    "${SRUN[@]}" ./heat2d_predict_operational \
        "${COMMON_ARGS[@]}" \
        --enable-predict "$enable" \
        | tee "$JOBDIR/rep${rep}_${mode}.txt"
}

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "PROBLEM=multimode mode11_plus_0.25_mode32"
echo "COMPARE=READ_WAIT versus READ_PREDICT_WAIT"
echo "NX=$NX NY=$NY STEPS=$STEPS ETA=$ETA KAPPA=$KAPPA REPS=$REPS"
echo "ORDER=alternating_pairs"
echo "=================================================="

for rep in $(seq 1 "$REPS"); do
    if (( rep % 2 == 1 )); then
        run_one baseline "$rep"
        run_one predict  "$rep"
    else
        run_one predict  "$rep"
        run_one baseline "$rep"
    fi
done

echo
echo "Resumo RESULT:"
grep '^RESULT ' "$JOBDIR"/*.txt || true

echo
echo "Resumo PREDICT_OP:"
grep '^PREDICT_OP ' "$JOBDIR"/*.txt || true

echo
echo "Resultados: $JOBDIR"
