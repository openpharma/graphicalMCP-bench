# =============================================================================
# Brute-force grid search over multiplicity graphs -- shared core
# =============================================================================
#
# A graph is (w, G): initial hypothesis weights w (sum to 1) and a row-stochastic
# transition matrix G (diagonal 0, each row sums to 1). Every candidate on a
# regular grid is run through the sequentially-rejective weighted-Bonferroni
# graphical procedure on ONE shared matrix of simulated p-values (common random
# numbers), and ALL metrics are evaluated together on the resulting rejections.
#
# Two grid resolutions are used: a fine step for the hypothesis weights (w_step)
# and a coarser step for the transition weights (g_step).
#
# A metric is any function(R) -> single number to MAXIMIZE, where R is the
# sim_n x k logical rejection matrix (columns H1..Hk). GOGT_METRICS holds the
# defaults; custom metrics plug in the same way.
#
# The rejection engine is a vectorised form of graphicalMCP's own Bonferroni
# shortcut and is checked against graph_calculate_power() at the start of every
# run (verify_engine() in R/gridRunner.R).
#
# Derived from optimalMCP src/gridSearchGraphER.R.
#
# -----------------------------------------------------------------------------
# FEASIBILITY WARNING -- READ BEFORE CHANGING k OR THE STEP SIZES
# -----------------------------------------------------------------------------
# The candidate space is (# weight vectors) x (# transition matrices). With a
# fine grid (w_step = 0.01, g_step = 0.05) the counts are roughly:
#     k = 3 :  5,151 x  9,261  ~= 4.8e7   candidates  (~2 ms each at sim_n=1e4)
#     k = 4 :  1.8e5 x  2.9e9  ~= 5e14    candidates  (impractical)
#     k = 5 :  4.6e6 x  1.7e16 ~= 8e22    candidates  (impossible)
# k > 3 is therefore gated behind allow_large_k and will refuse to run unless
# you coarsen the grid.
# =============================================================================


# Default metrics, all evaluated on the same rejection matrix R.
GOGT_METRICS <- list(
  er = function(R) sum(R) / nrow(R),                 # expected rejections
  dp = function(R) mean(rowSums(R) > 0),             # disjunctive power
  cp = function(R) mean(rowSums(R) == ncol(R))       # conjunctive power
)

#' Validate a named list of metric functions for k hypotheses.
#'
#' Each metric is probed on a small rejection matrix and must return one number.
#'
#' @param metrics named list of function(R)
#' @param k number of hypotheses
check_metrics <- function(metrics, k) {
  nm <- names(metrics)
  if (!is.list(metrics) || !length(metrics) || is.null(nm) ||
      any(!nzchar(nm)) || anyDuplicated(nm)) {
    stop("metrics must be a non-empty list with unique names.")
  }
  bad <- nm[nm != make.names(nm) | grepl("^(G|g_id|w_id|w[0-9]+|rank_.*)$", nm)]
  if (length(bad)) {
    stop("Invalid or reserved metric name(s): ", paste(bad, collapse = ", "))
  }
  probe <- matrix(c(TRUE, FALSE, TRUE), 6, k,
                  dimnames = list(NULL, paste0("H", seq_len(k))))
  for (x in nm) {
    if (!is.function(metrics[[x]])) stop("Metric '", x, "' is not a function.")
    v <- metrics[[x]](probe)
    if (!is.numeric(v) || length(v) != 1L) {
      stop("Metric '", x, "' must return a single number.")
    }
  }
  invisible(metrics)
}


# -----------------------------------------------------------------------------
# Cluster setup (scheduler / multi-node aware)
# -----------------------------------------------------------------------------

