#!/bin/bash
# =============================================================================
# Slurm job-array submission for scripts/gridSearchGraph.R
# =============================================================================
# Splits the transition-matrix grid into N_SHARDS independent array tasks (one
# node each, no communication between nodes); a dependent job then merges the
# shards into exactly the result a single run would give.
#
# Usage (from any directory, on a Slurm login node):
#     bash cluster/slurm/submit_array.sh                                # all shards + merge
#     bash cluster/slurm/submit_array.sh metrics_file=metrics/custom.R  # any key=value
#     ARRAY=3,7 bash cluster/slurm/submit_array.sh                      # re-run shards 3, 7 + merge
#
# Extra key=value arguments are appended to ARGS for both the shards and the
# merge (values must not contain spaces). Shards go to <out_dir>/shards/, the
# merged result to <out_dir>/ under the same name as a single run.
# =============================================================================

set -euo pipefail

# Marginal power per hypothesis (count defines k) and key=value overrides.
MP="0.90 0.80 0.70 0.60"
ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"
# 16 shards x 4 cores; the grid above is ~10 core-hours, i.e. ~10 min per shard.
N_SHARDS=16
CORES=4
PARTITION="normal"                # <-- set to your partition
ARRAY="${ARRAY:-1-${N_SHARDS}}"
EXTRA="$*"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K=$(wc -w <<< "$MP")
NAME="gogt_k${K}"
cd "$ROOT"
# Slurm does not create the --output/--error directory.
mkdir -p logs results

ARRAY_ID=$(sbatch --parsable <<EOF
#!/bin/bash
#SBATCH --job-name=${NAME}
#SBATCH --array=${ARRAY}
# One node per task, local workers only; --cpus-per-task sets the worker count.
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${CORES}
#SBATCH --mem-per-cpu=4000
#SBATCH --partition=${PARTITION}
#SBATCH --time=01:00:00
#SBATCH --output=logs/${NAME}.%A_%a.out
#SBATCH --error=logs/${NAME}.%A_%a.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} shard=\${SLURM_ARRAY_TASK_ID}/${N_SHARDS}
EOF
)
ARRAY_ID="${ARRAY_ID%%;*}"

MERGE_ID=$(sbatch --parsable --dependency=afterok:${ARRAY_ID} <<EOF
#!/bin/bash
#SBATCH --job-name=${NAME}_merge
#SBATCH --ntasks=1
#SBATCH --mem=4000
#SBATCH --partition=${PARTITION}
#SBATCH --time=00:30:00
#SBATCH --output=logs/${NAME}_merge.%j.out
#SBATCH --error=logs/${NAME}_merge.%j.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} merge_shards=${N_SHARDS}
EOF
)

echo "Submitted array job ${ARRAY_ID} (tasks ${ARRAY} of ${N_SHARDS}) and merge job ${MERGE_ID%%;*}."

# Notes:
# - The merge only starts if every task in this submission succeeds. If some
#   fail, re-run just those (ARRAY=3,7 bash ...), which also submits a new merge;
#   then scancel the old, never-starting merge job.
