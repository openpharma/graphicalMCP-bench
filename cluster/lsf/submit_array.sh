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
#
# There is no node count: each element takes CORES slots on one host and LSF
# places the elements; MAX_RUNNING caps how many run at the same time.
# With scenario=<id> the scenario file sets everything and MP / ARGS below are
# ignored. Otherwise positional numbers replace MP. key=value arguments
# override ARGS / the scenario for both the shards and the merge (last value
# wins; values must not contain spaces).
# Shards go to <out_dir>/shards/, the merged result to <out_dir>/ under the same
# name as a single run.
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
#BSUB -R "rusage[mem=1000]"
#BSUB -W 1:00
#BSUB -o logs/${NAME}.%J_%I.out
#BSUB -e logs/${NAME}.%J_%I.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

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
#BSUB -n 1
#BSUB -R "rusage[mem=2000]"
#BSUB -W 0:30
#BSUB -o logs/${NAME}_merge.%J.out
#BSUB -e logs/${NAME}_merge.%J.err

set -euo pipefail
module load R 2>/dev/null || true
cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA} merge_shards=${N_SHARDS}
EOF

# Notes:
# - done(<array id>) waits for every element. If some fail, re-run just those
#   (ARRAY=3,7 bash ...), which also submits a new merge; then bkill the old,
#   never-starting merge job.