#' Build a PSOCK cluster spanning all allocated cores/nodes.
#'
#' Uses parallelly::availableWorkers(), which detects the scheduler allocation
#' (LSF, Slurm, SGE, PBS, ...) and returns one entry per allocated core across
#' every node. Off a scheduler it returns the local cores. Returns NULL when a
#' single worker is available (search then runs serially).
#'
#' Remote workers are connected back to the master DIRECTLY (revtunnel = FALSE).
#' With the default ssh reverse tunnel every worker on a given remote host tries
#' to bind the same listen port there, so all but the first fail with
#' "remote port forwarding failed for listen port <port>" and the setup hangs.
#' Compute nodes on a cluster can normally reach the master node directly, so
#' the tunnel is unnecessary. Set GRIDSEARCH_REVTUNNEL=TRUE to restore the old
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
    # Remote workers start via ssh unless R_PARALLELLY_MAKENODEPSOCK_RSHCMD
    # names another launcher (blaunch on LSF, srun wrapper on Slurm; see cluster/).
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

#' Simulated one-sided p-values shared by every candidate.
#'
#' Drawn by graphicalMCP itself, so the stream is the one
#' graph_calculate_power() would use with the same seed.
#'
#' @param k number of hypotheses
#' @param alpha type I error
#' @param mp marginal powers
#' @param sim_n MC replications
#' @param seed RNG seed
#' @return sim_n x k matrix of p-values
simulate_pvalues <- function(k, alpha, mp, sim_n, seed) {
  stopifnot(length(mp) == k)
  set.seed(seed)
  sim <- graphicalMCP::graph_calculate_power(
    graph          = graphicalMCP::graph_create(rep(1 / k, k), matrix(0, k, k)),
    alpha          = alpha,
    power_marginal = mp,
    test_types     = "bonferroni",
    sim_n          = sim_n,
    sim_corr       = diag(k),         # independence
    verbose        = TRUE
  )
  unname(sim$details$p_sim)
}

#' Intersection-weight basis of a transition matrix.
#'
#' For fixed G every intersection weight is linear in w, so the weights of any
#' w are w %*% basis, built once from the k unit-weight graphs.
#'
#' @param G k x k transition matrix
#' @return list(ind = (2^k - 1) x k logical membership matrix in
#'   graphicalMCP::graph_generate_weights() row order,
#'   basis = k x ((2^k - 1) * k) matrix)
intersection_basis <- function(G) {
  k <- nrow(G)
  per_unit <- lapply(seq_len(k), function(i) {
    graphicalMCP::graph_generate_weights(
      graphicalMCP::graph_create(replace(numeric(k), i, 1), G))
  })
  list(ind   = per_unit[[1]][, seq_len(k), drop = FALSE] == 1,
       basis = t(vapply(per_unit, function(m) as.vector(m[, k + seq_len(k)]),
                        numeric((2^k - 1) * k))))
}

#' Rejections of a weighted-Bonferroni graph for every simulated p-value row.
#'
#' Vectorised graphicalMCP:::graph_test_shortcut_fast(): each step tests the
#' current non-rejected set at its intersection weights until nothing changes.
#'
#' @param p sim_n x k matrix of p-values
#' @param ind,wts (2^k - 1) x k membership / intersection-weight matrices
#' @param alpha type I error
#' @return sim_n x k logical matrix R (columns H1..Hk)
reject_matrix <- function(p, ind, wts, alpha) {
  n <- nrow(p); k <- ncol(p)
  slots <- 2L^(k:1 - 1L)
  crit  <- wts * alpha
  crit[!ind] <- -1                 # already-rejected hypotheses never re-fire
  code  <- integer(n)              # bitmask of rejections; crit row = code + 1
  todo  <- seq_len(n)
  pt    <- p
  repeat {
    inc  <- as.integer((pt <= crit[code[todo] + 1L, , drop = FALSE]) %*% slots)
    code[todo] <- code[todo] + inc
    more <- inc > 0L & code[todo] < 2L^k - 1L
    if (!any(more)) break
    todo <- todo[more]
    pt   <- p[todo, , drop = FALSE]
  }
  matrix(bitwAnd(rep(code, k), rep(slots, each = n)) > 0L, n, k,
         dimnames = list(NULL, paste0("H", seq_len(k))))
}

