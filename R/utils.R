# =============================================================================
# Shared numeric helpers
# =============================================================================
# Vendored verbatim from optimalMCP R/utils.R (roxygen @export/@import tags
# dropped; gogt is a script repo, not a package). Keep in sync if the upstream
# definitions change.
# =============================================================================

#' Convert a single correlation into a correlation matrix.
#'
#' @param rho numeric, correlation
#' @param n integer, number of hypotheses
#' @return n x n correlation matrix
sigma_matrix <- function(rho, n) {
  if (n <= 0 || rho < -1 || rho > 1) {
    stop("n must be a positive integer and rho must be between -1 and 1.")
  }
  sigma <- matrix(rho, n, n)
  diag(sigma) <- 1
  sigma
}


#' Non-centrality parameter implied by a marginal power.
#'
#' \eqn{\eta = \Phi^{-1}(1 - \alpha) - \Phi^{-1}(1 - p)}
#'
#' @param alpha numeric, one-sided type I error
#' @param p numeric, marginal power
#' @return numeric non-centrality parameter
solve_eta <- function(alpha, p) {
  qnorm(1 - alpha) - qnorm(1 - p)
}


#' Derivative of the critical value \eqn{z_{w_i \alpha}} with respect to \eqn{w_i}.
#'
#' \eqn{d z_{w_i \alpha} / d w_i = -\alpha / \phi(\Phi^{-1}(1 - w_i \alpha))}
#'
#' @param w numeric vector of weights
#' @param alpha numeric, type I error
#' @param i integer, index of the weight
#' @return numeric derivative (always negative)
inverse_derivative <- function(w, alpha, i) {
  -alpha / dnorm(qnorm(1 - w[i] * alpha))
}
