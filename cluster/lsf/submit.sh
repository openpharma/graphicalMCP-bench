#!/bin/bash
# =============================================================================
# LSF submission for scripts/gridSearchGraph.R -- one job, all metrics
# =============================================================================
# Usage (from any directory, on an LSF login node):
#     bash cluster/lsf/submit.sh                                # 1 host x 16 cores
#     bash cluster/lsf/submit.sh 0.9 0.8 0.7 w_step=0.02        # marginal powers + overrides
#     bash cluster/lsf/submit.sh metrics_file=metrics/custom.R  # + custom metrics
#     QUEUE=short bash cluster/lsf/submit.sh
#     NODES=2 CORES=32 bash cluster/lsf/submit.sh               # 2 hosts x 32 cores
#
# Positional numbers replace MP; key=value arguments override ARGS (last value
# wins; values must not contain spaces). The job is named gogt_k<k> and logs to
# logs/gogt_k<k>.<id>.out. Edit the #BSUB lines for other resources.
#
# The R script auto-detects the LSF allocation via parallelly::availableWorkers()
# (reads LSB_MCPU_HOSTS / LSB_HOSTS) and spawns a PSOCK cluster spanning all
# allocated cores on every node.
# =============================================================================

set -euo pipefail

# Marginal power per hypothesis (count defines k) and key=value overrides.
# k = 4 with w_step=0.1 / g_step=0.25 -> 286 weight vectors x 50,625 transition
# matrices = 14,478,750 candidates (~2.5 ms each at sim_n=10000 with er/dp/cp,
# i.e. ~10 core-hours).
MP="0.90 0.80 0.70 0.60"
ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"
QUEUE="${QUEUE:-}"                 # empty = the cluster's default queue
NODES="${NODES:-}"                 # empty = one host
CORES="${CORES:-16}"               # cores (workers) per host
source "$(dirname "${BASH_SOURCE[0]}")/../args.sh"

# LSF has no node count: total slots / slots per host = NODES hosts.
if [ -n "$NODES" ]; then
  SLOTS=$((NODES * CORES)); SPAN="span[ptile=${CORES}]"
else
  SLOTS=${CORES}; SPAN="span[hosts=1]"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K=$(wc -w <<< "$MP")
NAME="gogt_k${K}"
cd "$ROOT"
# LSF does not create the -o/-e directory, so it must exist before submission.
mkdir -p logs results

bsub ${QUEUE:+-q $QUEUE} <<EOF
#!/bin/bash
#BSUB -J ${NAME}
#BSUB -n ${SLOTS}
#BSUB -R "${SPAN}"
#BSUB -R "rusage[mem=4000]"       # MB per slot; raise if graphs/k are larger
#BSUB -W 12:00                    # wall-clock limit HH:MM (k=4 grid ~40 min on 16 cores)
#BSUB -o logs/${NAME}.%J.out
#BSUB -e logs/${NAME}.%J.err

set -euo pipefail

# Load the R module/toolchain that provides graphicalMCP + parallelly on ALL nodes.
module load R 2>/dev/null || true

cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA}
EOF

# Notes:
# - Multi-node PSOCK workers are launched over ssh by default. If passwordless
#   ssh between compute nodes is blocked at your site, use LSF's launcher by
#   adding this line to the job body above the Rscript call:
#       export R_PARALLELLY_MAKENODEPSOCK_RSHCMD=blaunch
# - Workers connect back to the master node directly (ssh reverse tunnel off).
#   The tunnel would make every worker on a node bind the same listen port, so
#   all but the first fail with "remote port forwarding failed for listen port"
#   and the job hangs. If the master node is unreachable from the compute nodes
#   (firewall), request 1 core per node and add to the job body:
#       export GRIDSEARCH_REVTUNNEL=TRUE
# - graphicalMCP and parallelly must be installed in a library visible from
#   every compute node (a shared/network R library path).
