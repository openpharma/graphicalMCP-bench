# Worked example: correlated primaries and a gated secondary endpoint.
scenario <- list(
  title       = "Example: two doses and a secondary endpoint",
  author      = "AI test",
  date        = "2026-11-16",
  description = paste(
    "H1 and H2 test the high and low dose against a shared control, so their",
    "statistics are correlated (rho = 0.5). H3 is a secondary endpoint of the",
    "high dose: it gets no initial alpha and can only receive alpha from H1,",
    "so the low dose (H2) passes everything it frees to H1."
  ),

  alpha = 0.025,
  mp    = c(0.90, 0.80, 0.70),
  corr  = matrix(c(1,   0.5, 0,
                   0.5, 1,   0,
                   0,   0,   1), 3, byrow = TRUE),

  metrics = c(BENCH_METRICS, list(
    h1h3 = function(R) mean(R[, "H1"] & R[, "H3"])   # high dose: primary and secondary
  )),

  w_fixed = c(NA, NA, 0),
  G_fixed = matrix(c(NA, NA, NA,
                     NA, NA,  0,
                     NA, NA, NA), 3, byrow = TRUE),

  w_step = 0.05,
  g_step = 0.1,
  sim_n  = 1e4,
  seed   = 2024
)
