# =============================================================================
# Grid-search runner: configuration, CLI parsing, verification, main loop
# =============================================================================
# Used by scripts/gridSearchGraph.R, which supplies a default config list and
# calls bench_main() on it.
#
# DEPENDENCIES: R/rootPath.R, R/analytic.R, R/gridCore.R, R/report.R.
# =============================================================================

#' Default grid-search configuration.
#'
#' @param ... overrides; each replaces the default field as a whole
#' @return named list consumed by bench_main()
bench_config <- function(...) {
  cfg <- list(
    ## -- Problem definition ---------------------------------------------------
    alpha          = 0.025,       # one-sided family-wise type I error
    # Which hypothesis counts to run. Default 3; add 4 / 5 only with a coarse
    # grid and allow_large_k = TRUE (see the feasibility warning in gridCore.R).
    run_k          = c(3),
    # Marginal power per hypothesis, one numeric vector per k in run_k. Names
    # must be "k3", "k4", "k5" and the vector length must equal k.
    mp_list        = list(k3 = c(0.90, 0.80, 0.70)),
    # Correlation of the test statistics: NULL = independence, one number =
    # equicorrelation, or a k x k matrix. It only enters the simulated
    # p-values; the tests stay weighted Bonferroni.
    corr           = NULL,

    ## -- Metrics (all evaluated together on every candidate) ------------------
    # Named list of function(R) -> one number to maximize; R is the sim_n x k
    # logical rejection matrix (columns H1..Hk).
    metrics        = BENCH_METRICS,
    # Optional R file defining `metrics`, a named list merged into the above.
    metrics_file   = NULL,
    # Optional subset / order of metric names (NULL = all). The first one
    # orders the output table.
    metric_select  = NULL,

    ## -- Grid resolution ------------------------------------------------------
    w_step         = 0.05,        # step for the hypothesis-weight simplex
    g_step         = 0.1,         # step for the transition-weight simplex (per row)

    ## -- Constraints (NA = free, a number = fixed; fixed values must lie on the grid)
    # Length-k weight vector. Fully specified, the weight simplex is skipped
    # and only G is searched. Ad-hoc runs are tagged "fixedw".
    w_fixed        = NULL,
    # k x k transition matrix (diagonal NA or 0). Ad-hoc runs are tagged "fixedg".
    G_fixed        = NULL,

    ## -- Monte-Carlo / runtime ------------------------------------------------
    sim_n          = 1e4,         # MC replications, shared by all candidates
    seed           = 2024,        # RNG seed of the shared p-value matrix
    # Workers are auto-detected via parallelly::availableWorkers() (LSF/Slurm-aware).
    # Set max_workers to cap the count, or NULL to use every allocated core.
    max_workers    = NULL,

    ## -- Re-evaluation of the kept graphs on independent p-values -------------
    validate_n     = 1e5,         # MC replications; 0 = skip
    validate_seed  = NULL,        # NULL = seed + 1; must differ from seed

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
    max_candidates = 1e8,         # hard stop above this many candidates

    # TRUE: checks plus a time / memory estimate of the full run; nothing written.
    smoke          = FALSE,
    ## -- Set by scenario=<id> (see scenarios/_template.R) ---------------------
    scenario       = NULL,        # list(id, file, title, author, date, description)
    overrides      = NULL         # key=value arguments applied on top of it
  )
  over <- list(...)
  cfg[names(over)] <- over
  cfg
}