#' Rejection matrix of one graph (w, G) on a shared p-value matrix.
graph_rejections <- function(w, G, p, alpha) {
  b <- intersection_basis(G)
  reject_matrix(p, b$ind, matrix(drop(w %*% b$basis), nrow = nrow(b$ind)),
                alpha)
}

#' All metric values of one graph (w, G) on a shared p-value matrix.
#'
#' @return named numeric vector, one entry per metric
eval_graph <- function(w, G, p, alpha, metrics = GOGT_METRICS) {
  R <- graph_rejections(w, G, p, alpha)
  vapply(metrics, function(f) f(R), numeric(1))
}


# -----------------------------------------------------------------------------
# Search driver (streamed + parallel over the transition grid)
# -----------------------------------------------------------------------------

#' Row order of a candidate matrix for one metric (descending).
#'
#' Ties are broken by the remaining metrics, then by g_id / w_id, so rankings
#' are reproducible (e.g. DP does not depend on G at all).
rank_order <- function(m, metric, metric_names) {
  keys <- c(metric, setdiff(metric_names, metric))
  do.call(order, c(lapply(keys, function(x) -m[, x]),
                   list(m[, "g_id"], m[, "w_id"])))
}

#' Rows of a candidate matrix that are in the top_n of at least one metric.
top_union <- function(m, metric_names, top_n) {
  keep <- unlist(lapply(metric_names, function(x)
    head(rank_order(m, x, metric_names), top_n)))
  m[sort(unique(keep)), , drop = FALSE]
}

#' Evaluate every weight vector against a batch of transition matrices.
#'
#' Runs on the workers and keeps only the running top_n union, so memory stays
#' bounded however many candidates the batch holds.
#'
#' @param task list(g_id = integer ids, G = list of matrices)
#' @return numeric matrix with columns g_id, w_id and one per metric
search_chunk <- function(task, W, p, alpha, metrics, top_n) {
  nm   <- names(metrics)
  best <- NULL
  for (t in seq_along(task$g_id)) {
    b  <- intersection_basis(task$G[[t]])
    IW <- W %*% b$basis
    vals <- vapply(seq_len(nrow(W)), function(a) {
      R <- reject_matrix(p, b$ind, matrix(IW[a, ], nrow = nrow(b$ind)), alpha)
      vapply(metrics, function(f) f(R), numeric(1))
    }, numeric(length(nm)))
    rows <- cbind(g_id = task$g_id[t], w_id = seq_len(nrow(W)),
                  matrix(vals, ncol = length(nm), byrow = TRUE,
                         dimnames = list(NULL, nm)))
    best <- top_union(rbind(best, rows), nm, top_n)
  }
  best
}

#' Weight and transition grids of a search.
#'
#' @param w_fixed optional numeric weight vector (length k, sums to 1). When
#'   supplied the weight simplex is skipped and only G is searched.
#' @return list(W = matrix with columns w1..wk, Glist = list of k x k matrices)
build_grids <- function(k, w_step, g_step, w_fixed = NULL) {
  if (is.null(w_fixed)) {
    W <- simplex_grid(k, w_step)
  } else {
    if (length(w_fixed) != k) {
      stop(sprintf("[k=%d] w_fixed must have length %d; got %d.",
                   k, k, length(w_fixed)))
    }
    if (abs(sum(w_fixed) - 1) > 1e-9) {
      stop(sprintf("[k=%d] w_fixed must sum to 1; got %g.", k, sum(w_fixed)))
    }
    W <- matrix(w_fixed, nrow = 1)
  }
  colnames(W) <- paste0("w", seq_len(k))
  list(W = W, Glist = transition_grid(k, g_step))
}

