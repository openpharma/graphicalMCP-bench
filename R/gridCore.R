# =============================================================================
# Brute-force grid search over multiplicity graphs -- shared core
# =============================================================================
#
# A graph is (w, G): initial hypothesis weights w (sum to 1) and a row-stochastic
# transition matrix G (diagonal 0, each row sums to 1). For every candidate on a
# regular grid the objective of the full sequentially-rejective graphical
# procedure is evaluated by Monte-Carlo simulation
# (graphicalMCP::graph_calculate_power) and the best graph is kept.
#
# Two grid resolutions are used: a fine step for the hypothesis weights (w_step)
# and a coarser step for the transition weights (g_step).
#
# Objectives are selected by key; see GOGT_OBJECTIVES below. Everything here is
# objective-agnostic -- scripts/gridSearchGraphER.R and
# scripts/gridSearchGraphDP.R are thin wrappers that pick one.
#
# Derived from optimalMCP src/gridSearchGraphER.R.
#
# -----------------------------------------------------------------------------
# FEASIBILITY WARNING -- READ BEFORE CHANGING k OR THE STEP SIZES
# -----------------------------------------------------------------------------
# The candidate space is (# weight vectors) x (# transition matrices). With a
# fine grid (w_step = 0.01, g_step = 0.05) the counts are roughly:
#     k = 3 :  5,151 x  9,261  ~= 4.8e7   candidates  (overnight-scale run)
#     k = 4 :  1.8e5 x  2.9e9  ~= 5e14    candidates  (impractical)
#     k = 5 :  4.6e6 x  1.7e16 ~= 8e22    candidates  (impossible)
# Each candidate triggers a Monte-Carlo simulation, so k > 3 is gated behind
# allow_large_k and will refuse to run unless you coarsen the grid.
# =============================================================================


# Objective key -> field of graphicalMCP::graph_calculate_power()$power.
GOGT_OBJECTIVES <- list(
  er = list(field = "rejection_expected", label = "E[R]",
            name = "expected rejections"),
  dp = list(field = "power_at_least_1",   label = "DP",
            name = "disjunctive power"),
  cp = list(field = "power_all",          label = "CP",
            name = "conjunctive power")
)

#' Look up an objective definition, erroring on an unknown key.
#'
#' @param objective one of names(GOGT_OBJECTIVES)
#' @return list(field, label, name)
gogt_objective <- function(objective) {
  spec <- GOGT_OBJECTIVES[[objective]]
  if (is.null(spec)) {
    stop("Unknown objective '", objective, "'. Use one of: ",
         paste(names(GOGT_OBJECTIVES), collapse = ", "), ".")
  }
  spec
}


# -----------------------------------------------------------------------------
# Cluster setup (LSF / multi-node aware)
# -----------------------------------------------------------------------------

#' Build a PSOCK cluster spanning all allocated cores/nodes.
#'
#' Uses parallelly::availableWorkers(), which detects the LSF allocation
#' (LSB_MCPU_HOSTS / LSB_HOSTS) and returns one entry per allocated core across
#' every node. Off a scheduler it returns the local cores. Returns NULL when a
#' single worker is available (search then runs serially).
#'
#' Remote workers are connected back to the master DIRECTLY (revtunnel = FALSE).
#' With the default ssh reverse tunnel every worker on a given remote host tries
#' to bind the same listen port there, so all but the first fail with
#' "remote port forwarding failed for listen port <port>" and the setup hangs.
#' Compute nodes on an LSF cluster can reach the master node directly, so the
#' tunnel is unnecessary. Set GRIDSEARCH_REVTUNNEL=TRUE to restore the old
#' behaviour (then request a single core per node, or it will hang again).
#'
#' @param max_workers optional integer cap on the number of workers
#' @return a parallel cluster object, or NULL
make_cluster <- function(max_workers = NULL) {
  workers <- parallelly::availableWorkers()
  if (!is.null(max_workers) && is.finite(max_workers) &&
      length(workers) > max_workers) {
    workers <- workers[seq_len(max_workers)]
  }
  if (length(workers) <= 1L) return(NULL)

  hosts     <- unique(workers)
  nodename  <- unname(Sys.info()[["nodename"]])
  local_ids <- c("localhost", "127.0.0.1", nodename,
                 sub("\\..*$", "", nodename))
  remote    <- setdiff(hosts, local_ids)

  message(sprintf("Starting PSOCK cluster: %d workers across %d host(s): %s",
                  length(workers), length(hosts),
                  paste(hosts, collapse = ", ")))

  args <- list(workers = workers, connectTimeout = 120L)
  if (length(remote)) {
    revtunnel <- identical(toupper(Sys.getenv("GRIDSEARCH_REVTUNNEL", "FALSE")),
                           "TRUE")
    args$revtunnel <- revtunnel
    if (!revtunnel) args$master <- nodename
    # parallelly picks ssh for remote hosts; on LSF set env
    # PARALLELLY_MAKENODEPSOCK_RSHCMD to "blaunch" when ssh between compute
    # nodes is not permitted.
  }

  tryCatch(
    do.call(parallelly::makeClusterPSOCK, args),
    error = function(e) {
      message("Multi-node cluster setup failed (", conditionMessage(e), ").")
      local_n <- max(sum(workers %in% local_ids), 1L)
      if (local_n <= 1L) {
        message("Falling back to a serial run.")
        return(NULL)
      }
      message(sprintf("Falling back to %d local workers on %s.",
                      local_n, nodename))
      parallelly::makeClusterPSOCK(local_n, connectTimeout = 120L)
    }
  )
}


