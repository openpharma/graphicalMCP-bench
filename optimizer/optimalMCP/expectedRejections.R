# =============================================================================
# Optimization of the Expected Number of Rejections for k hypotheses
# =============================================================================
#
# Vendored from optimalMCP src/expectedRejections.R. Keep in sync upstream.
#
# This script mirrors the disjunctive-power pipeline of the optimalMCP package
# but targets a different objective: the EXPECTED NUMBER OF REJECTIONS, E[R], of
# a single-step weighted-Bonferroni test, assuming the k hypotheses are
# INDEPENDENT.
#
# DEPENDENCIES: utils.R (solve_eta, inverse_derivative) and constraintBonf.R
# (constraint_bonferroni, constraint_bonferroni_grad) in this folder must be
# sourced first; optim_w_er() additionally needs the nloptr package.
#
# MATH
# ----
# Under a single-step weighted-Bonferroni test, hypothesis H_i is rejected when
# its test statistic exceeds the (weighted) critical value:
#     reject H_i  <=>  Z_i > z_{w_i alpha},   z_{w_i alpha} = qnorm(1 - w_i alpha)
# with Z_i ~ N(mu_i, 1) and mu_i = solve_eta(alpha, mp_i).
#
# By linearity of expectation, the expected number of rejections is the sum of
# the marginal rejection probabilities:
#     E[R] = sum_i P(Z_i > z_{w_i alpha}) = sum_i Phi(mu_i - z_{w_i alpha}).
#
# Because this is a sum of marginals, E[R] does NOT depend on the correlation
# structure under Bonferroni. The `rho` argument is therefore inert and is kept
# only for signature parity with the disjunctive-power functions.
# =============================================================================


# Options for the nloptr optimizer (same as R/weightOptim.R `opts`).
opts_er <- list("algorithm" = "NLOPT_LD_SLSQP",
                "xtol_rel" = 1e-6,
                "maxeval" = 1e4)


# -----------------------------------------------------------------------------
# Core computation
# -----------------------------------------------------------------------------

#' Calculate the expected number of rejections
#'
#' @param w vector of numeric, weight assigned to each hypothesis (sum to 1)
#' @param alpha numeric, type I error
#' @param mp vector of numeric, marginal power of each hypothesis
#' @param rho numeric or matrix, correlation or correlation matrix. Not used for
#'        Bonferroni under independence; kept for consistency with
#'        \code{disjunctive_power}.
#' @param test character, currently only "Bonferroni" is supported
#'
#' @details
#' Mirrors \code{disjunctive_power} but returns the expected number of
#' rejections of a single-step weighted-Bonferroni test:
#' \deqn{E[R] = \sum_{i=1}^{k} P(Z_i > z_{w_i \alpha}) = \sum_{i=1}^{k} \Phi(\mu_i - z_{w_i \alpha})}
#' where \eqn{\mu_i} is the non-centrality parameter derived from the marginal
#' power via \code{solve_eta}, and \eqn{z_{w_i \alpha} = \Phi^{-1}(1 - w_i \alpha)}.
#'
#' @return numeric in [0, k], the expected number of rejections
#' @seealso \code{\link{solve_eta}}, \code{\link{disjunctive_power}}
expected_rejections <- function(w, alpha, mp, rho = 0, test = "Bonferroni") {
  if (any(w < 0)) stop("Negative weights not allowed.")
  if (!(isTRUE(all.equal(sum(w), 1)))) {
    message("Sum of weights not equal to 1. Make sure you are not using Bonferroni test.")
  }
  if (test != "Bonferroni") {
    stop("Only the Bonferroni test is currently supported for expected rejections.")
  }

  n <- length(mp)
  if (length(w) != n) stop("lengths of weights and marginal powers need match")

  # Non-centrality parameters from marginal powers.
  mus <- vapply(mp, function(p) solve_eta(alpha = alpha, p = p), numeric(1))

  # Weighted-Bonferroni critical values.
  zs <- qnorm(1 - w * alpha)

  # E[R] = sum of marginal rejection probabilities (independent of rho).
  sum(pnorm(mus - zs))
}


# -----------------------------------------------------------------------------
# Loss function (negative expected number of rejections)
# -----------------------------------------------------------------------------

