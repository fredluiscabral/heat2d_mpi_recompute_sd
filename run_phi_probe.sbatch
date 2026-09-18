#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J phi_probe
#SBATCH --time=00:20:00
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

DELAY_US=${DELAY_US:-50}
INJECT_EVERY=${INJECT_EVERY:-10}
INJECT_LOCAL_RANK=${INJECT_LOCAL_RANK:-0}

JOBDIR="results/raw/${SLURM_JOB_ID}_phi_probe"
mkdir -p "$JOBDIR"

STAMP="${SLURM_JOB_ID}_nx${NX}_ny${NY}_s${STEPS}"

run_case () {
    local case_name=$1
    local inject_us=$2
    local inject_node=$3
    local label=$4

    local dir="$JOBDIR/$case_name"
    mkdir -p "$dir"

    echo "=== CASE=$case_name LABEL=$label inject_us=$inject_us inject_node=$inject_node ==="

    "${SRUN[@]}" ./heat2d_naive \
        --nx "$NX" \
        --ny "$NY" \
        --steps "$STEPS" \
        --inject-delay-us "$inject_us" \
        --inject-every "$INJECT_EVERY" \
        --inject-node "$inject_node" \
        --inject-local-rank "$INJECT_LOCAL_RANK" \
        | tee "$dir/${STAMP}_${label}_${case_name}.txt"
}

echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "NX=$NX NY=$NY STEPS=$STEPS REPS=$REPS"
echo "DELAY_US=$DELAY_US INJECT_EVERY=$INJECT_EVERY"
echo "INJECT_LOCAL_RANK=$INJECT_LOCAL_RANK"

for ((w=1; w<=WARMUP; ++w)); do
    label="warmup${w}"

    run_case baseline 0 -1 "$label"
    run_case node0 "$DELAY_US" 0 "$label"
    run_case node1 "$DELAY_US" 1 "$label"
    run_case node2 "$DELAY_US" 2 "$label"
    run_case node3 "$DELAY_US" 3 "$label"
done

for ((r=1; r<=REPS; ++r)); do

    label="rep${r}"

    case $(((r-1)%5)) in
        0)
            run_case baseline 0 -1 "$label"
            run_case node0 "$DELAY_US" 0 "$label"
            run_case node1 "$DELAY_US" 1 "$label"
            run_case node2 "$DELAY_US" 2 "$label"
            run_case node3 "$DELAY_US" 3 "$label"
            ;;
        1)
            run_case node0 "$DELAY_US" 0 "$label"
            run_case node1 "$DELAY_US" 1 "$label"
            run_case node2 "$DELAY_US" 2 "$label"
            run_case node3 "$DELAY_US" 3 "$label"
            run_case baseline 0 -1 "$label"
            ;;
        2)
            run_case node1 "$DELAY_US" 1 "$label"
            run_case node2 "$DELAY_US" 2 "$label"
            run_case node3 "$DELAY_US" 3 "$label"
            run_case baseline 0 -1 "$label"
            run_case node0 "$DELAY_US" 0 "$label"
            ;;
        3)
            run_case node2 "$DELAY_US" 2 "$label"
            run_case node3 "$DELAY_US" 3 "$label"
            run_case baseline 0 -1 "$label"
            run_case node0 "$DELAY_US" 0 "$label"
            run_case node1 "$DELAY_US" 1 "$label"
            ;;
        4)
            run_case node3 "$DELAY_US" 3 "$label"
            run_case baseline 0 -1 "$label"
            run_case node0 "$DELAY_US" 0 "$label"
            run_case node1 "$DELAY_US" 1 "$label"
            run_case node2 "$DELAY_US" 2 "$label"
            ;;
    esac
done

echo "FIM"
echo "Resultados em: $JOBDIR"
