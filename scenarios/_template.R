# =============================================================================
# Scenario template: copy to scenarios/<id>.R and edit
# =============================================================================
# <id> is the file name: lowercase letters, digits and "_" (e.g. onco_dose_k3).
# Results go to results/<id>/ and docs/scenarios/<id>.md.
#
# Smoke test (coarse grid, nothing written):
#     Rscript scripts/gridSearchGraph.R scenario=<id> w_step=0.25 g_step=0.5 sim_n=2000 validate_n=0 save_results=FALSE
# Full run, locally or on a cluster:
#     Rscript scripts/gridSearchGraph.R scenario=<id>
#     bash cluster/slurm/submit.sh scenario=<id>
#
# Required: title, author, alpha, mp. Every other field can be deleted; the
# values below are the defaults.
# =============================================================================

scenario <- list(
  title       = "Short descriptive title",
  author      = "Your Name",
  date        = "YYYY-MM-DD",
  description = "What the hypotheses are and why this example matters.",

  ## -- Problem ----------------------------------------------------------------
  alpha = 0.025,                    # one-sided family-wise type I error
  mp    = c(0.90, 0.80, 0.70),      # marginal power of H1..Hk; its length is k

  # Correlation of the test statistics: NULL = independence, one number =
  # equicorrelation, or a k x k matrix. The tests stay weighted Bonferroni.
  corr = NULL,
  # corr = matrix(c(1,   0.5, 0,
  #                 0.5, 1,   0,
  #                 0,   0,   1), 3, byrow = TRUE),

  ## -- Metrics ----------------------------------------------------------------
  # function(R) -> one number to maximize; R is the sim_n x k logical rejection
  # matrix with columns H1..Hk. The first metric orders the result tables.
  # Defaults: er (expected rejections), dp (disjunctive), cp (conjunctive power).
  metrics = c(GOGT_METRICS, list(
    h1h2 = function(R) mean(R[, "H1"] & R[, "H2"])   # P(reject H1 and H2)
  )),

  ## -- Constraints: NA = free, a number = fixed (on the grid) -------------------
  # Free entries share what the fixed ones leave, so they still sum to 1.
  w_fixed = NULL,                   # e.g. c(NA, NA, 0): no initial alpha for H3
  G_fixed = NULL,                   # k x k, rows = from; e.g. no H3 -> H1:
  # G_fixed = matrix(c(NA, NA, NA,
  #                    NA, NA, NA,
  #                     0, NA, NA), 3, byrow = TRUE),

  ## -- Grid and simulation ----------------------------------------------------
  w_step         = 0.05,            # weight grid step (1/step an integer)
  g_step         = 0.1,             # transition grid step
  sim_n          = 1e4,             # simulations shared by all candidates
  seed           = 2024,
  top_n          = 50,              # graphs kept per metric
  validate_n     = 1e5,             # fresh simulations to re-evaluate them (0 = skip)
  validate_seed  = NULL,            # NULL = seed + 1
  allow_large_k  = FALSE,           # TRUE allows more than max_candidates (k >= 4)
  max_candidates = 1e8
)