#' Loss function to maximize the expected number of rejections (Bonferroni)
#'
#' @param w vector of numeric, weight assigned to each hypothesis
#' @param alpha numeric, type I error
#' @param mp vector of numeric, marginal power of each hypothesis
#' @param rho numeric or matrix, correlation; inert for Bonferroni, kept for
#'        consistency with other loss functions
#' @param min.w numeric, default 1e-8, minimum weight to avoid numerical issues;
#'        kept for parameter consistency with other loss functions
#'
#' @details
#' The loss is the negative expected number of rejections, since the optimizer
#' minimizes the objective. Mirrors \code{loss_dp}.
#'
#' @return numeric loss value
#' @seealso \code{\link{expected_rejections}}
loss_er <- function(w, alpha, mp, rho, min.w = 1e-8) {
  -as.numeric(expected_rejections(w, alpha, mp, rho))
}


# -----------------------------------------------------------------------------
# Gradient of the loss function
# -----------------------------------------------------------------------------

#' kth partial derivative of the expected-rejections loss (Bonferroni)
#'
#' @param w vector, weight assigned to each hypothesis
#' @param k integer, the kth weight to differentiate with respect to
#' @param alpha numeric, type I error
#' @param mp vector of numeric, marginal power of each hypothesis
#' @param rho numeric or matrix, correlation; inert for Bonferroni
#' @param min.w numeric, default 1e-8, floor applied to \code{w[k]} to avoid
#'        numerical issues
#'
#' @details
#' Because E[R] is a sum of marginals and each term depends on a single weight,
#' the gradient decouples:
#' \deqn{\frac{\partial\,loss}{\partial w_k} = \phi(\mu_k - z_{w_k \alpha}) \cdot \frac{d z_{w_k \alpha}}{d w_k}}
#' where \eqn{\frac{d z_{w_k \alpha}}{d w_k} = -\alpha / \phi(\Phi^{-1}(1 - w_k \alpha))}
#' is provided by \code{inverse_derivative}. Unlike \code{loss_dp_d}, no
#' multivariate integration or conditional distribution is required.
#'
#' @return numeric, the kth partial derivative of the loss
#' @seealso \code{\link{solve_eta}}, \code{\link{inverse_derivative}}
loss_er_d <- function(w, k, alpha, mp, rho, min.w = 1e-8) {
  n <- length(mp)
  stopifnot(length(w) == n)
  stopifnot(k <= n)
  if (w[k] <= min.w) {
    w[k] <- min.w
  }

  mu_k <- solve_eta(alpha = alpha, p = mp[k])
  z_k <- qnorm(1 - w[k] * alpha)

  # d loss / d w_k = -d E[R] / d w_k
  #               = -[ d/dw_k Phi(mu_k - z_k) ]
  #               = -[ -phi(mu_k - z_k) * dz_k/dw_k ]
  #               = phi(mu_k - z_k) * dz_k/dw_k    (dz_k/dw_k < 0)
  dnorm(mu_k - z_k) * inverse_derivative(w = w, alpha = alpha, i = k)
}


#' Gradient of the expected-rejections loss (Bonferroni)
#'
#' @param w vector, weight assigned to each hypothesis
#' @param alpha numeric, type I error
#' @param mp vector of numeric, marginal power of each hypothesis
#' @param rho numeric or matrix, correlation; inert for Bonferroni
#' @param min.w numeric, default 1e-8, minimum weight to avoid numerical issues
#'
#' @details
#' Returns the full gradient vector by applying \code{loss_er_d} to each weight.
#' Mirrors \code{loss_dp_grad}.
#'
#' @return numeric vector of length \code{length(w)}
#' @seealso \code{\link{loss_er_d}}
loss_er_grad <- function(w, alpha, mp, rho, min.w = 1e-8) {
  vapply(seq_along(w),
         function(k) loss_er_d(w, k, alpha, mp, rho, min.w = min.w),
         numeric(1))
}


# -----------------------------------------------------------------------------
# Weight optimization
# -----------------------------------------------------------------------------

