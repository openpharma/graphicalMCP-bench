# =============================================================================
# Grid-search runner: configuration, CLI parsing, verification, main loop
# =============================================================================
# Used by scripts/gridSearchGraph.R, which supplies a default config list and
# calls gogt_main() on it.
#
# DEPENDENCIES: R/rootPath.R, R/gridCore.R, R/utils.R, R/expectedRejections.R,
# R/analyticDP.R.
# =============================================================================

#' Default grid-search configuration.
#'
#' @param ... overrides; each replaces the default field as a whole
#' @return named list consumed by gogt_main()
gogt_config <- function(...) {
  cfg <- list(
    ## -- Problem definition ---------------------------------------------------
    alpha          = 0.025,       # one-sided family-wise type I error
    # Which hypothesis counts to run. Default 3; add 4 / 5 only with a coarse
    # grid and allow_large_k = TRUE (see the feasibility warning in gridCore.R).
    run_k          = c(3),
    # Marginal power per hypothesis, one numeric vector per k in run_k. Names
    # must be "k3", "k4", "k5" and the vector length must equal k.
    mp_list        = list(k3 = c(0.90, 0.80, 0.70)),

    ## -- Metrics (all evaluated together on every candidate) ------------------
    # Named list of function(R) -> one number to maximize; R is the sim_n x k
    # logical rejection matrix (columns H1..Hk).
    metrics        = GOGT_METRICS,
    # Optional R file defining `metrics`, a named list merged into the above.
    metrics_file   = NULL,
    # Optional subset / order of metric names (NULL = all). The first one
    # orders the output table.
    metric_select  = NULL,

    ## -- Grid resolution ------------------------------------------------------
    w_step         = 0.05,        # step for the hypothesis-weight simplex
    g_step         = 0.1,         # step for the transition-weight simplex (per row)
    # Optionally FIX the hypothesis weights instead of gridding over them. When a
    # numeric vector (length k, summing to 1) is supplied the weight simplex is
    # skipped and only G is searched; results are tagged "fixedw".
    w_fixed        = NULL,

    ## -- Monte-Carlo / runtime ------------------------------------------------
    sim_n          = 1e4,         # MC replications, shared by all candidates
    seed           = 2024,        # RNG seed of the shared p-value matrix
    # Workers are auto-detected via parallelly::availableWorkers() (LSF/Slurm-aware).
    # Set max_workers to cap the count, or NULL to use every allocated core.
    max_workers    = NULL,

    ## -- Output ---------------------------------------------------------------
    top_n          = 50L,         # graphs kept per metric (their union is saved)
    save_results   = TRUE,        # write RDS/CSV of the kept graphs
    out_dir        = "results",   # relative paths resolve against the repo root
    stem_prefix    = "gridSearch",

    ## -- Job arrays -----------------------------------------------------------
    # c(i, N): search only shard i of N and write it to <out_dir>/shards/.
    shard          = NULL,
    # N: merge shards 1..N of the same run into the final result (no search).
    merge_shards   = NULL,

    ## -- Safety gate for large k ----------------------------------------------
    allow_large_k  = FALSE,       # set TRUE only after coarsening the grid for k>3
    max_candidates = 1e8          # hard stop above this many candidates
  )
  over <- list(...)
  cfg[names(over)] <- over
  cfg
}