#' Apply command-line overrides to a config.
#'
#' Positional numeric args are the marginal powers (their count defines k).
#' key=value args override individual config fields. scenario=<id|path> is
#' loaded first, whatever its position, so the other keys override it.
#'
#' @param cfg config list from bench_config()
#' @param args character vector, defaults to the Rscript arguments
#' @return the updated config list
bench_parse_cli <- function(cfg, args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) == 0L) return(cfg)
  is_kv <- grepl("=", args, fixed = TRUE)
  pos   <- args[!is_kv]
  kv    <- args[is_kv]

  is_sc <- sub("=.*$", "", kv) == "scenario"
  if (any(is_sc)) {
    if (length(pos)) {
      stop("With scenario= the marginal powers come from the scenario file; ",
           "drop the positional arguments: ", paste(pos, collapse = " "))
    }
    cfg <- bench_load_scenario(cfg, sub("^[^=]*=", "", tail(kv[is_sc], 1L)))
    kv  <- kv[!is_sc]
    cfg$overrides <- kv[!sub("=.*$", "", kv) %in%
                          c("shard", "merge_shards", "max_workers", "save_results")]
  }

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
    else if (key == "w_fixed") {
      tok <- split_csv(val)
      cfg$w_fixed <- suppressWarnings(as.numeric(tok))
      if (anyNA(cfg$w_fixed[toupper(tok) != "NA"])) {
        stop("Invalid value for CLI option w_fixed: '", val, "'")
      }
    }
    else if (key == "corr")           cfg$corr           <- conv(key, val, as.numeric)
    else if (key == "validate_n")     cfg$validate_n     <- conv(key, val, as.numeric)
    else if (key == "validate_seed")  cfg$validate_seed  <- conv(key, val, as.integer)
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
    else if (key == "smoke")          cfg$smoke          <- conv(key, val, as.logical)
    else if (key == "shard") {
      cfg$shard <- conv(key, strsplit(val, "/", fixed = TRUE)[[1]], as.integer)
      if (length(cfg$shard) != 2L || cfg$shard[1] < 1L ||
          cfg$shard[1] > cfg$shard[2]) {
        stop("shard must be i/N with 1 <= i <= N; got '", val, "'")
      }
    }
    else stop("Unknown CLI option '", key, "'. Valid: scenario, alpha, corr, ",
              "sim_n, w_step, g_step, w_fixed, seed, top_n, validate_n, ",
              "validate_seed, out_dir, stem_prefix, allow_large_k, ",
              "max_candidates, save_results, max_workers, metrics, metrics_file, ",
              "shard, merge_shards, smoke.")
  }
  cfg
}


# Fields a scenario file may set; anything else is an error.
BENCH_SCENARIO_FIELDS <- c(
  "title", "author", "date", "description",
  "alpha", "mp", "corr", "metrics", "w_fixed", "G_fixed",
  "w_step", "g_step", "sim_n", "seed", "top_n", "validate_n", "validate_seed",
  "allow_large_k", "max_candidates"
)

#' Path of a scenario given as an id (scenarios/<id>.R) or a file path.
bench_scenario_path <- function(x) {
  if (!grepl("[/\\\\]|\\.R$", x)) {
    path <- file.path(bench_root(), "scenarios", paste0(x, ".R"))
  } else {
    path <- if (file.exists(x)) x else file.path(bench_root(), x)
  }
  if (!file.exists(path)) stop("Scenario not found: ", x)
  normalizePath(path, winslash = "/")
}

#' Load a scenario file into a config.
#'
#' The file must define `scenario`, a named list (see scenarios/_template.R).
#' Its id is the file name; results go to results/<id>/.
#'
#' @param cfg config list from bench_config()
#' @param x scenario id or path
#' @return the updated config list
bench_load_scenario <- function(cfg, x) {
  path <- bench_scenario_path(x)
  id   <- sub("\\.R$", "", basename(path))
  if (!grepl("^[a-z0-9][a-z0-9_]*$", id)) {
    stop("Scenario file names must match [a-z0-9][a-z0-9_]*.R; got '",
         basename(path), "'.")
  }
  env <- new.env(parent = globalenv())
  sys.source(path, envir = env)
  sc <- env$scenario
  if (!is.list(sc) || is.null(names(sc)) || any(!nzchar(names(sc)))) {
    stop(path, " must define `scenario`, a named list.")
  }
  bad <- setdiff(names(sc), BENCH_SCENARIO_FIELDS)
  if (length(bad)) {
    stop("Unknown field(s) in ", basename(path), ": ", paste(bad, collapse = ", "),
         ". Allowed: ", paste(BENCH_SCENARIO_FIELDS, collapse = ", "), ".")
  }
  for (f in c("title", "author", "alpha", "mp")) {
    if (is.null(sc[[f]])) stop("Scenario ", id, " must set `", f, "`.")
  }
  if (any(sc$mp <= 0 | sc$mp >= 1)) stop("Scenario ", id, ": mp must be in (0, 1).")

  k <- length(sc$mp)
  cfg$run_k   <- k
  cfg$mp_list <- stats::setNames(list(sc$mp), paste0("k", k))
  run <- setdiff(intersect(names(sc), BENCH_SCENARIO_FIELDS),
                 c("title", "author", "date", "description", "mp"))
  cfg[run] <- sc[run]
  cfg$scenario <- list(
    id          = id,
    file        = file.path("scenarios", basename(path)),
    title       = sc$title,
    author      = sc$author,
    date        = if (is.null(sc$date)) "" else as.character(sc$date),
    description = if (is.null(sc$description)) "" else sc$description
  )
  cfg$out_dir <- file.path("results", id)
  cat(sprintf("[scenario] %s: %s (k = %d)\n", id, sc$title, k))
  cfg
}


