#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --ntasks=16
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd_dev
#SBATCH -J heat2d_smoke
#SBATCH --time=00:10:00
#SBATCH --no-requeue
#SBATCH --output=results/slurm-%x-%j.out

set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
source ./env_sd.sh

SRUN=(srun --nodes=2 --ntasks=16 --ntasks-per-node=8 --cpus-per-task=1)

"${SRUN[@]}" ./heat2d_naive --nx 512 --ny 256 --steps 20
"${SRUN[@]}" ./heat2d_recompute --nx 512 --ny 256 --steps 20 --policy always --validate-late 1
