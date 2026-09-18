#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J predict_diag
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

JOBDIR="results/raw/${SLURM_JOB_ID}_predict_diag"
mkdir -p "$JOBDIR"

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "NX=$NX NY=$NY STEPS=$STEPS"
echo "=================================================="

"${SRUN[@]}" ./heat2d_predict \
    --nx "$NX" \
    --ny "$NY" \
    --steps "$STEPS" \
    --inject-delay-us 0 \
    --inject-every 0 \
    --inject-node -1 \
    --inject-local-rank -1 \
    | tee "$JOBDIR/predict_diag.txt"

echo
echo "Resultados: $JOBDIR"