#' Correlation matrix of a run.
#'
#' @param corr NULL (independence), one number (equicorrelation) or k x k matrix
#' @param k number of hypotheses
#' @return validated k x k correlation matrix
bench_corr <- function(corr, k) {
  if (is.null(corr)) return(diag(k))
  if (length(corr) == 1L) {
    corr <- matrix(corr, k, k)
    diag(corr) <- 1
  }
  if (!is.matrix(corr) || any(dim(corr) != k)) {
    stop(sprintf("corr must be one number or a %d x %d matrix.", k, k))
  }
  corr <- unname(corr)
  if (!isSymmetric(corr) || any(diag(corr) != 1) || any(abs(corr) > 1)) {
    stop("corr must be symmetric with unit diagonal and entries in [-1, 1].")
  }
  if (min(eigen(corr, symmetric = TRUE, only.values = TRUE)$values) < -1e-8) {
    stop("corr is not positive semi-definite.")
  }
  corr
}


#' Final metric list of a config: defaults, plus metrics_file, then selection.
#'
#' @param cfg config list
#' @return named list of metric functions
bench_resolve_metrics <- function(cfg) {
  metrics <- cfg$metrics
  if (!is.null(cfg$metrics_file)) {
    path <- cfg$metrics_file
    if (!file.exists(path)) path <- file.path(bench_root(), path)
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
bench_check_deps <- function() {
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
#' reduces to the closed forms in R/analytic.R.
#'
#' @return numeric, or NULL for metrics without a closed form
bench_analytic <- function(w, alpha, mp, metric) {
  switch(metric,
    er = expected_rejections_single(w, alpha, mp),
    dp = disjunctive_power_indep(w, alpha, mp),
    cp = conjunctive_power_indep(w, alpha, mp),
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
#' E[R] only depends on the marginals; DP / CP are checked only when indep.
verify_zero_transition <- function(p, alpha, mp, metrics, indep = TRUE) {
  k <- ncol(p)
  w <- rep(1 / k, k)
  own <- names(metrics)[vapply(names(metrics), function(x)
    identical(metrics[[x]], BENCH_METRICS[[x]]), logical(1))]
  if (!length(own)) return(invisible(NULL))
  sim <- eval_graph(w, matrix(0, k, k), p, alpha, metrics[own])
  tol <- 2 * sqrt(k / nrow(p))
  for (x in own) {
    if (!indep && x != "er") {
      cat(sprintf("[verify k=%d] G=0 %s: skipped (analytic value assumes independence)\n",
                  k, x))
      next
    }
    ana <- bench_analytic(w, alpha, mp, x)
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


#' Smoke test: the checks plus a time and memory estimate of the full run.
#'
#' Times a random sample of the real grid at the run's sim_n, k, metrics and
#' constraints; the full grid is counted, never built. Search CPU time is
#' n_G * (c_G + n_W * c_w), with c_G the fixed cost per transition matrix and
#' c_w the cost per candidate. Nothing is written.
#'
#' @param cfg config list from bench_config() / bench_parse_cli()
#' @param n_g,n_w transition matrices / weight vectors in the sample
#' @param n_val graphs timed at validate_n simulations
#' @param cores,shards,shard_cores defaults of cluster/*/submit.sh (cores) and
#'   cluster/*/submit_array.sh (shards x shard_cores); keep in sync
#' @return invisibly, a list of estimates per k (seconds, MB)
smoke_test <- function(cfg, n_g = 10L, n_w = 200L, n_val = 5L,
                       cores = 16L, shards = 16L, shard_cores = 4L) {
  metrics <- bench_resolve_metrics(cfg)
  m       <- length(metrics)
  since   <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "secs"))
  heap    <- function(col) sum(gc()[, col])   # col 2 = used, 6 = max used (Mb)
  rss     <- function() {                      # resident MB; NA off Linux
    f <- "/proc/self/status"
    if (!file.exists(f)) return(NA_real_)
    as.numeric(gsub("[^0-9]", "", grep("^VmRSS:", readLines(f), value = TRUE))) / 1024
  }
  big     <- function(x) format(x, big.mark = ",", scientific = x >= 1e15)
  fmt_s   <- function(s) {
    if (s < 10) sprintf("%.1f s", s)
    else if (s < 120) sprintf("%.0f s", s)
    else if (s < 7200) sprintf("%.1f min", s / 60)
    else paste(big(signif(s / 3600, 3)), "h")
  }
  fmt_mb  <- function(x) {
    if (x < 1024) sprintf("%.0f MB", x) else paste(big(signif(x / 1024, 3)), "GB")
  }

  out <- list()
  for (k in cfg$run_k) {
    key <- paste0("k", k)
    mp  <- cfg$mp_list[[key]]
    if (is.null(mp)) stop("No marginal powers defined in mp_list for ", key, ".")
    check_metrics(metrics, k)
    corr <- bench_corr(cfg$corr, k)

    t0 <- Sys.time()
    verify_engine(k, cfg$alpha, mp)
    p <- simulate_pvalues(k, cfg$alpha, mp, cfg$sim_n, cfg$seed, corr)
    verify_zero_transition(p, cfg$alpha, mp, metrics, indep = all(corr == diag(k)))
    startup_s <- since(t0)

    size <- grid_size(k, cfg$w_step, cfg$g_step, cfg$w_fixed, cfg$G_fixed)
    n_W  <- size[["n_W"]]
    n_G  <- size[["n_G"]]
    smp  <- grid_sample(k, cfg$w_step, cfg$g_step, min(n_w, n_W), min(n_g, n_G),
                        cfg$w_fixed, cfg$G_fixed)
    Gs   <- lapply(smp$g_ids, transition_matrix, G_rows = smp$G_rows)
    s_w  <- nrow(smp$W)
    s_g  <- length(Gs)

    t0 <- Sys.time()
    for (G in Gs) intersection_basis(G)
    c_G <- since(t0) / s_g
    overhead <- rss() - heap(2)
    gc(reset = TRUE)
    t0 <- Sys.time()
    search_chunk(smp$g_ids, smp$G_rows, smp$W, p, cfg$alpha, metrics, cfg$top_n)
    c_w    <- max(since(t0) - c_G * s_g, 0) / (s_g * s_w)
    heap_s <- heap(6)
    core_s <- n_G * (c_G + n_W * c_w)

    n_keep <- min(cfg$top_n * m, n_W * n_G)
    val_s  <- 0
    heap_v <- 0
    if (isTRUE(cfg$validate_n > 0)) {
      gc(reset = TRUE)
      t0 <- Sys.time()
      p_val <- simulate_pvalues(k, cfg$alpha, mp, cfg$validate_n, cfg$seed + 1L, corr)
      sim_s <- since(t0)
      idx   <- rep_len(seq_len(min(s_w, s_g)), min(n_val, n_keep))
      kept  <- list(k = k, metrics = names(metrics),
                    best = data.frame(smp$W[idx, , drop = FALSE]))
      kept$best[names(metrics)] <- NA_real_
      kept$best$G <- Gs[idx]
      t0 <- Sys.time()
      validate_best(kept, p_val, cfg$alpha, metrics)
      val_s  <- sim_s + n_keep * since(t0) / length(idx)
      heap_v <- heap(6)
      rm(p_val)
    }

    # Grid-sized arrays (W, W %*% basis, scores, g_ids) with rough copy factors.
    add      <- if (is.na(overhead)) 0 else overhead
    worker   <- function(n_workers, g_job) add + heap_s +
      8 * (n_W * (k + (2^k - 1) * k + m + 3 * (2 + m)) + g_job / n_workers) / 2^20
    main     <- function(g_job) add + max(heap_s, heap_v) +
      8 * (4 * n_W * k + 3 * g_job) / 2^20
    g_shard  <- n_G / shards
    est <- list(
      n_W = n_W, n_G = n_G, c_G = c_G, c_w = c_w, core_s = core_s,
      validate_s = val_s, startup_s = startup_s,
      worker_mb = worker(cores, n_G), main_mb = main(n_G),
      single_s  = startup_s + core_s / cores + val_s,
      single_mb = main(n_G) + cores * worker(cores, n_G),
      shard_s   = startup_s + core_s / (shards * shard_cores),
      shard_mb  = main(g_shard) + shard_cores * worker(shard_cores, g_shard),
      merge_s   = val_s, merge_mb = main(0)
    )

    cat(sprintf("\n==== smoke test k = %d: estimate for the full grid ====\n", k))
    cat(sprintf("grid        %s weight vectors x %s transition matrices = %s candidates\n",
                big(n_W), big(n_G), big(n_W * n_G)))
    if (n_W * n_G > cfg$max_candidates && !isTRUE(cfg$allow_large_k)) {
      cat(sprintf("            above max_candidates (%s): the full run needs allow_large_k=TRUE\n",
                  big(cfg$max_candidates)))
    }
    cat(sprintf("sample      %d transition matrices x %d weight vectors, sim_n = %s\n",
                s_g, s_w, big(cfg$sim_n)))
    cat(sprintf("cost        %.1f ms per transition matrix + %.2f ms per candidate\n",
                1e3 * c_G, 1e3 * c_w))
    cat(sprintf("search      %s CPU time (%s core-hours)\n",
                fmt_s(core_s), big(signif(core_s / 3600, 3))))
    if (val_s > 0) {
      cat(sprintf("validation  up to %s graphs x %s simulations: %s (serial)\n",
                  big(n_keep), big(cfg$validate_n), fmt_s(val_s)))
    }
    cat(sprintf("startup     %s per job (checks + p-values; worker start-up not included)\n",
                fmt_s(startup_s)))
    cat(sprintf("memory      %s per worker, %s main process%s\n",
                fmt_mb(est$worker_mb), fmt_mb(est$main_mb),
                if (is.na(overhead)) " (R heap only; process overhead measured on Linux)" else ""))
    cat(sprintf("single job  %d cores: wall time %s, memory %s\n",
                cores, fmt_s(est$single_s), fmt_mb(est$single_mb)))
    cat(sprintf("job array   %d shards x %d cores: wall time %s, memory %s per shard\n",
                shards, shard_cores, fmt_s(est$shard_s), fmt_mb(est$shard_mb)))
    cat(sprintf("            merge job: wall time %s, memory %s\n",
                fmt_s(est$merge_s), fmt_mb(est$merge_mb)))
    out[[key]] <- est
  }
  invisible(out)
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
#' @param cfg config list from bench_config() / bench_parse_cli()
#' @return invisibly, a named list of results per k
bench_main <- function(cfg) {
  bench_check_deps()
  if (isTRUE(cfg$smoke)) {
    if (!is.null(cfg$shard) || !is.null(cfg$merge_shards)) {
      stop("smoke=TRUE cannot be combined with shard= or merge_shards=.")
    }
    return(smoke_test(cfg))
  }
  metrics <- bench_resolve_metrics(cfg)
  merging <- !is.null(cfg$merge_shards)
  if (merging && !is.null(cfg$shard)) {
    stop("Use either shard= or merge_shards=, not both.")
  }

  out_dir <- cfg$out_dir
  if (!isTRUE(grepl("^(/|\\\\|[A-Za-z]:)", out_dir))) {
    out_dir <- file.path(bench_root(), out_dir)
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
    corr <- bench_corr(cfg$corr, k)
    tag  <- paste0("mp", paste(sprintf("%02d", round(mp * 100)), collapse = "_"))
    if (any(corr != diag(k))) {
      tag <- paste0(tag, if (length(cfg$corr) == 1L) {
        paste0("_rho", sub("-", "m", round(cfg$corr * 100), fixed = TRUE))
      } else "_corr")
    }
    if (!is.null(cfg$w_fixed)) tag <- paste0(tag, "_fixedw")
    if (!is.null(cfg$G_fixed)) tag <- paste0(tag, "_fixedg")
    stem <- if (is.null(cfg$scenario)) bench_stem(cfg$stem_prefix, k, tag) else cfg$scenario$id

    if (merging) {
      res  <- merge_shards(shard_dir, stem, cfg$merge_shards)
      miss <- setdiff(res$metrics, names(metrics))
      if (length(miss)) {
        stop("Shards use metric(s) not defined in this run: ",
             paste(miss, collapse = ", "), ". Pass the same metric arguments.")
      }
    } else {
      check_metrics(metrics, k)
      verify_engine(k, cfg$alpha, mp)
      p <- simulate_pvalues(k, cfg$alpha, mp, cfg$sim_n, cfg$seed, corr)
      verify_zero_transition(p, cfg$alpha, mp, metrics, indep = all(corr == diag(k)))

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
        G_fixed        = cfg$G_fixed,
        metrics        = metrics,
        shard          = cfg$shard
      )
      res$settings$mp   <- mp
      res$settings$seed <- cfg$seed
      res$settings$corr <- corr

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

    if (isTRUE(cfg$validate_n > 0)) {
      s      <- res$settings
      v_seed <- if (is.null(cfg$validate_seed)) s$seed + 1L else cfg$validate_seed
      if (v_seed == s$seed) stop("validate_seed must differ from seed.")
      p_val <- simulate_pvalues(k, s$alpha, s$mp, cfg$validate_n, v_seed, s$corr)
      res   <- validate_best(res, p_val, s$alpha, metrics)
      res$validation$seed <- v_seed
      cat(sprintf("[k=%d] kept graphs re-evaluated on %s simulations (seed %d)\n",
                  k, format(cfg$validate_n, big.mark = ",", scientific = FALSE),
                  v_seed))
    }
    res$meta <- bench_run_meta(cfg, metrics[res$metrics])
    results[[key]] <- res

    if (cfg$save_results) {
      save_best(res, out_dir, stem)
      cat(sprintf("[k=%d] results written to %s.rds / _top.csv / _best.csv\n",
                  k, file.path(out_dir, stem)))
      if (!is.null(cfg$scenario) &&
          identical(cfg$out_dir, file.path("results", cfg$scenario$id))) {
        bench_render_docs(cfg$scenario$id)
      }
    }
    report_best(res)
  }
  invisible(results)
}


#' Provenance stored with a result and shown in its doc.
#'
#' @param metrics the metric functions of the run (their bodies are recorded)
bench_run_meta <- function(cfg, metrics) {
  commit <- tryCatch(suppressWarnings(system2(
    "git", c("-C", shQuote(bench_root()), "rev-parse", "--short", "HEAD"),
    stdout = TRUE, stderr = FALSE)), error = function(e) character(0))
  list(
    scenario     = cfg$scenario,
    overrides    = cfg$overrides,
    run_date     = format(Sys.Date()),
    git_commit   = if (length(commit) == 1L && is.null(attr(commit, "status"))) {
      commit
    } else NA_character_,
    r_version    = paste(R.version$major, R.version$minor, sep = "."),
    graphicalMCP = as.character(utils::packageVersion("graphicalMCP")),
    metric_defs  = vapply(metrics, function(f)
      paste(trimws(deparse(body(f), width.cutoff = 500L)), collapse = " "),
      character(1))
  )
}
