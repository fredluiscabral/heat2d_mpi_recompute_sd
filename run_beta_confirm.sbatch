#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --ntasks=768
#SBATCH --cpus-per-task=1
#SBATCH -p lncc-cpu_amd
#SBATCH -J beta_confirm
#SBATCH --time=00:30:00
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
REPS=${REPS:-30}
WARMUP=${WARMUP:-1}

INJECT_DELAY_US=0
INJECT_EVERY=0
INJECT_NODE=-1
INJECT_LOCAL_RANK=-1

JOBDIR="results/raw/${SLURM_JOB_ID}_beta_confirm"
NAIVEDIR="$JOBDIR/naive"
B05DIR="$JOBDIR/b0p5"
B4DIR="$JOBDIR/b4p0"

mkdir -p "$NAIVEDIR" "$B05DIR" "$B4DIR"

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
        | tee "$NAIVEDIR/${STAMP}_${label}_naive.txt"
}

run_b05 () {
    local label=$1

    echo "=== RUN cost beta=0.5 $label ==="

    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" \
        --policy cost --beta 0.5 \
        | tee "$B05DIR/${STAMP}_${label}_recompute_cost_b0p5.txt"
}

run_b4 () {
    local label=$1

    echo "=== RUN cost beta=4.0 $label ==="

    "${SRUN[@]}" ./heat2d_recompute "${COMMON[@]}" \
        --policy cost --beta 4.0 \
        | tee "$B4DIR/${STAMP}_${label}_recompute_cost_b4p0.txt"
}

echo "=================================================="
echo "JOB       = $SLURM_JOB_ID"
echo "NODES     = $SLURM_JOB_NODELIST"
echo "NX x NY   = $NX x $NY"
echo "STEPS     = $STEPS"
echo "REPS      = $REPS"
echo "TESTE     = NAIVE vs beta=0.5 vs beta=4.0"
echo "=================================================="

for ((w=1; w<=WARMUP; ++w)); do
    label="warmup${w}"

    run_naive "$label"
    run_b05 "$label"
    run_b4 "$label"
done

for ((r=1; r<=REPS; ++r)); do

    label="rep${r}"

    echo
    echo "=================================================="
    echo "REPETICAO $r"
    echo "=================================================="

    case $(( (r-1) % 3 )) in

        0)
            run_naive "$label"
            run_b05 "$label"
            run_b4 "$label"
            ;;

        1)
            run_b05 "$label"
            run_b4 "$label"
            run_naive "$label"
            ;;

        2)
            run_b4 "$label"
            run_naive "$label"
            run_b05 "$label"
            ;;
    esac

done

echo
echo "=================================================="
echo "ANALISE"
echo "=================================================="

mkdir -p "$JOBDIR/analysis_b0p5"
mkdir -p "$JOBDIR/analysis_b4p0"

cp "$NAIVEDIR"/*.txt "$JOBDIR/analysis_b0p5/"
cp "$B05DIR"/*.txt "$JOBDIR/analysis_b0p5/"

cp "$NAIVEDIR"/*.txt "$JOBDIR/analysis_b4p0/"
cp "$B4DIR"/*.txt "$JOBDIR/analysis_b4p0/"

echo
echo "===== BETA 0.5 ====="
python3 ./analyze_results.py "$JOBDIR/analysis_b0p5" --exclude-warmup \
    | tee "$JOBDIR/summary_b0p5.txt" || true

echo
echo "===== BETA 4.0 ====="
python3 ./analyze_results.py "$JOBDIR/analysis_b4p0" --exclude-warmup \
    | tee "$JOBDIR/summary_b4p0.txt" || true

echo
echo "=================================================="
echo "FIM"
echo "Resultados em: $JOBDIR"
echo "=================================================="
