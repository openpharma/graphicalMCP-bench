# =============================================================================
# Bonferroni equality constraint for nloptr
# =============================================================================
# Vendored verbatim from optimalMCP R/constraintBonf.R (roxygen @export tags
# dropped). Required by optim_w_er() in expectedRejections.R.
# =============================================================================

#' Bonferroni constraint: the weights must sum to 1.
#'
#' @param w vector, weight assigned to each hypothesis
#' @param alpha numeric, type I error (unused; signature parity)
#' @param mp vector, marginal power of each hypothesis (unused)
#' @param rho numeric or matrix, correlation (unused)
#' @param min.w numeric, minimum weight (unused)
#' @return numeric, \code{sum(w) - 1}
constraint_bonferroni <- function(w, alpha, mp, rho, min.w) {
  return(sum(w) - 1.)
}


#' Gradient of the Bonferroni constraint.
#'
#' @inheritParams constraint_bonferroni
#' @return numeric vector of ones
constraint_bonferroni_grad <- function(w, alpha, mp, rho, min.w) {
  return(rep(1, length(w)))
}
