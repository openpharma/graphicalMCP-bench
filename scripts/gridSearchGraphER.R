#!/usr/bin/env Rscript
# =============================================================================
# Grid search for the graph that maximizes the Expected Number of Rejections
# =============================================================================
#
# Brute-force grid search over multiplicity graphs (w, G) for k INDEPENDENT
# hypotheses. For every candidate on the grid the expected number of rejections
# E[R] of the full sequentially-rejective graphical procedure is computed by
# Monte-Carlo simulation (graphicalMCP::graph_calculate_power); the graph with
# the largest E[R] is kept. See R/gridCore.R for the search machinery and the
# feasibility warning about k > 3.
#
# USAGE
#     Rscript scripts/gridSearchGraphER.R <mp_1> <mp_2> <mp_3> [key=value ...]
#   Positional numeric args are the marginal powers (their count defines k):
#     Rscript scripts/gridSearchGraphER.R 0.90 0.80 0.70 sim_n=10000 w_step=0.05
#   Optional key=value overrides: sim_n, w_step, g_step, w_fixed, seed, top_n,
#   out_dir, allow_large_k, max_candidates, save_full, save_results, max_workers.
#   Fixed weights (skip the w grid): w_fixed=0.5,0.3,0.2 -> only G is searched.
#   Works from any working directory.
#
# LSF / MULTI-NODE
#   Workers are auto-detected with parallelly::availableWorkers(), which reads
#   the LSF host allocation (LSB_MCPU_HOSTS / LSB_HOSTS) and spans ALL allocated
#   nodes via a PSOCK cluster. Submit with bsub/gridSearchGraphER.bsub. Requires
#   graphicalMCP + parallelly installed on every node.
# =============================================================================

# --- Bootstrap: locate the repo root, then load the shared code --------------
local({
  this <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  root <- if (length(this)) {
    dirname(dirname(normalizePath(sub("^--file=", "", this[1]), winslash = "/")))
  } else {
    getwd()
  }
  source(file.path(root, "R", "rootPath.R"), local = globalenv())
})
gogt_source("R", "utils.R")
gogt_source("R", "constraintBonf.R")
gogt_source("R", "expectedRejections.R")
gogt_source("R", "analyticDP.R")
gogt_source("R", "gridCore.R")
gogt_source("R", "gridRunner.R")


# =============================================================================
# PARAMETERS  (edit defaults here; any of them can be overridden from the CLI)
# =============================================================================
cfg <- gogt_config(
  objective = "er",
  alpha     = 0.025,
  run_k     = c(3),
  mp_list   = list(k3 = c(0.90, 0.80, 0.70)),
  w_step    = 0.05,
  g_step    = 0.1,
  sim_n     = 1e4,
  seed      = 2024,
  top_n     = 50L,
  out_dir   = "results"
)
# =============================================================================

cfg <- gogt_parse_cli(cfg)

# Auto-run only when executed as a script (Rscript), not on interactive source().
if (!interactive() && sys.nframe() == 0L) {
  gogt_main(cfg)
}
