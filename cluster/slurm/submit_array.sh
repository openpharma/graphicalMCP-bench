#!/bin/bash
# =============================================================================
# Slurm job-array submission for scripts/gridSearchGraph.R
# =============================================================================
# Splits the transition-matrix grid into N_SHARDS independent array tasks (one
# node each, no communication between nodes); a dependent job then merges the
# shards into exactly the result a single run would give.
#
# Usage (from any directory, on a Slurm login node):
#     bash cluster/slurm/submit_array.sh scenario=my_id                 # a scenario file
#     bash cluster/slurm/submit_array.sh                                # all shards + merge
#     bash cluster/slurm/submit_array.sh 0.9 0.8 0.7 w_step=0.02        # marginal powers + overrides
#     bash cluster/slurm/submit_array.sh metrics_file=metrics/custom.R  # + custom metrics
#     ARRAY=3,7 bash cluster/slurm/submit_array.sh                      # re-run shards 3, 7 + merge
#     N_SHARDS=32 CORES=2 PARTITION=short bash cluster/slurm/submit_array.sh
#     MAX_RUNNING=4 bash cluster/slurm/submit_array.sh                  # at most 4 tasks at once
#     WALLTIME=00:20:00 MERGE_WALLTIME=00:15:00 bash cluster/slurm/submit_array.sh
#
# There is no node count: each task takes CORES cores on one node and Slurm
# places the tasks; MAX_RUNNING caps how many run at the same time.
# With scenario=<id> the scenario file sets everything and MP / ARGS below are
# ignored. Otherwise positional numbers replace MP. key=value arguments
# override ARGS / the scenario for both the shards and the merge (last value
# wins; values must not contain spaces). WALLTIME / MERGE_WALLTIME set the time
# limits; account, memory, ... can be overridden with SBATCH_* environment
# variables.
# Shards go to <out_dir>/shards/ (results/shards/ for a scenario), the merged
# result to <out_dir>/ under the same name as a single run.
# =============================================================================

set -euo pipefail

# Marginal power per hypothesis (count defines k) and key=value overrides.
MP="0.90 0.80 0.70 0.60"
ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"
# Default 16 shards x 4 cores; the grid above is ~10 core-hours, i.e. ~10 min
# per shard. Re-runs must use the same N_SHARDS as the original submission.
N_SHARDS="${N_SHARDS:-16}"
CORES="${CORES:-4}"
PARTITION="${PARTITION:-}"         # empty = the cluster's default partition
ARRAY="${ARRAY:-1-${N_SHARDS}}"
MAX_RUNNING="${MAX_RUNNING:-}"     # empty = no limit
WALLTIME="${WALLTIME:-08:00:00}"   # [D-]HH:MM:SS per task
MERGE_WALLTIME="${MERGE_WALLTIME:-08:00:00}"
source "$(dirname "${BASH_SOURCE[0]}")/../args.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# Slurm does not create the --output/--error directory.
mkdir -p logs results

ARRAY_ID=$(sbatch --parsable ${PARTITION:+--partition=$PARTITION} <<EOF
#!/bin/bash
#SBATCH --job-name=${NAME}
#SBATCH --array=${ARRAY}${MAX_RUNNING:+%$MAX_RUNNING}
# One node per task, local workers only; --cpus-per-task sets the worker count.
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${CORES}
#SBATCH --mem-per-cpu=1000
#SBATCH --time=${WALLTIME}
#SBATCH --output=logs/${NAME}.%A_%a.out
#SBATCH --error=logs/${NAME}.%A_%a.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export BENCH_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} shard=\${SLURM_ARRAY_TASK_ID}/${N_SHARDS}
EOF
)
ARRAY_ID="${ARRAY_ID%%;*}"

MERGE_ID=$(sbatch --parsable ${PARTITION:+--partition=$PARTITION} --dependency=afterok:${ARRAY_ID} <<EOF
#!/bin/bash
#SBATCH --job-name=${NAME}_merge
#SBATCH --ntasks=1
#SBATCH --mem=2000
#SBATCH --time=${MERGE_WALLTIME}
#SBATCH --output=logs/${NAME}_merge.%j.out
#SBATCH --error=logs/${NAME}_merge.%j.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export BENCH_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} merge_shards=${N_SHARDS}
EOF
)

echo "Submitted array job ${ARRAY_ID} (tasks ${ARRAY} of ${N_SHARDS}) and merge job ${MERGE_ID%%;*}."

# Notes:
# - The merge only starts if every task in this submission succeeds. If some
#   fail, re-run just those (ARRAY=3,7 bash ...), which also submits a new merge;
#   then scancel the old, never-starting merge job.