#' Apply command-line overrides to a config.
#'
#' Positional numeric args are the marginal powers (their count defines k).
#' key=value args override individual config fields.
#'
#' @param cfg config list from gogt_config()
#' @param args character vector, defaults to the Rscript arguments
#' @return the updated config list
gogt_parse_cli <- function(cfg, args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) == 0L) return(cfg)
  is_kv <- grepl("=", args, fixed = TRUE)
  pos   <- args[!is_kv]
  kv    <- args[is_kv]

  if (length(pos)) {
    mp_cli <- suppressWarnings(as.numeric(pos))
    if (anyNA(mp_cli)) {
      stop("Positional args must be numeric marginal powers; got: ",
           paste(pos, collapse = " "))
    }
    if (any(mp_cli <= 0 | mp_cli >= 1)) {
      stop("Marginal powers must be in (0, 1); got: ", paste(pos, collapse = " "))
    }
    k_cli       <- length(mp_cli)
    cfg$run_k   <- k_cli
    cfg$mp_list <- stats::setNames(list(mp_cli), paste0("k", k_cli))
    cat(sprintf("[cli] k = %d, marginal power = %s\n",
                k_cli, paste(mp_cli, collapse = ", ")))
  }

  conv <- function(key, val, as) {
    out <- suppressWarnings(as(val))
    if (anyNA(out)) stop("Invalid value for CLI option ", key, ": '", val, "'")
    out
  }
  split_csv <- function(val) strsplit(val, ",", fixed = TRUE)[[1]]

  for (item in kv) {
    key <- sub("=.*$", "", item)
    val <- sub("^[^=]*=", "", item)
    if      (key == "alpha")          cfg$alpha          <- conv(key, val, as.numeric)
    else if (key == "sim_n")          cfg$sim_n          <- conv(key, val, as.numeric)
    else if (key == "w_step")         cfg$w_step         <- conv(key, val, as.numeric)
    else if (key == "g_step")         cfg$g_step         <- conv(key, val, as.numeric)
    else if (key == "w_fixed")        cfg$w_fixed        <- conv(key, split_csv(val), as.numeric)
    else if (key == "seed")           cfg$seed           <- conv(key, val, as.integer)
    else if (key == "top_n")          cfg$top_n          <- conv(key, val, as.integer)
    else if (key == "out_dir")        cfg$out_dir        <- val
    else if (key == "stem_prefix")    cfg$stem_prefix    <- val
    else if (key == "allow_large_k")  cfg$allow_large_k  <- conv(key, val, as.logical)
    else if (key == "max_candidates") cfg$max_candidates <- conv(key, val, as.numeric)
    else if (key == "save_results")   cfg$save_results   <- conv(key, val, as.logical)
    else if (key == "max_workers")    cfg$max_workers    <- conv(key, val, as.integer)
    else if (key == "metrics")        cfg$metric_select  <- split_csv(val)
    else if (key == "metrics_file")   cfg$metrics_file   <- val
    else if (key == "merge_shards")   cfg$merge_shards   <- conv(key, val, as.integer)
    else if (key == "shard") {
      cfg$shard <- conv(key, strsplit(val, "/", fixed = TRUE)[[1]], as.integer)
      if (length(cfg$shard) != 2L || cfg$shard[1] < 1L ||
          cfg$shard[1] > cfg$shard[2]) {
        stop("shard must be i/N with 1 <= i <= N; got '", val, "'")
      }
    }
    else stop("Unknown CLI option '", key, "'. Valid: alpha, sim_n, w_step, g_step, ",
              "w_fixed, seed, top_n, out_dir, stem_prefix, allow_large_k, ",
              "max_candidates, save_results, max_workers, metrics, metrics_file, ",
              "shard, merge_shards.")
  }
  cfg
}


#' Final metric list of a config: defaults, plus metrics_file, then selection.
#'
#' @param cfg config list
#' @return named list of metric functions
gogt_resolve_metrics <- function(cfg) {
  metrics <- cfg$metrics
  if (!is.null(cfg$metrics_file)) {
    path <- cfg$metrics_file
    if (!file.exists(path)) path <- file.path(gogt_root(), path)
    if (!file.exists(path)) stop("metrics_file not found: ", cfg$metrics_file)
    env <- new.env(parent = globalenv())
    sys.source(path, envir = env)
    if (!is.list(env$metrics) || is.null(names(env$metrics))) {
      stop(path, " must define `metrics`, a named list of function(R).")
    }
    metrics[names(env$metrics)] <- env$metrics
  }
  if (!is.null(cfg$metric_select)) {
    miss <- setdiff(cfg$metric_select, names(metrics))
    if (length(miss)) {
      stop("Unknown metric(s): ", paste(miss, collapse = ", "),
           ". Available: ", paste(names(metrics), collapse = ", "))
    }
    metrics <- metrics[cfg$metric_select]
  }
  metrics
}


#' Check that the required packages are installed.
gogt_check_deps <- function() {
  for (pkg in c("graphicalMCP", "parallel", "parallelly")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Package '", pkg, "' is required. ",
           "Install it with install.packages('", pkg, "').")
    }
  }
}


