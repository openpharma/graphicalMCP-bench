# =============================================================================
# Optimizer solutions: score proposed graphs against a scenario's reference
# =============================================================================
# An optimizer proposes one graph (w, G) per metric for a scenario. The graphs
# are re-evaluated with the grid's rejection engine on the SAME independent
# p-values as reference/<id>/ (its validation seed and size), so their values
# compare directly with the reference `_val` columns, and the difference to the
# reference graph is paired (common random numbers). Scenarios with
# grid = FALSE have no reference graphs: every solution is still scored on the
# same simulations, so solutions compare with each other, and ref_val /
# diff_val / diff_se are NA.
#
# DEPENDENCIES: R/rootPath.R, R/gridCore.R, R/gridRunner.R.
# =============================================================================

#' Score an optimizer's graphs for a scenario and save them.
#'
#' Writes <out_dir>/<method>.rds (full result) and <method>_best.csv (one row
#' per metric: metric, w1..wk, <m>_val / <m>_se for every metric m, ref_val =
#' the reference graph's value, diff_val / diff_se = solution minus reference
#' with paired SE (all NA with grid = FALSE), time_s, G column-major).
#'
#' @param id scenario id; reference/<id>/<id>.rds must exist and match
#'   scenarios/<id>.R (with grid = FALSE it holds no graphs, only the settings)
#' @param method optimizer name, used as the file stem (e.g. "optimalMCP")
#' @param graphs named list, one graphicalMCP graph (graph_create()) per metric
#'   the method optimizes; hypotheses named H1..Hk in the scenario's order
#' @param time_s optional run times in seconds, named by metric
#' @param info optional list stored in the RDS (method version, solver settings)
#' @param out_dir NULL = solutions/<id>; relative paths resolve against the repo
#'   root
#' @param save FALSE = score only, nothing written
#' @return invisibly, list(method, id, k, metrics, best, graphs, settings,
#'   validation, reference, info, meta)
bench_save_solution <- function(id, method, graphs, time_s = NULL, info = NULL,
                                out_dir = NULL, save = TRUE) {
  if (!grepl("^[a-z0-9][a-z0-9_]*$", id)) stop("Invalid scenario id '", id, "'.")
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", method)) {
    stop("method must match [A-Za-z0-9][A-Za-z0-9_.-]*; got '", method, "'.")
  }
  ref_path <- file.path(bench_root(), "reference", id, paste0(id, ".rds"))
  if (!file.exists(ref_path)) {
    stop("No reference for '", id, "': run scripts/gridSearchGraph.R scenario=", id,
         " first.")
  }
  ref <- readRDS(ref_path)
  s   <- ref$settings
  v   <- ref$validation
  k   <- ref$k
  nm  <- ref$metrics
  if (is.null(v)) stop("reference/", id, " was run with validate_n=0; re-run it.")

  cfg     <- bench_load_scenario(bench_config(), id)
  metrics <- bench_resolve_metrics(cfg)
  if (length(setdiff(nm, names(metrics)))) {
    stop("scenarios/", id, ".R no longer defines metric(s) ",
         paste(setdiff(nm, names(metrics)), collapse = ", "), ".")
  }
  metrics <- metrics[nm]
  meta    <- bench_run_meta(cfg, metrics)
  grid    <- !isFALSE(s$grid)
  same <- isTRUE(all.equal(
    list(cfg$alpha, cfg$mp_list[[1]], bench_corr(cfg$corr, k), cfg$w_fixed,
         cfg$G_fixed, meta$metric_defs, !isFALSE(cfg$grid)),
    list(s$alpha, s$mp, s$corr, s$w_fixed, s$G_fixed, ref$meta$metric_defs[nm], grid)))
  if (length(ref$meta$overrides) || !same) {
    stop("reference/", id, " does not match scenarios/", id, ".R (changed since, ",
         "or run with overrides); re-run scripts/gridSearchGraph.R scenario=", id,
         " first.")
  }

  if (!is.list(graphs) || !length(graphs) || is.null(names(graphs)) ||
      anyDuplicated(names(graphs))) {
    stop("graphs must be a named list with one entry per metric.")
  }
  bad <- setdiff(names(graphs), nm)
  if (length(bad)) {
    stop("Unknown metric(s) in graphs: ", paste(bad, collapse = ", "),
         ". The reference has: ", paste(nm, collapse = ", "), ".")
  }
  xs <- intersect(nm, names(graphs))
  H  <- paste0("H", seq_len(k))
  w_of <- function(x) unname(graphs[[x]]$hypotheses)
  G_of <- function(x) unname(graphs[[x]]$transitions)
  for (x in xs) {
    g <- graphs[[x]]
    if (!inherits(g, "initial_graph")) {
      stop(sprintf("graphs$%s must be a graphicalMCP graph from graph_create().", x))
    }
    # Re-validate: the object may have been modified after graph_create().
    tryCatch(graphicalMCP::graph_create(g$hypotheses, g$transitions), error = function(e) {
      stop(sprintf("graphs$%s is not a valid graph: %s", x, conditionMessage(e)),
           call. = FALSE)
    })
    if (!identical(names(g$hypotheses), H)) {
      stop(sprintf(paste("graphs$%s must name its hypotheses %s in this order (got %s);",
                         "pass unnamed weights or hyp_names to graph_create()."),
                   x, paste(H, collapse = ", "),
                   paste(names(g$hypotheses), collapse = ", ")))
    }
    if (any(abs(w_of(x) - s$w_fixed) > 1e-8, na.rm = TRUE) ||
        any(abs(G_of(x) - s$G_fixed) > 1e-8, na.rm = TRUE)) {
      stop(sprintf("graphs$%s breaks the scenario's fixed weights / transitions.", x))
    }
  }
  if (!is.null(time_s) && (!is.numeric(time_s) || is.null(names(time_s)) ||
                           length(setdiff(names(time_s), xs)))) {
    stop("time_s must be a numeric vector named by metrics in graphs.")
  }

  p_val   <- simulate_pvalues(k, s$alpha, s$mp, v$sim_n, v$seed, s$corr)
  # Without reference graphs, the p-values themselves show whether the
  # simulations are still those of the other solutions.
  if (!grid && !isTRUE(all.equal(colSums(p_val), v$p_colsums))) {
    stop("Could not reproduce the simulations of reference/", id, "; was graphicalMCP ",
         "updated since? Re-run scripts/gridSearchGraph.R scenario=", id,
         " and every solution in solutions/", id, "/.")
  }
  n       <- nrow(p_val)
  batches <- split(seq_len(n), ceiling(seq_len(n) * v$n_batch / n))
  score <- function(w, G) {
    R <- graph_rejections(w, G, p_val, s$alpha)
    list(val = vapply(metrics, function(f) f(R), numeric(1)),
         by_b = matrix(vapply(batches, function(r) {
           Rb <- R[r, , drop = FALSE]
           vapply(metrics, function(f) f(Rb), numeric(1))
         }, numeric(length(nm))), length(nm), dimnames = list(nm, NULL)))
  }

  top1 <- if (grid) best_per_metric(ref)
  rows <- lapply(xs, function(x) {
    sol <- score(w_of(x), G_of(x))
    se  <- apply(sol$by_b, 1, stats::sd) / sqrt(v$n_batch)
    out <- data.frame(metric = x, t(w_of(x)))
    names(out)[-1] <- paste0("w", seq_len(k))
    for (m in nm) {
      out[[paste0(m, "_val")]] <- sol$val[[m]]
      out[[paste0(m, "_se")]]  <- se[[m]]
    }
    out$ref_val  <- NA_real_
    out$diff_val <- NA_real_
    out$diff_se  <- NA_real_
    if (grid) {
      i  <- match(x, top1$metric)
      rf <- score(unlist(top1[i, paste0("w", seq_len(k))]), top1$G[[i]])
      # Same p-values as the reference validation, or the comparison is not paired.
      if (!isTRUE(all.equal(rf$val[[x]], top1[[paste0(x, "_val")]][i]))) {
        stop("Could not reproduce the reference value of '", x, "' (",
             rf$val[[x]], " vs ", top1[[paste0(x, "_val")]][i], "); was graphicalMCP ",
             "updated since the reference run? Re-run the grid search.")
      }
      out$ref_val  <- rf$val[[x]]
      out$diff_val <- sol$val[[x]] - rf$val[[x]]
      out$diff_se  <- stats::sd(sol$by_b[x, ] - rf$by_b[x, ]) / sqrt(v$n_batch)
    }
    out$time_s   <- if (is.null(time_s)) NA_real_ else unname(time_s[x])
    out
  })
  best <- do.call(rbind, rows)
  rownames(best) <- NULL
  best$G <- lapply(xs, G_of)

  res <- list(method = method, id = id, k = k, metrics = nm, best = best,
              graphs = graphs[xs], settings = s, validation = v,
              reference = list(run_date = ref$meta$run_date,
                               git_commit = ref$meta$git_commit),
              info = info, meta = meta)

  cat(sprintf("[solution] %s on %s: re-evaluated on %s simulations (seed %d), as the %s\n",
              method, id, format(v$sim_n, big.mark = ",", scientific = FALSE), v$seed,
              if (grid) "reference" else "other solutions (no grid reference)"))
  for (j in seq_len(nrow(best))) {
    x <- best$metric[j]
    cat(sprintf("  %-6s %.5f +/- %.5f", x, best[[paste0(x, "_val")]][j],
                best[[paste0(x, "_se")]][j]))
    if (grid) {
      cat(sprintf("   reference %.5f   diff %+.5f +/- %.5f",
                  best$ref_val[j], best$diff_val[j], best$diff_se[j]))
    }
    cat("\n")
  }

  if (save) {
    if (is.null(out_dir)) out_dir <- file.path("solutions", id)
    if (!grepl("^(/|\\\\|[A-Za-z]:)", out_dir)) out_dir <- file.path(bench_root(), out_dir)
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
    saveRDS(res, file.path(out_dir, paste0(method, ".rds")))
    flat <- best
    flat$G <- vapply(best$G, paste, character(1), collapse = ";")
    utils::write.csv(flat, file.path(out_dir, paste0(method, "_best.csv")),
                     row.names = FALSE)
    cat(sprintf("[solution] written to %s.rds / _best.csv\n", file.path(out_dir, method)))
  }
  invisible(res)
}