#' Turn a candidate matrix (g_id, w_id, metrics) into the result table.
#'
#' @return data.frame: w1..wk, one column per metric, g_id, rank_<metric>
#'   (NA outside that metric's top_n) and G; sorted by the first metric.
assemble_best <- function(cand, W, Glist, metric_names, top_n) {
  nm   <- metric_names
  best <- data.frame(W[cand[, "w_id"], , drop = FALSE],
                     cand[, nm, drop = FALSE],
                     g_id = cand[, "g_id"], row.names = NULL)
  for (x in nm) {
    r <- head(rank_order(cand, x, nm), top_n)
    best[[paste0("rank_", x)]] <- NA_integer_
    best[[paste0("rank_", x)]][r] <- seq_along(r)
  }
  best$G <- Glist[best$g_id]
  best <- best[rank_order(cand, nm[1], nm), ]
  rownames(best) <- NULL
  best
}

#' Grid-search the best graphs for every metric at once.
#'
#' Each candidate is evaluated once on the shared p-values and scored by all
#' metrics. Parallelizes over the transition-matrix grid; each worker returns
#' only its top_n union, so memory stays small for tens of millions of
#' candidates.
#'
#' @param p sim_n x k p-value matrix from simulate_pvalues() (k = ncol(p))
#' @param metrics named list of function(R); see GOGT_METRICS
#' @param w_fixed optional fixed weight vector; see build_grids()
#' @param shard optional c(i, N): search only every N-th transition matrix
#'   starting at i (job arrays); combine shards with merge_results().
#' @return list(best, k, metrics = metric names, n_candidates (evaluated here),
#'   cand = candidate matrix, settings, shard); see assemble_best() for best.
grid_search_k <- function(p, alpha, w_step, g_step, top_n, cl = NULL,
                          allow_large_k = FALSE, max_candidates = 1e8,
                          w_fixed = NULL, metrics = GOGT_METRICS,
                          shard = NULL) {
  k <- ncol(p)
  check_metrics(metrics, k)
  nm <- names(metrics)

  grids <- build_grids(k, w_step, g_step, w_fixed)
  W     <- grids$W
  Glist <- grids$Glist
  n_all <- nrow(W) * length(Glist)
  if (!is.null(w_fixed)) {
    cat(sprintf("[k=%d] fixed weights supplied: %s (w grid skipped)\n",
                k, paste(round(w_fixed, 4), collapse = ", ")))
  }
  cat(sprintf("[k=%d] weight vectors = %s, transition matrices = %s, candidates = %s\n",
              k, format(nrow(W), big.mark = ","),
              format(length(Glist), big.mark = ","),
              format(n_all, big.mark = ",")))
  cat(sprintf("[k=%d] metrics: %s (sim_n = %s)\n", k,
              paste(nm, collapse = ", "), format(nrow(p), big.mark = ",")))

  if (n_all > max_candidates && !allow_large_k) {
    stop(sprintf(
      "[k=%d] %s candidates exceeds max_candidates (%s). Coarsen w_step/g_step ",
      k, format(n_all, big.mark = ","), format(max_candidates, big.mark = ",")),
      "or set allow_large_k = TRUE.")
  }

  g_ids <- seq_along(Glist)
  if (!is.null(shard)) {
    if (shard[2] > length(Glist)) {
      stop(sprintf("[k=%d] %d shards exceed the %d transition matrices.",
                   k, shard[2], length(Glist)))
    }
    g_ids <- seq(shard[1], length(Glist), by = shard[2])
    cat(sprintf("[k=%d] shard %d/%d: %s transition matrices\n",
                k, shard[1], shard[2], format(length(g_ids), big.mark = ",")))
  }

  # One batch of transition matrices per worker.
  n_tasks <- if (is.null(cl)) 1L else min(length(g_ids), length(cl))
  ids   <- split(g_ids, ceiling(seq_along(g_ids) * n_tasks / length(g_ids)))
  tasks <- lapply(ids, function(i) list(g_id = i, G = Glist[i]))

  t0 <- Sys.time()
  if (!is.null(cl)) {
    parallel::clusterExport(
      cl, c("intersection_basis", "reject_matrix", "rank_order", "top_union"),
      envir = environment(search_chunk)
    )
    parallel::clusterEvalQ(cl, requireNamespace("graphicalMCP", quietly = TRUE))
    parts <- parallel::parLapply(cl, tasks, search_chunk, W = W, p = p,
                                 alpha = alpha, metrics = metrics, top_n = top_n)
  } else {
    parts <- lapply(tasks, search_chunk, W = W, p = p, alpha = alpha,
                    metrics = metrics, top_n = top_n)
  }
  cat(sprintf("[k=%d] search time: %.1f s\n", k,
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  cand <- top_union(do.call(rbind, parts), nm, top_n)
  list(best = assemble_best(cand, W, Glist, nm, top_n), k = k, metrics = nm,
       n_candidates = nrow(W) * length(g_ids), cand = cand,
       settings = list(alpha = alpha, sim_n = nrow(p), w_step = w_step,
                       g_step = g_step, w_fixed = w_fixed, top_n = top_n),
       shard = shard)
}

#' Combine the shard results of one search into the full result.
#'
#' Exact: each shard keeps its top_n per metric, so the union over shards
#' contains the global top_n of every metric.
#'
#' @param parts list of grid_search_k() results with identical settings
merge_results <- function(parts) {
  s  <- parts[[1]]$settings
  nm <- parts[[1]]$metrics
  for (x in parts[-1]) {
    if (!identical(x$settings, s) || !identical(x$metrics, nm)) {
      stop("Shards were run with different settings or metrics; cannot merge.")
    }
  }
  k     <- parts[[1]]$k
  cand  <- top_union(do.call(rbind, lapply(parts, `[[`, "cand")), nm, s$top_n)
  grids <- build_grids(k, s$w_step, s$g_step, s$w_fixed)
  list(best = assemble_best(cand, grids$W, grids$Glist, nm, s$top_n), k = k,
       metrics = nm,
       n_candidates = sum(unlist(lapply(parts, `[[`, "n_candidates"))),
       cand = cand, settings = s, shard = NULL)
}


# -----------------------------------------------------------------------------
# Reporting / saving
# -----------------------------------------------------------------------------

#' Print the best graph for every metric, with all its metric values.
#'
#' @param res return value of grid_search_k()
report_best <- function(res) {
  w_cols <- paste0("w", seq_len(res$k))
  cat(sprintf("\n==== k = %d : best graph per metric (%s candidates) ====\n",
              res$k, format(res$n_candidates, big.mark = ",")))
  for (x in res$metrics) {
    i <- which(res$best[[paste0("rank_", x)]] == 1L)
    cat(sprintf("\n-- %s-optimal --\n", x))
    print(round(unlist(res$best[i, res$metrics, drop = FALSE]), 5))
    cat("Hypothesis weights w:\n"); print(round(unlist(res$best[i, w_cols]), 4))
    cat("Transition matrix G:\n");  print(round(res$best$G[[i]], 4))
  }
}

#' File stem of a run, e.g. "gridSearch_k3_mp90_80_70".
#'
#' @param tag run tag (marginal powers, fixed-weight flag)
gogt_stem <- function(stem_prefix, k, tag = "") {
  sprintf("%s_k%d%s", stem_prefix, k, if (nzchar(tag)) paste0("_", tag) else "")
}

#' Write the result of a grid search to <out_dir>/<stem>.rds and _top.csv.
#'
#' @param res return value of grid_search_k() / merge_results()
#' @return the path stem, invisibly
save_best <- function(res, out_dir, stem) {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  saveRDS(res, file.path(out_dir, paste0(stem, ".rds")))
  flat <- res$best
  flat$G <- vapply(flat$G, function(G) paste(round(G, 4), collapse = ";"),
                   character(1))
  utils::write.csv(flat, file.path(out_dir, paste0(stem, "_top.csv")),
                   row.names = FALSE)
  invisible(file.path(out_dir, stem))
}
