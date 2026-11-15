#!/bin/bash
# =============================================================================
# Slurm submission for scripts/gridSearchGraph.R -- one job, all metrics
# =============================================================================
# Usage (from any directory, on a Slurm login node):
#     bash cluster/slurm/submit.sh                                # er, dp, cp together
#     bash cluster/slurm/submit.sh 0.9 0.8 0.7 w_step=0.02        # marginal powers + overrides
#     bash cluster/slurm/submit.sh metrics_file=metrics/custom.R  # + custom metrics
#     PARTITION=short SBATCH_TIMELIMIT=02:00:00 bash cluster/slurm/submit.sh
#
# Positional numbers replace MP; key=value arguments override ARGS (last value
# wins; values must not contain spaces). Other #SBATCH lines can be overridden
# with SBATCH_* environment variables. The job is named gogt_k<k> and logs to
# logs/gogt_k<k>.<id>.out.
#
# The R script auto-detects the allocation via parallelly::availableWorkers()
# (reads SLURM_JOB_NODELIST / SLURM_JOB_CPUS_PER_NODE) and spawns a PSOCK
# cluster spanning all allocated cores on every node. Remote workers are
# started with srun (cluster/slurm/srun-rsh.sh), so no ssh between nodes is
# needed.
# =============================================================================

set -euo pipefail

# Marginal power per hypothesis (count defines k) and key=value overrides.
# k = 4 with w_step=0.1 / g_step=0.25 -> 286 weight vectors x 50,625 transition
# matrices = 14,478,750 candidates (~2.5 ms each at sim_n=10000 with er/dp/cp,
# i.e. ~10 core-hours).
MP="0.90 0.80 0.70 0.60"
ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"
PARTITION="${PARTITION:-normal}"   # <-- your default partition
source "$(dirname "${BASH_SOURCE[0]}")/../args.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K=$(wc -w <<< "$MP")
NAME="gogt_k${K}"
cd "$ROOT"
# Slurm does not create the --output/--error directory.
mkdir -p logs results

sbatch <<EOF
#!/bin/bash
#SBATCH --job-name=${NAME}
# 4 nodes x 16 tasks = 64 workers. Do NOT set --cpus-per-task=1: parallelly
# then counts only one worker per node.
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=16
# MB per worker; raise if graphs/k are larger.
#SBATCH --mem-per-cpu=4000
#SBATCH --partition=${PARTITION}
# Wall-clock limit (k=4 grid ~10-20 min on 64 cores).
#SBATCH --time=12:00:00
#SBATCH --output=logs/${NAME}.%j.out
#SBATCH --error=logs/${NAME}.%j.err

set -euo pipefail

# Load the R module/toolchain that provides graphicalMCP + parallelly on ALL nodes.
module load R 2>/dev/null || true

cd "${ROOT}"
export GOGT_ROOT="${ROOT}"

# Launch remote workers via srun; drop these two lines to use ssh instead.
chmod u+x cluster/slurm/srun-rsh.sh 2>/dev/null || true
export R_PARALLELLY_MAKENODEPSOCK_RSHCMD="${ROOT}/cluster/slurm/srun-rsh.sh"

Rscript scripts/gridSearchGraph.R ${MP} ${ARGS} ${EXTRA}
EOF

# Notes:
# - srun --overlap needs Slurm >= 20.11. Each worker runs as a 1-CPU job step
#   sharing the allocation, and inherits the job environment.
# - Workers connect back to the master node directly (ssh reverse tunnel off).
#   If the master node is unreachable from the other nodes (firewall), use ssh
#   (drop the srun lines above), request 1 task per node and add to the job body:
#       export GRIDSEARCH_REVTUNNEL=TRUE
# - graphicalMCP and parallelly must be installed in a library visible from
#   every compute node (a shared/network R library path).