# -----------------------------------------------------------------------------
# Grid builders
# -----------------------------------------------------------------------------

#' All compositions of 1 into k non-negative parts on a regular grid.
#'
#' Enumerates every vector of length k with entries in {0, step, 2*step, ...}
#' summing to exactly 1 (i.e. lattice points of the probability simplex).
#'
#' @param k number of parts
#' @param step grid step; 1/step must be (close to) an integer
#' @return matrix with k columns, one simplex point per row
simplex_grid <- function(k, step) {
  m <- round(1 / step)
  if (abs(m * step - 1) > 1e-9) {
    stop("1/step must be an integer for a simplex grid (got step = ", step, ").")
  }
  # Recursively enumerate compositions of m into k parts, then scale by 1/m.
  build <- function(parts, remaining) {
    if (parts == 1L) return(matrix(remaining, nrow = 1))
    out <- vector("list", remaining + 1L)
    for (v in 0:remaining) {
      rest <- build(parts - 1L, remaining - v)
      out[[v + 1L]] <- cbind(v, rest, deparse.level = 0)
    }
    do.call(rbind, out)
  }
  comps <- build(k, m)
  comps / m
}

#' All row-stochastic transition matrices on the g_step grid.
#'
#' Each row i distributes its propagated alpha over the other k-1 hypotheses
#' (diagonal fixed to 0, row sums to 1). The full set is the Cartesian product
#' of the per-row simplices across the k rows.
#'
#' @param k number of hypotheses
#' @param step transition grid step
#' @return list of k x k matrices
transition_grid <- function(k, step) {
  if (k < 2L) return(list(matrix(0, k, k)))
  row_dists <- simplex_grid(k - 1L, step)   # distributions over k-1 targets
  n_rows    <- nrow(row_dists)
  # Index every combination of a per-row distribution for each of the k rows.
  idx <- expand.grid(rep(list(seq_len(n_rows)), k), KEEP.OUT.ATTRS = FALSE)
  lapply(seq_len(nrow(idx)), function(t) {
    G <- matrix(0, k, k)
    for (i in seq_len(k)) {
      targets <- setdiff(seq_len(k), i)     # off-diagonal columns for row i
      G[i, targets] <- row_dists[idx[t, i], ]
    }
    G
  })
}


# -----------------------------------------------------------------------------
# Candidate evaluation
# -----------------------------------------------------------------------------

#' Objective value of one graph (w, G) via a graphicalMCP simulation.
#'
#' @param w numeric weight vector (sum to 1)
#' @param G k x k row-stochastic transition matrix (diagonal 0)
#' @param alpha type I error
#' @param mp marginal powers
#' @param sim_n MC replications
#' @param seed RNG seed set immediately before simulating (common random numbers)
#' @param objective one of names(GOGT_OBJECTIVES)
#' @return numeric objective value
eval_graph <- function(w, G, alpha, mp, sim_n, seed, objective = "er") {
  k <- length(w)
  field <- GOGT_OBJECTIVES[[objective]]$field
  if (is.null(field)) stop("Unknown objective '", objective, "'.")
  graph <- graphicalMCP::graph_create(hypotheses = w, transition = G)
  set.seed(seed)
  sim <- graphicalMCP::graph_calculate_power(
    graph          = graph,
    alpha          = alpha,
    power_marginal = mp,
    test_types     = "bonferroni",
    sim_n          = sim_n,
    sim_corr       = diag(k)          # independence
  )
  sim$power[[field]]
}


# -----------------------------------------------------------------------------
# Search driver (streamed + parallel over the transition grid)
# -----------------------------------------------------------------------------

