#!/bin/bash
# =============================================================================
# LSF job-array submission for scripts/gridSearchGraph.R
# =============================================================================
# Splits the transition-matrix grid into N_SHARDS independent array elements
# (one host each, no communication between hosts); a dependent job then merges
# the shards into exactly the result a single run would give.
#
# Usage (from any directory, on an LSF login node):
#     bash cluster/lsf/submit_array.sh scenario=my_id                 # a scenario file
#     bash cluster/lsf/submit_array.sh                                # all shards + merge
#     bash cluster/lsf/submit_array.sh 0.9 0.8 0.7 w_step=0.02        # marginal powers + overrides
#     bash cluster/lsf/submit_array.sh metrics_file=metrics/custom.R  # + custom metrics
#     ARRAY=3,7 bash cluster/lsf/submit_array.sh                      # re-run shards 3, 7 + merge
#     N_SHARDS=32 CORES=2 QUEUE=short bash cluster/lsf/submit_array.sh
#     MAX_RUNNING=4 bash cluster/lsf/submit_array.sh                  # at most 4 elements at once
#     WALLTIME=0:20 MERGE_WALLTIME=0:15 bash cluster/lsf/submit_array.sh
#     SHARD_MEM=8000 MERGE_MEM=4000 bash cluster/lsf/submit_array.sh  # MB per element / merge
#
# There is no node count: each element takes CORES slots on one host and LSF
# places the elements; MAX_RUNNING caps how many run at the same time.
# With scenario=<id> the scenario file sets everything and MP / ARGS below are
# ignored. Otherwise positional numbers replace MP. key=value arguments
# override ARGS / the scenario for both the shards and the merge (last value
# wins; values must not contain spaces). WALLTIME / MERGE_WALLTIME set the time
# limits and SHARD_MEM / MERGE_MEM the memory (MB per element, all its slots,
# and MB for the merge; take them from the smoke=TRUE estimate plus a margin).
# Each run gets its own folder: shards go to <out_dir>/<stem>/shards/ and the
# merged result to <out_dir>/<stem>/ (<stem> as in a single run, e.g.
# gridSearch_k4_mp90_80_70_60). For a scenario, shards go to
# results/<id>/shards/ and the merged result to reference/<id>/.
# If any element fails, the merge job is terminated automatically.
# =============================================================================

set -euo pipefail

# Marginal power per hypothesis (count defines k) and key=value overrides.
MP="0.90 0.80 0.70 0.60"
ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"
# Default 16 shards x 4 cores; the grid above is ~10 core-hours, i.e. ~10 min
# per shard. Re-runs must use the same N_SHARDS as the original submission.
N_SHARDS="${N_SHARDS:-16}"
CORES="${CORES:-4}"
QUEUE="${QUEUE:-}"                 # empty = the cluster's default queue
ARRAY="${ARRAY:-1-${N_SHARDS}}"
MAX_RUNNING="${MAX_RUNNING:-}"     # empty = no limit
WALLTIME="${WALLTIME:-8:00}"       # HH:MM per element
MERGE_WALLTIME="${MERGE_WALLTIME:-8:00}"
# rusage[mem] is reserved per host by default and each element runs on one
# host, so SHARD_MEM is the total for all CORES slots.
SHARD_MEM="${SHARD_MEM:-$((CORES * 1000))}"   # MB per element
MERGE_MEM="${MERGE_MEM:-2000}"                # MB for the merge (incl. validation)
source "$(dirname "${BASH_SOURCE[0]}")/../args.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# LSF does not create the -o/-e directory, so it must exist before submission.
mkdir -p logs results

OUT=$(bsub ${QUEUE:+-q $QUEUE} <<EOF
#!/bin/bash
#BSUB -J "${NAME}[${ARRAY}]${MAX_RUNNING:+%$MAX_RUNNING}"
# One host per element, local workers only; -n sets the worker count.
#BSUB -n ${CORES}
#BSUB -R "span[hosts=1]"
#BSUB -R "rusage[mem=${SHARD_MEM}]"
#BSUB -W ${WALLTIME}
#BSUB -o logs/${NAME}.%J_%I.out
#BSUB -e logs/${NAME}.%J_%I.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export BENCH_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} shard=\${LSB_JOBINDEX}/${N_SHARDS}
EOF
)
echo "$OUT"
ARRAY_ID=$(sed -n 's/^Job <\([0-9]*\)>.*/\1/p' <<< "$OUT")
[ -n "$ARRAY_ID" ] || { echo "Could not parse the array job id; merge not submitted." >&2; exit 1; }

bsub ${QUEUE:+-q $QUEUE} <<EOF
#!/bin/bash
#BSUB -J ${NAME}_merge
#BSUB -w "done(${ARRAY_ID})"
# -ti: terminate the merge once an element fails and done() can never be met.
#BSUB -ti
#BSUB -n 1
#BSUB -R "rusage[mem=${MERGE_MEM}]"
#BSUB -W ${MERGE_WALLTIME}
#BSUB -o logs/${NAME}_merge.%J.out
#BSUB -e logs/${NAME}_merge.%J.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export BENCH_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} merge_shards=${N_SHARDS}
EOF

# Notes:
# - done(<array id>) waits for every element; if one fails (error, run or
#   memory limit), -ti terminates the merge. Find the failed elements and
#   their peak memory with
#       bjobs -a <array id>      bhist -l "<array id>[3]"
#   then re-run just those (ARRAY=3,7 bash ..., raise WALLTIME / SHARD_MEM if
#   needed), which also submits a new merge. The merge checks that all
#   N_SHARDS shard files exist, so earlier successful shards are reused.