#' Analytic value of a default metric for a single-step weighted-Bonferroni test.
#'
#' This is the G = 0 case: no alpha is propagated, so the graphical procedure
#' reduces to the closed forms in R/expectedRejections.R / R/analyticDP.R.
#'
#' @return numeric, or NULL when the analytic reference is unavailable
gogt_analytic <- function(w, alpha, mp, metric) {
  switch(metric,
    er = if (exists("expected_rejections")) {
      expected_rejections(w, alpha, mp, test = "Bonferroni")
    },
    dp = if (exists("disjunctive_power_indep")) {
      disjunctive_power_indep(w, alpha, mp)
    },
    cp = if (exists("conjunctive_power_indep")) {
      conjunctive_power_indep(w, alpha, mp)
    },
    NULL
  )
}


#' Cross-check: the rejection engine must reproduce graphicalMCP exactly.
#'
#' Random graphs (with some zero weights / transitions) are simulated by
#' graph_calculate_power(); the engine is run on the same p-values and the two
#' rejection matrices must be identical.
verify_engine <- function(k, alpha, mp, n_graphs = 5L, sim_n = 2000L,
                          seed = 1L) {
  for (i in seq_len(n_graphs)) {
    set.seed(seed + i)
    w <- runif(k) * (runif(k) > 0.25)
    if (!any(w > 0)) w[1] <- 1
    w <- w / sum(w)
    G <- matrix(runif(k * k) * (runif(k * k) > 0.25), k, k)
    diag(G) <- 0
    G <- G / pmax(rowSums(G), 1e-12)
    ref <- graphicalMCP::graph_calculate_power(
      graph          = graphicalMCP::graph_create(w, G),
      alpha          = alpha,
      power_marginal = mp,
      test_types     = "bonferroni",
      sim_n          = sim_n,
      sim_corr       = diag(k),
      verbose        = TRUE
    )
    R <- graph_rejections(w, G, ref$details$p_sim, alpha)
    if (!identical(unname(R), unname(ref$details$test_results))) {
      stop(sprintf("[verify k=%d] rejection engine disagrees with graphicalMCP ",
                   k), "for w = ", paste(round(w, 4), collapse = ", "), ".")
    }
  }
  cat(sprintf("[verify k=%d] engine matches graphicalMCP on %d random graphs\n",
              k, n_graphs))
}


#' Cross-check: with G = 0 the default metrics must match their analytic
#' single-step values within Monte-Carlo error.
#'
#' Runs on the search's own p-values. Stops when a difference exceeds 4 MC
#' standard errors, bounded by sqrt(k) / (2 sqrt(sim_n)) under independence.
verify_zero_transition <- function(p, alpha, mp, metrics) {
  k <- ncol(p)
  w <- rep(1 / k, k)
  own <- names(metrics)[vapply(names(metrics), function(x)
    identical(metrics[[x]], GOGT_METRICS[[x]]), logical(1))]
  if (!length(own)) return(invisible(NULL))
  sim <- eval_graph(w, matrix(0, k, k), p, alpha, metrics[own])
  tol <- 2 * sqrt(k / nrow(p))
  for (x in own) {
    ana <- gogt_analytic(w, alpha, mp, x)
    if (is.null(ana)) next
    cat(sprintf("[verify k=%d] G=0 %s: analytic=%.5f  simulated=%.5f  diff=%+.5f\n",
                k, x, ana, sim[[x]], sim[[x]] - ana))
    if (abs(sim[[x]] - ana) > tol) {
      stop(sprintf("[verify k=%d] G=0 %s differs from analytic by more than %.4f.",
                   k, x, tol))
    }
  }
  invisible(sim)
}


#' Fast pipeline smoke test on a coarse grid (seconds, not the full run).
smoke_test <- function(alpha = 0.025, mp = c(0.8, 0.7, 0.9),
                       metrics = GOGT_METRICS) {
  p <- simulate_pvalues(length(mp), alpha, mp, sim_n = 2e3, seed = 1)
  res <- grid_search_k(p, alpha, w_step = 0.25, g_step = 0.5, top_n = 5,
                       allow_large_k = TRUE, max_candidates = Inf,
                       metrics = metrics)
  report_best(res)
  invisible(res)
}


