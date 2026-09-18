#!/bin/bash
set -euo pipefail

SBATCH_SCRIPT="run_compare_4n192.sbatch"
mkdir -p results
LOG="results/submitted_beta_jobs.txt"

echo "=== Beta sweep $(date) ===" | tee -a "$LOG"

for beta in 0.5 2.0 4.0; do

    tag=$(echo "$beta" | tr '.' 'p')

    out=$(sbatch \
        --job-name="cost_b${tag}" \
        --export=ALL,POLICY=cost,BETA="$beta",STEPS=10000,REPS=10,WARMUP=1 \
        "$SBATCH_SCRIPT")

    jobid=$(echo "$out" | awk '{print $4}')

    echo "beta=$beta  job=$jobid" | tee -a "$LOG"
done

echo
echo "Jobs submetidos:"
cat "$LOG"
