#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J waittrace_bal
#SBATCH --time=00:15:00
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
STEPS=10000
REPS=10
WARMUP=1

JOBDIR="results/raw/${SLURM_JOB_ID}_waittrace"

mkdir -p "$JOBDIR/control"
mkdir -p "$JOBDIR/waittrace"

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "NX=$NX NY=$NY STEPS=$STEPS"
echo "REPS=$REPS"
echo "TRACE_EVERY=100"
echo "=================================================="

run_control () {
    local label=$1

    echo
    echo "=== CONTROL $label ==="

    "${SRUN[@]}" ./heat2d_naive \
        --nx "$NX" \
        --ny "$NY" \
        --steps "$STEPS" \
        --inject-delay-us 0 \
        --inject-every 0 \
        --inject-node -1 \
        --inject-local-rank -1 \
        | tee "$JOBDIR/control/${label}.txt"
}

run_waittrace () {
    local label=$1

    echo
    echo "=== TRACE $label ==="

    "${SRUN[@]}" ./heat2d_naive_waittrace \
        --nx "$NX" \
        --ny "$NY" \
        --steps "$STEPS" \
        --inject-delay-us 0 \
        --inject-every 0 \
        --inject-node -1 \
        --inject-local-rank -1 \
        | tee "$JOBDIR/waittrace/${label}.txt"
}

for ((w=1; w<=WARMUP; ++w)); do
    run_control "warmup${w}"
    run_waittrace   "warmup${w}"
done

for ((r=1; r<=REPS; ++r)); do

    if (( r % 2 == 1 )); then
        run_control "rep${r}"
        run_waittrace   "rep${r}"
    else
        run_waittrace   "rep${r}"
        run_control "rep${r}"
    fi

done

echo
echo "=================================================="
echo "FIM"
echo "Resultados: $JOBDIR"
echo "=================================================="
