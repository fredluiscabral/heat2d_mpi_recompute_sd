#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J phi_delay_sweep
#SBATCH --time=00:35:00
#SBATCH --no-requeue
#SBATCH --exclude=sdumont2nd1011,sdumont2nd1018,sdumont2nd1023,sdumont2nd1031
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail

cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

SRUN=(srun --nodes=4 --ntasks=768 --ntasks-per-node=192 \
      --cpus-per-task=1 --cpu-bind=threads)

NX=${NX:-8192}
NY=${NY:-8192}
STEPS=${STEPS:-10000}
REPS=${REPS:-10}
WARMUP=${WARMUP:-1}

INJECT_EVERY=${INJECT_EVERY:-10}
INJECT_LOCAL_RANK=${INJECT_LOCAL_RANK:-0}

DELAYS=(10 25 50 100 200)

JOBDIR="results/raw/${SLURM_JOB_ID}_phi_delay_sweep"
mkdir -p "$JOBDIR"

STAMP="${SLURM_JOB_ID}_nx${NX}_ny${NY}_s${STEPS}"

run_case () {
    local node=$1
    local delay=$2
    local label=$3

    if [[ "$node" == "baseline" ]]; then
        local dir="$JOBDIR/baseline"
        mkdir -p "$dir"

        echo "=== BASELINE $label ==="

        "${SRUN[@]}" ./heat2d_naive \
            --nx "$NX" \
            --ny "$NY" \
            --steps "$STEPS" \
            --inject-delay-us 0 \
            --inject-every "$INJECT_EVERY" \
            --inject-node -1 \
            --inject-local-rank "$INJECT_LOCAL_RANK" \
            | tee "$dir/${STAMP}_${label}_baseline.txt"

        return
    fi

    local dir="$JOBDIR/node${node}_d${delay}"
    mkdir -p "$dir"

    echo "=== NODE=$node DELAY=${delay}us $label ==="

    "${SRUN[@]}" ./heat2d_naive \
        --nx "$NX" \
        --ny "$NY" \
        --steps "$STEPS" \
        --inject-delay-us "$delay" \
        --inject-every "$INJECT_EVERY" \
        --inject-node "$node" \
        --inject-local-rank "$INJECT_LOCAL_RANK" \
        | tee "$dir/${STAMP}_${label}_node${node}_d${delay}.txt"
}

CASES=(
    "baseline:0"
    "0:10"
    "0:25"
    "0:50"
    "0:100"
    "0:200"
    "3:10"
    "3:25"
    "3:50"
    "3:100"
    "3:200"
)

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "NX=$NX NY=$NY STEPS=$STEPS"
echo "REPS=$REPS"
echo "INJECT_EVERY=$INJECT_EVERY"
echo "INJECT_LOCAL_RANK=$INJECT_LOCAL_RANK"
echo "DELAYS=${DELAYS[*]}"
echo "=================================================="

for ((w=1; w<=WARMUP; ++w)); do

    label="warmup${w}"

    for entry in "${CASES[@]}"; do
        node=${entry%%:*}
        delay=${entry##*:}
        run_case "$node" "$delay" "$label"
    done

done

NCASES=${#CASES[@]}

for ((r=1; r<=REPS; ++r)); do

    label="rep${r}"

    echo
    echo "=================================================="
    echo "REPETICAO $r"
    echo "=================================================="

    start=$(( (r-1) % NCASES ))

    for ((k=0; k<NCASES; ++k)); do

        idx=$(( (start+k) % NCASES ))
        entry=${CASES[$idx]}

        node=${entry%%:*}
        delay=${entry##*:}

        run_case "$node" "$delay" "$label"

    done

done

echo
echo "=================================================="
echo "FIM"
echo "Resultados em: $JOBDIR"
echo "=================================================="
