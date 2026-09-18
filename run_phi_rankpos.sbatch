#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J phi_rankpos
#SBATCH --time=00:20:00
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

DELAY_US=${DELAY_US:-200}
INJECT_EVERY=${INJECT_EVERY:-10}

JOBDIR="results/raw/${SLURM_JOB_ID}_phi_rankpos"
mkdir -p "$JOBDIR"

STAMP="${SLURM_JOB_ID}_nx${NX}_ny${NY}_s${STEPS}"

run_case () {
    local name=$1
    local node=$2
    local lrank=$3
    local delay=$4
    local label=$5

    local dir="$JOBDIR/$name"
    mkdir -p "$dir"

    echo "=== CASE=$name NODE=$node LRANK=$lrank DELAY=${delay}us LABEL=$label ==="

    "${SRUN[@]}" ./heat2d_naive \
        --nx "$NX" \
        --ny "$NY" \
        --steps "$STEPS" \
        --inject-delay-us "$delay" \
        --inject-every "$INJECT_EVERY" \
        --inject-node "$node" \
        --inject-local-rank "$lrank" \
        | tee "$dir/${STAMP}_${label}_${name}.txt"
}

CASES=(
    "baseline:-1:0:0"
    "n0r0:0:0:$DELAY_US"
    "n3r0:3:0:$DELAY_US"
    "n0r96:0:96:$DELAY_US"
    "n3r96:3:96:$DELAY_US"
)

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "NX=$NX NY=$NY STEPS=$STEPS"
echo "REPS=$REPS WARMUP=$WARMUP"
echo "DELAY_US=$DELAY_US"
echo "INJECT_EVERY=$INJECT_EVERY"
echo "=================================================="

run_entry () {
    local entry=$1
    local label=$2

    IFS=: read -r name node lrank delay <<< "$entry"
    run_case "$name" "$node" "$lrank" "$delay" "$label"
}

for ((w=1; w<=WARMUP; ++w)); do
    label="warmup${w}"

    for entry in "${CASES[@]}"; do
        run_entry "$entry" "$label"
    done
done

NCASES=${#CASES[@]}

for ((r=1; r<=REPS; ++r)); do

    label="rep${r}"
    start=$(( (r-1) % NCASES ))

    echo
    echo "=================================================="
    echo "REPETICAO $r"
    echo "=================================================="

    for ((k=0; k<NCASES; ++k)); do
        idx=$(( (start+k) % NCASES ))
        run_entry "${CASES[$idx]}" "$label"
    done
done

echo
echo "=================================================="
echo "FIM"
echo "Resultados em: $JOBDIR"
echo "=================================================="
