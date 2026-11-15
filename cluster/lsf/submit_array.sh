#!/bin/bash
# =============================================================================
# LSF job-array submission for scripts/gridSearchGraph.R
# =============================================================================
# Splits the transition-matrix grid into N_SHARDS independent array elements
# (one host each, no communication between hosts); a dependent job then merges
# the shards into exactly the result a single run would give.
#
# Usage (from any directory, on an LSF login node):
#     bash cluster/lsf/submit_array.sh                                # all shards + merge
#     bash cluster/lsf/submit_array.sh metrics_file=metrics/custom.R  # any key=value
#     ARRAY=3,7 bash cluster/lsf/submit_array.sh                      # re-run shards 3, 7 + merge
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
QUEUE="normal"                    # <-- set to your queue
ARRAY="${ARRAY:-1-${N_SHARDS}}"
EXTRA="$*"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K=$(wc -w <<< "$MP")
NAME="gogt_k${K}"
cd "$ROOT"
# LSF does not create the -o/-e directory, so it must exist before submission.
mkdir -p logs results

OUT=$(bsub <<EOF
#!/bin/bash
#BSUB -J "${NAME}[${ARRAY}]"
# One host per element, local workers only; -n sets the worker count.
#BSUB -n ${CORES}
#BSUB -R "span[hosts=1]"
#BSUB -R "rusage[mem=4000]"
#BSUB -q ${QUEUE}
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

bsub <<EOF
#!/bin/bash
#BSUB -J ${NAME}_merge
#BSUB -w "done(${ARRAY_ID})"
#BSUB -n 1
#BSUB -R "rusage[mem=4000]"
#BSUB -q ${QUEUE}
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