#' Optimize weights to maximize the expected number of rejections (Bonferroni)
#'
#' @param alpha numeric, type I error
#' @param mp vector of numeric, marginal power of each hypothesis
#' @param rho numeric or square matrix, correlation matrix; inert for Bonferroni
#'        but accepted for signature parity with \code{optim_w_dp}
#' @param test character, currently only "Bonferroni" is supported
#' @param initial_w vector, initial weights used as the optimization start point
#' @param constraint.w vector, per-hypothesis weight constraints. Use \code{NA}
#'        for weights to be optimized, a numeric value to fix a weight, and
#'        \code{0} to drop a hypothesis.
#' @param lb vector, lower bound of weight for each hypothesis
#' @param ub vector, upper bound of weight for each hypothesis
#' @param min.w numeric, minimum weight to avoid numerical issues
#' @param optim_opts list, options passed to \code{nloptr}
#'
#' @details
#' Given the significance level \code{alpha} and marginal powers \code{mp},
#' finds the weight allocation that maximizes the expected number of rejections
#' under a single-step weighted-Bonferroni test, subject to \eqn{\sum_i w_i = 1}.
#' Mirrors the Bonferroni branch of \code{optim_w_dp}.
#'
#' @return
#' \item{w}{Optimal weights (sum to 1)}
#' \item{inflation}{Always 1 for Bonferroni}
#' \item{alphas}{Per-hypothesis local significance levels \code{w * alpha}}
#' \item{power}{Expected number of rejections at the optimum}
#' \item{detail}{The raw \code{nloptr} result object}
#' @import nloptr
#' @seealso \code{\link{loss_er}}, \code{\link{loss_er_grad}},
#'   \code{\link{constraint_bonferroni}}, \code{\link{constraint_bonferroni_grad}},
#'   \code{\link{expected_rejections}}, \code{\link{optim_w_dp}}
optim_w_er <- function(alpha, mp, rho = NULL, test = "Bonferroni",
                       initial_w = NULL, constraint.w = NULL,
                       lb = NULL, ub = NULL,
                       min.w = 1e-8, optim_opts = opts_er) {
  if (test != "Bonferroni") {
    stop("Only the Bonferroni test is currently supported for expected rejections.")
  }

  # Normalize correlation input to a matrix (inert here, kept for parity).
  if (is.null(rho)) rho <- 0
  if (length(rho) == 1) {
    rho <- matrix(rho, length(mp), length(mp))
    diag(rho) <- 1
  }

  # Set up weight constraints.
  if (is.null(constraint.w)) {
    constraint.w <- rep(NA, length(mp))
  }
  if (sum(constraint.w, na.rm = TRUE) > 1) {
    stop("Sum of constraint over one!")
  }

  # If there is nothing left to optimize, return the fully specified solution.
  if (sum(is.na(constraint.w)) == 0) {
    if (sum(constraint.w) < 1) {
      stop("Nothing to optimize with constraint summation less than 1!")
    } else {
      w_full <- constraint.w / sum(constraint.w)
      return(list(w = w_full,
                  inflation = 1,
                  alphas = alpha * w_full,
                  power = expected_rejections(w_full, alpha, mp, rho = rho),
                  detail = "Fully specified by constraints."))
    }
  }

  # Keep hypotheses that are either free (NA) or have non-zero fixed weight.
  keep <- constraint.w != 0 | is.na(constraint.w)
  mp.p <- mp[keep]
  constraint.p <- constraint.w[keep]
  rho.p <- rho[keep, keep]
  n.hypo.p <- length(mp.p)

  # Lower/upper bounds for the reduced problem.
  if (is.null(lb)) {
    lb <- rep(0, n.hypo.p)
  } else {
    lb <- lb[keep]
  }
  if (is.null(ub)) {
    ub <- rep(1, n.hypo.p)
  } else {
    ub <- ub[keep]
  }
  # Pin bounds for fixed (non-NA) constraints.
  lb[!is.na(constraint.p)] <- constraint.p[!is.na(constraint.p)]
  ub[!is.na(constraint.p)] <- constraint.p[!is.na(constraint.p)]

  # Starting point.
  if (is.null(initial_w)) {
    if (sum(ub - lb) == 0) {
      initial_w.p <- ub
    } else {
      remain_weight <- 1 - sum(lb)
      initial_w.p <- (ub - lb) / sum(ub - lb) * remain_weight + lb
    }
  } else {
    initial_w.p <- initial_w[keep]
  }

  suppressMessages({
    res <- nloptr::nloptr(x0 = initial_w.p,
                          eval_f = loss_er,
                          eval_grad_f = loss_er_grad,
                          alpha = alpha, mp = mp.p, rho = rho.p,
                          lb = lb, ub = ub, min.w = min.w,
                          eval_g_eq = constraint_bonferroni,
                          eval_jac_g_eq = constraint_bonferroni_grad,
                          opts = optim_opts)
  })

  w.p <- res$solution
  ereject <- -res$objective

  # Map the reduced solution back onto the full set of hypotheses.
  w <- rep(0, length(mp))
  w[keep] <- w.p
  w <- w / sum(w)

  return(list(w = w,
              inflation = 1,
              alphas = w * alpha,
              power = ereject,
              detail = res))
}
