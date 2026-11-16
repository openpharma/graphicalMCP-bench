# =============================================================================
# Compare analytic Expected Number of Rejections vs. graphicalMCP simulation
# =============================================================================
#
# This standalone script validates `expected_rejections()` (see
# expectedRejections.R in this folder) against a Monte-Carlo simulation from the
# graphicalMCP package.
#
# WHY THEY SHOULD AGREE
# ---------------------
# `expected_rejections()` models a SINGLE-STEP weighted-Bonferroni test with NO
# alpha propagation between hypotheses: H_i is rejected iff Z_i > z_{w_i alpha},
# and E[R] = sum_i Phi(mu_i - z_{w_i alpha}).
#
# In graphicalMCP, a graph whose transition matrix is all zeros performs exactly
# this single-step weighted-Bonferroni test (no alpha is passed on after a
# rejection). Simulating that graph under INDEPENDENCE (sim_corr = identity) and
# marginal powers `mp` should reproduce the analytic E[R]:
#   - power$rejection_expected  ==  analytic E[R]
#   - power$power_local[i]      ==  Phi(mu_i - z_{w_i alpha})   (per hypothesis)
#
# USAGE
#   Rscript optimizer/optimalMCP/compareExpectedRejections.R
# (works from any working directory)
# =============================================================================

# --- Dependencies ------------------------------------------------------------
local({
  this <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  dir  <- if (length(this)) {
    dirname(normalizePath(sub("^--file=", "", this[1]), winslash = "/"))
  } else {
    getwd()
  }
  while (!file.exists(file.path(dir, "R", "rootPath.R")) && dirname(dir) != dir) {
    dir <- dirname(dir)
  }
  source(file.path(dir, "R", "rootPath.R"), local = globalenv())
})
gogt_source("optimizer", "optimalMCP", "utils.R")
gogt_source("optimizer", "optimalMCP", "constraintBonf.R")
gogt_source("optimizer", "optimalMCP", "expectedRejections.R")

if (!requireNamespace("graphicalMCP", quietly = TRUE)) {
  stop("Package 'graphicalMCP' is required for this comparison. ",
       "Install it with install.packages('graphicalMCP').")
}


# --- Comparison helper -------------------------------------------------------

#' Compare analytic E[R] against a graphicalMCP simulation for one scenario
#'
#' @param w vector of weights (sum to 1)
#' @param alpha type I error
#' @param mp vector of marginal powers
#' @param sim_n number of Monte-Carlo simulations
#' @param seed random seed for reproducibility
#'
#' @return a list with the analytic and simulated quantities (invisibly); also
#'   prints a side-by-side summary.
compare_expected_rejections <- function(w, alpha, mp, sim_n = 1e5, seed = 2024) {
  k <- length(mp)
  stopifnot(length(w) == k)

  # --- Analytic (single-step weighted Bonferroni, independence) -------------
  er_analytic <- expected_rejections(w, alpha, mp, test = "Bonferroni")
  mus <- vapply(mp, function(p) solve_eta(alpha = alpha, p = p), numeric(1))
  zs <- qnorm(1 - w * alpha)
  local_analytic <- pnorm(mus - zs)          # per-hypothesis rejection prob

  # --- Simulation via graphicalMCP ------------------------------------------
  # Zero transition matrix => pure single-step weighted Bonferroni (no
  # propagation), matching the analytic model.
  transition <- matrix(0, k, k)
  graph <- graphicalMCP::graph_create(hypotheses = w, transition = transition)

  set.seed(seed)
  sim <- graphicalMCP::graph_calculate_power(
    graph          = graph,
    alpha          = alpha,
    power_marginal = mp,
    test_types     = "bonferroni",
    sim_n          = sim_n,
    sim_corr       = diag(k)                 # independence
  )
  er_sim    <- sim$power$rejection_expected
  local_sim <- as.numeric(sim$power$power_local)

  # --- Report ---------------------------------------------------------------
  se <- sqrt(sum(local_analytic * (1 - local_analytic))) / sqrt(sim_n)  # MC SE of E[R]

  per_hyp <- data.frame(
    hypothesis = paste0("H", seq_len(k)),
    weight     = round(w, 4),
    mp         = mp,
    analytic   = round(local_analytic, 5),
    simulated  = round(local_sim, 5),
    diff       = round(local_sim - local_analytic, 5)
  )

  cat("Per-hypothesis rejection probability:\n")
  print(per_hyp, row.names = FALSE)
  cat(sprintf(
    "\nExpected number of rejections E[R]:\n  analytic  = %.5f\n  simulated = %.5f\n  diff      = %+.5f  (MC SE approx %.5f, sim_n = %g)\n",
    er_analytic, er_sim, er_sim - er_analytic, se, sim_n))
  cat(strrep("-", 60), "\n")

  invisible(list(
    er_analytic    = er_analytic,
    er_sim         = er_sim,
    local_analytic = local_analytic,
    local_sim      = local_sim,
    mc_se          = se
  ))
}


# --- Scenarios ---------------------------------------------------------------

alpha <- 0.025
mp    <- c(0.8, 0.7, 0.9)
k     <- length(mp)

cat("==== Scenario 1: equal weights ====\n")
compare_expected_rejections(w = rep(1 / k, k), alpha = alpha, mp = mp)

cat("\n==== Scenario 2: optimized weights (maximize E[R]) ====\n")
opt <- optim_w_er(alpha, mp)
cat("Optimized weights:", round(opt$w, 4), "\n\n")
compare_expected_rejections(w = opt$w, alpha = alpha, mp = mp)

cat("\n==== Scenario 3: 5 hypotheses, uneven weights ====\n")
mp5 <- c(0.6, 0.75, 0.85, 0.9, 0.5)
w5  <- c(0.30, 0.25, 0.20, 0.15, 0.10)
compare_expected_rejections(w = w5, alpha = alpha, mp = mp5)
