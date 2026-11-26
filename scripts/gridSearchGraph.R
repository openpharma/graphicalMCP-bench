#!/usr/bin/env Rscript
# =============================================================================
# Grid search for the best graphs under several metrics at once
# =============================================================================
#
# Brute-force grid search over the graphs (w, G) of the graphical approach in
# multiple testing, for k hypotheses (independent or correlated). Every
# candidate is run through the sequentially-rejective weighted-Bonferroni
# graphical procedure on one shared matrix of simulated p-values, and ALL
# metrics are evaluated on the same rejections. The top_n graphs per metric are
# kept and re-evaluated on independent p-values. See R/gridCore.R for the search
# machinery and the feasibility warning about k > 3.
#
# METRICS  (function(R) -> number to maximize; R = sim_n x k logical rejections)
#   er  expected number of rejections
#   dp  disjunctive power (depends on w only)
#   cp  conjunctive power
#   Custom: add to `metrics` below, or metrics_file=<file.R> defining `metrics`.
#
# USAGE
#     Rscript scripts/gridSearchGraph.R scenario=<id> [key=value ...]
#     Rscript scripts/gridSearchGraph.R <mp_1> <mp_2> <mp_3> [key=value ...]
#   scenario=<id> loads scenarios/<id>.R (see scenarios/_template.R), writes
#   reference/<id>/ and docs/scenarios/<id>.md. Without it, positional numeric
#   args are the marginal powers (their count defines k):
#     Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70 sim_n=10000
#   Optional key=value overrides: alpha, corr, sim_n, w_step, g_step, w_fixed,
#   seed, top_n, validate_n, validate_seed, out_dir, stem_prefix,
#   allow_large_k, max_candidates, save_results, max_workers, metrics (comma
#   list), metrics_file, shard, merge_shards, smoke.
#   Fixed weights: w_fixed=0.5,0.3,0.2 (only G searched) or w_fixed=0.5,NA,NA.
#   Job arrays: shard=i/N searches one shard; merge_shards=N combines them.
#   smoke=TRUE runs the checks and estimates the time / memory of the full run
#   from a sample of its grid (nothing written).
#   Works from any working directory.
#
# CLUSTER / MULTI-NODE
#   Workers are auto-detected with parallelly::availableWorkers(), which reads
#   the scheduler allocation (LSF, Slurm, ...) and spans ALL allocated nodes via
#   a PSOCK cluster. Submit with `bash cluster/{lsf,slurm}/submit.sh`, or as a
#   job array with `bash cluster/{lsf,slurm}/submit_array.sh`.
#   Requires graphicalMCP + parallelly installed on every node.
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
bench_source("R", "analytic.R")
bench_source("R", "gridCore.R")
bench_source("R", "gridRunner.R")
bench_source("R", "report.R")


# =============================================================================
# PARAMETERS  (edit defaults here; any of them can be overridden from the CLI)
# =============================================================================
cfg <- bench_config(
  alpha     = 0.025,
  run_k     = c(3),
  mp_list   = list(k3 = c(0.90, 0.80, 0.70)),
  # e.g. c(BENCH_METRICS, list(h1h2 = function(R) mean(R[, "H1"] & R[, "H2"])))
  metrics   = BENCH_METRICS,
  w_step    = 0.05,
  g_step    = 0.1,
  sim_n     = 1e4,
  seed      = 2024,
  top_n     = 50L,
  out_dir   = "results"
)
# =============================================================================

cfg <- bench_parse_cli(cfg)

# Auto-run only when executed as a script (Rscript), not on interactive source().
if (!interactive() && sys.nframe() == 0L) {
  bench_main(cfg)
}