#' Grid-search the objective-optimal graph for a given k.
#'
#' Parallelizes over the transition-matrix grid: each worker sweeps all weight
#' vectors for one G and returns only its best rows, so memory stays small even
#' for tens of millions of candidates.
#'
#' @param objective one of names(GOGT_OBJECTIVES)
#' @param w_fixed optional numeric weight vector (length k, sums to 1). When
#'   supplied the weight simplex is skipped and only G is searched.
#' @return list(best = data.frame(top_n rows, objective column "obj"),
#'   n_candidates = integer, objective = character)
grid_search_k <- function(k, alpha, mp, w_step, g_step, sim_n, seed,
                          top_n, cl, allow_large_k, max_candidates,
                          w_fixed = NULL, objective = "er") {
  stopifnot(length(mp) == k)
  gogt_objective(objective)

  if (is.null(w_fixed)) {
    W <- simplex_grid(k, w_step)        # weight vectors  (rows)
  } else {
    if (length(w_fixed) != k) {
      stop(sprintf("[k=%d] w_fixed must have length %d; got %d.",
                   k, k, length(w_fixed)))
    }
    if (abs(sum(w_fixed) - 1) > 1e-9) {
      stop(sprintf("[k=%d] w_fixed must sum to 1; got %g.", k, sum(w_fixed)))
    }
    W <- matrix(w_fixed, nrow = 1)      # single fixed weight vector
    cat(sprintf("[k=%d] fixed weights supplied: %s (w grid skipped)\n",
                k, paste(round(w_fixed, 4), collapse = ", ")))
  }
  Glist <- transition_grid(k, g_step)   # transition matrices (list)
  n_cand <- nrow(W) * length(Glist)

  cat(sprintf("[k=%d] weight vectors = %s, transition matrices = %s, candidates = %s\n",
              k, format(nrow(W), big.mark = ","),
              format(length(Glist), big.mark = ","),
              format(n_cand, big.mark = ",")))

  if (n_cand > max_candidates && !allow_large_k) {
    stop(sprintf(
      "[k=%d] %s candidates exceeds max_candidates (%s). Coarsen w_step/g_step ",
      k, format(n_cand, big.mark = ","), format(max_candidates, big.mark = ",")),
      "or set allow_large_k = TRUE.")
  }

  # Worker: sweep all weight vectors for a single transition matrix G.
  process_G <- function(G) {
    obj <- apply(W, 1L, function(w)
      eval_graph(w, G, alpha, mp, sim_n, seed, objective))
    keep <- order(obj, decreasing = TRUE)[seq_len(min(top_n, length(obj)))]
    data.frame(obj = obj[keep], W[keep, , drop = FALSE],
               row.names = NULL, check.names = FALSE)
  }

  t0 <- Sys.time()
  if (!is.null(cl)) {
    parallel::clusterExport(
      cl,
      varlist = c("W", "alpha", "mp", "sim_n", "seed", "top_n", "objective",
                  "eval_graph", "GOGT_OBJECTIVES"),
      envir = environment()
    )
    parallel::clusterEvalQ(cl, requireNamespace("graphicalMCP", quietly = TRUE))
    per_G <- parallel::parLapply(cl, Glist, process_G)
  } else {
    per_G <- lapply(Glist, process_G)
  }
  cat(sprintf("[k=%d] search time: %.1f s\n", k,
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  # Attach the winning G to each kept weight vector, then take the global top_n.
  best_rows <- do.call(rbind, Map(function(df, G) {
    df$G <- replicate(nrow(df), G, simplify = FALSE)
    df
  }, per_G, Glist))
  best_rows <- best_rows[order(best_rows$obj, decreasing = TRUE), ]
  best_rows <- head(best_rows, top_n)
  rownames(best_rows) <- NULL

  list(best = best_rows, n_candidates = n_cand, objective = objective)
}


# -----------------------------------------------------------------------------
# Reporting / saving
# -----------------------------------------------------------------------------

#' Print the winning graph of a grid search.
#'
#' @param k number of hypotheses
#' @param res return value of grid_search_k()
report_best <- function(k, res) {
  spec <- gogt_objective(res$objective)
  best <- res$best[1, ]
  # Weight columns are everything except the objective "obj" and the graph "G".
  w_cols <- setdiff(names(res$best), c("obj", "G"))
  w <- as.numeric(best[, w_cols])
  G <- best$G[[1]]

  cat(sprintf("\n==== k = %d : %s-optimal graph ====\n", k, spec$label))
  cat(sprintf("%s = %.5f  (%s, from %s candidates)\n",
              spec$label, best$obj, spec$name,
              format(res$n_candidates, big.mark = ",")))
  cat("Hypothesis weights w:\n"); print(round(w, 4))
  cat("Transition matrix G:\n");  print(round(G, 4))
}

#' Write the top-n table of a grid search to RDS + CSV.
#'
#' @param stem_prefix file-name prefix, e.g. "gridSearchER"
#' @param tag run tag appended to the stem (marginal powers, fixed-weight flag)
save_best <- function(k, res, out_dir, save_full, tag = "",
                      stem_prefix = "gridSearch") {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  stem <- sprintf("%s_k%d%s", stem_prefix, k,
                  if (nzchar(tag)) paste0("_", tag) else "")
  saveRDS(res, file.path(out_dir, paste0(stem, ".rds")))
  flat <- res$best
  flat$G <- vapply(flat$G, function(G) paste(round(G, 4), collapse = ";"),
                   character(1))
  utils::write.csv(flat, file.path(out_dir, paste0(stem, "_top.csv")),
                   row.names = FALSE)
  if (save_full) {
    warning("save_full = TRUE can produce very large files; not the streamed ",
            "default. Only the top_n table is retained by the search.")
  }
}
