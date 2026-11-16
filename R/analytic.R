# =============================================================================
# Closed forms for the single-step weighted-Bonferroni test (G = 0)
# =============================================================================
# Reference values for the G = 0 cross-check of the grid search. E[R] holds
# for any correlation; DP / CP assume INDEPENDENT test statistics, so with
# correlation the cross-check skips them. Independence keeps the check free
# of mvtnorm, so compute nodes only need graphicalMCP.
#
# Self-contained on purpose: the grid search must not depend on optimizer/.
# =============================================================================

#' Non-centrality parameter implied by a marginal power.
#'
#' \eqn{\eta = \Phi^{-1}(1 - \alpha) - \Phi^{-1}(1 - mp)}
#'
#' @param alpha numeric, one-sided type I error
#' @param mp numeric vector of marginal powers
#' @return numeric vector of non-centrality parameters
noncentrality <- function(alpha, mp) {
  qnorm(1 - alpha) - qnorm(1 - mp)
}

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
  mus <- noncentrality(alpha, mp)
  pnorm(mus - qnorm(1 - w * alpha))
}


#' Expected number of rejections (any correlation).
#'
#' @inheritParams local_rejection_prob
#' @return numeric in [0, k]
expected_rejections_single <- function(w, alpha, mp) {
  sum(local_rejection_prob(w, alpha, mp))
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