#' Path of shard i of n for a run stem.
shard_file <- function(shard_dir, stem, i, n) {
  file.path(shard_dir, sprintf("%s_shard%dof%d.rds", stem, i, n))
}

#' Load shards 1..n of a run and merge them into the full result.
merge_shards <- function(shard_dir, stem, n) {
  if (n < 1L) stop("merge_shards must be >= 1.")
  files <- shard_file(shard_dir, stem, seq_len(n), n)
  miss  <- which(!file.exists(files))
  if (length(miss)) {
    stop(sprintf("Missing %d of %d shard(s) for %s: %s", length(miss), n, stem,
                 paste(miss, collapse = ", ")))
  }
  res <- merge_results(lapply(files, readRDS))
  cat(sprintf("[k=%d] merged %d shards from %s\n", res$k, n, shard_dir))
  res
}


#' Run the grid search for every k in the config.
#'
#' With cfg$shard set, only that shard is searched and written to
#' <out_dir>/shards/; with cfg$merge_shards set, existing shards are merged
#' instead of searching.
#'
#' @param cfg config list from gogt_config() / gogt_parse_cli()
#' @return invisibly, a named list of results per k
gogt_main <- function(cfg) {
  gogt_check_deps()
  metrics <- gogt_resolve_metrics(cfg)
  merging <- !is.null(cfg$merge_shards)
  if (merging && !is.null(cfg$shard)) {
    stop("Use either shard= or merge_shards=, not both.")
  }

  out_dir <- cfg$out_dir
  if (!isTRUE(grepl("^(/|\\\\|[A-Za-z]:)", out_dir))) {
    out_dir <- file.path(gogt_root(), out_dir)
  }
  shard_dir <- file.path(out_dir, "shards")

  cl <- if (merging) NULL else make_cluster(cfg$max_workers)
  if (!is.null(cl)) on.exit(parallel::stopCluster(cl), add = TRUE)

  results <- list()
  for (k in cfg$run_k) {
    key <- paste0("k", k)
    mp  <- cfg$mp_list[[key]]
    if (is.null(mp)) stop("No marginal powers defined in mp_list for ", key, ".")

    # Tag output files with the marginal powers so runs don't clash.
    tag <- paste0("mp", paste(sprintf("%02d", round(mp * 100)), collapse = "_"))
    if (!is.null(cfg$w_fixed)) tag <- paste0(tag, "_fixedw")
    stem <- gogt_stem(cfg$stem_prefix, k, tag)

    if (merging) {
      res <- merge_shards(shard_dir, stem, cfg$merge_shards)
    } else {
      check_metrics(metrics, k)
      verify_engine(k, cfg$alpha, mp)
      p <- simulate_pvalues(k, cfg$alpha, mp, cfg$sim_n, cfg$seed)
      verify_zero_transition(p, cfg$alpha, mp, metrics)

      res <- grid_search_k(
        p              = p,
        alpha          = cfg$alpha,
        w_step         = cfg$w_step,
        g_step         = cfg$g_step,
        top_n          = cfg$top_n,
        cl             = cl,
        allow_large_k  = cfg$allow_large_k,
        max_candidates = cfg$max_candidates,
        w_fixed        = cfg$w_fixed,
        metrics        = metrics,
        shard          = cfg$shard
      )
      res$settings$mp   <- mp
      res$settings$seed <- cfg$seed

      if (!is.null(cfg$shard)) {
        dir.create(shard_dir, recursive = TRUE, showWarnings = FALSE)
        path <- shard_file(shard_dir, stem, cfg$shard[1], cfg$shard[2])
        saveRDS(res, path)
        cat(sprintf("[k=%d] shard %d/%d written to %s\n",
                    k, cfg$shard[1], cfg$shard[2], path))
        results[[key]] <- res
        next
      }
    }
    results[[key]] <- res

    if (cfg$save_results) {
      save_best(res, out_dir, stem)
      cat(sprintf("[k=%d] results written to %s.rds / _top.csv\n",
                  k, file.path(out_dir, stem)))
    }
    report_best(res)
  }
  invisible(results)
}
