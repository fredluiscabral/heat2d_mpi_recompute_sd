#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J predict_admiss_ftcs
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

JOBDIR="results/raw/${SLURM_JOB_ID}_predict_admiss_ftcs"
mkdir -p "$JOBDIR"

echo "=================================================="
echo "JOB=$SLURM_JOB_ID"
echo "NODES=$SLURM_JOB_NODELIST"
echo "PROBLEM=multimode mode11_plus_0.25_mode32"
echo "DIAGNOSTIC=prediction_admissibility D=0 fp_guard=higham_gamma ftcs_guard=higham_gamma8"
echo "NX=$NX NY=$NY STEPS=$STEPS ETA=$ETA KAPPA=$KAPPA"
echo "NOTE=makespan_not_for_production_comparison"
echo "=================================================="

"${SRUN[@]}" ./heat2d_predict_admiss \
    --nx "$NX" \
    --ny "$NY" \
    --steps "$STEPS" \
    --policy wait \
    --eta "$ETA" \
    --kappa "$KAPPA" \
    --budget-floor "$BUDGET_FLOOR" \
    --inject-delay-us 0 \
    --inject-every 0 \
    --inject-node -1 \
    --inject-local-rank -1 \
    | tee "$JOBDIR/predict_admiss_ftcs.txt"

echo
echo "Resultados: $JOBDIR"
