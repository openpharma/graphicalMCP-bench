# =============================================================================
# Analytic disjunctive / conjunctive power under independence
# =============================================================================
# Closed forms for the single-step weighted-Bonferroni test with INDEPENDENT
# test statistics. They mirror optimalMCP's disjunctive_power() restricted to
# `test = "Bonferroni"` and `rho = 0`, which is exactly the regime the grid
# search simulates (sim_corr = diag(k)). Restricting to independence keeps the
# cross-check free of mvtnorm, so compute nodes only need graphicalMCP.
#
# DEPENDENCIES: R/utils.R (solve_eta).
# =============================================================================

#' Per-hypothesis rejection probability of a single-step weighted-Bonferroni test.
#'
#' \eqn{P(Z_i > z_{w_i \alpha}) = \Phi(\mu_i - \Phi^{-1}(1 - w_i \alpha))}
#'
#' @param w numeric vector of weights (sum to 1)
#' @param alpha numeric, one-sided type I error
#' @param mp numeric vector of marginal powers
#' @return numeric vector of length \code{length(w)}
local_rejection_prob <- function(w, alpha, mp) {
  if (any(w < 0)) stop("Negative weights not allowed.")
  if (length(w) != length(mp)) {
    stop("lengths of weights and marginal powers need match")
  }
  mus <- vapply(mp, function(p) solve_eta(alpha = alpha, p = p), numeric(1))
  pnorm(mus - qnorm(1 - w * alpha))
}


#' Disjunctive power (reject at least one) under independence.
#'
#' \eqn{1 - \prod_i (1 - P(Z_i > z_{w_i \alpha}))}
#'
#' @inheritParams local_rejection_prob
#' @return numeric in [0, 1]
disjunctive_power_indep <- function(w, alpha, mp) {
  1 - prod(1 - local_rejection_prob(w, alpha, mp))
}


#' Conjunctive power (reject all) under independence.
#'
#' @inheritParams local_rejection_prob
#' @return numeric in [0, 1]
conjunctive_power_indep <- function(w, alpha, mp) {
  prod(local_rejection_prob(w, alpha, mp))
}
