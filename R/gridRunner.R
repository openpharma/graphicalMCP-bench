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
#' @param objective one of names(GOGT_OBJECTIVES)
#' @param ... overrides applied on top of the defaults
#' @return named list consumed by gogt_main()
gogt_config <- function(objective = "er", ...) {
  cfg <- list(
    objective      = objective,
    stem_prefix    = paste0("gridSearch", toupper(objective)),

    ## -- Problem definition ---------------------------------------------------
    alpha          = 0.025,       # one-sided family-wise type I error
    # Which hypothesis counts to run. Default 3; add 4 / 5 only with a coarse
    # grid and allow_large_k = TRUE (see the feasibility warning in gridCore.R).
    run_k          = c(3),
    # Marginal power per hypothesis, one numeric vector per k in run_k. Names
    # must be "k3", "k4", "k5" and the vector length must equal k.
    mp_list        = list(k3 = c(0.90, 0.80, 0.70)),

    ## -- Grid resolution ------------------------------------------------------
    w_step         = 0.05,        # step for the hypothesis-weight simplex
    g_step         = 0.1,         # step for the transition-weight simplex (per row)
    # Optionally FIX the hypothesis weights instead of gridding over them. When a
    # numeric vector (length k, summing to 1) is supplied the weight simplex is
    # skipped and only G is searched; results are tagged "fixedw".
    w_fixed        = NULL,

    ## -- Monte-Carlo / runtime ------------------------------------------------
    sim_n          = 1e4,         # MC replications per candidate
    seed           = 2024,        # base RNG seed (common random numbers across
                                  #   candidates -> more stable ranking)
    # Workers are auto-detected via parallelly::availableWorkers() (LSF-aware).
    # Set max_workers to cap the count, or NULL to use every allocated core.
    max_workers    = NULL,

    ## -- Output ---------------------------------------------------------------
    top_n          = 50L,         # how many best graphs to keep / report per k
    save_results   = TRUE,        # write RDS/CSV of the top_n table
    save_full      = FALSE,       # ALSO save the FULL candidate table (can be GBs)
    out_dir        = "results",   # relative paths resolve against the repo root

    ## -- Safety gate for large k ----------------------------------------------
    allow_large_k  = FALSE,       # set TRUE only after coarsening the grid for k>3
    max_candidates = 1e8          # hard stop above this many candidates
  )
  modifyList(cfg, list(...))
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

  for (item in kv) {
    p   <- strsplit(item, "=", fixed = TRUE)[[1]]
    key <- p[1]; val <- p[2]
    if      (key == "sim_n")          cfg$sim_n          <- as.numeric(val)
    else if (key == "w_step")         cfg$w_step         <- as.numeric(val)
    else if (key == "g_step")         cfg$g_step         <- as.numeric(val)
    else if (key == "w_fixed")        cfg$w_fixed        <- as.numeric(strsplit(val, ",", fixed = TRUE)[[1]])
    else if (key == "seed")           cfg$seed           <- as.integer(val)
    else if (key == "top_n")          cfg$top_n          <- as.integer(val)
    else if (key == "out_dir")        cfg$out_dir        <- val
    else if (key == "allow_large_k")  cfg$allow_large_k  <- as.logical(val)
    else if (key == "max_candidates") cfg$max_candidates <- as.numeric(val)
    else if (key == "save_full")      cfg$save_full      <- as.logical(val)
    else if (key == "save_results")   cfg$save_results   <- as.logical(val)
    else if (key == "max_workers")    cfg$max_workers    <- as.integer(val)
    else if (key == "objective") {
      cfg$objective   <- val
      cfg$stem_prefix <- paste0("gridSearch", toupper(val))
    }
    else warning("Unknown CLI option ignored: ", key)
  }
  cfg
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


#' Analytic value of an objective for a single-step weighted-Bonferroni test.
#'
#' This is the G = 0 case: no alpha is propagated, so the graphical procedure
#' reduces to the closed forms in R/expectedRejections.R / R/analyticDP.R.
#'
#' @return numeric, or NULL when the analytic reference is unavailable
gogt_analytic <- function(w, alpha, mp, objective) {
  switch(objective,
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


#' Cross-check: with G = 0 the simulated objective must match the analytic
#' single-step value within Monte-Carlo error.
verify_zero_transition <- function(k, alpha, mp, objective = "er",
                                   sim_n = 1e5, seed = 2024) {
  w   <- rep(1 / k, k)
  ana <- gogt_analytic(w, alpha, mp, objective)
  if (is.null(ana)) {
    message("Analytic reference for '", objective,
            "' not loaded; skipping cross-check.")
    return(invisible(NULL))
  }
  sim   <- eval_graph(w, matrix(0, k, k), alpha, mp, sim_n, seed, objective)
  label <- gogt_objective(objective)$label
  cat(sprintf("[verify k=%d] G=0 %s: analytic=%.5f  simulated=%.5f  diff=%+.5f\n",
              k, label, ana, sim, sim - ana))
  invisible(list(analytic = ana, simulated = sim))
}


#' Fast pipeline smoke test on a coarse grid (seconds, not the full run).
smoke_test <- function(k = 3, alpha = 0.025, mp = c(0.8, 0.7, 0.9),
                       objective = "er") {
  res <- grid_search_k(k, alpha, mp, w_step = 0.25, g_step = 0.5,
                       sim_n = 2e3, seed = 1, top_n = 5, cl = NULL,
                       allow_large_k = TRUE, max_candidates = Inf,
                       objective = objective)
  report_best(k, res)
  invisible(res)
}


#' Run the grid search for every k in the config.
#'
#' @param cfg config list from gogt_config() / gogt_parse_cli()
#' @return invisibly, a named list of grid_search_k() results per k
gogt_main <- function(cfg) {
  gogt_check_deps()
  gogt_objective(cfg$objective)

  out_dir <- cfg$out_dir
  if (!isTRUE(grepl("^(/|\\\\|[A-Za-z]:)", out_dir))) {
    out_dir <- file.path(gogt_root(), out_dir)
  }

  cl <- make_cluster(cfg$max_workers)
  if (!is.null(cl)) on.exit(parallel::stopCluster(cl), add = TRUE)

  results <- list()
  for (k in cfg$run_k) {
    key <- paste0("k", k)
    mp  <- cfg$mp_list[[key]]
    if (is.null(mp)) stop("No marginal powers defined in mp_list for ", key, ".")

    verify_zero_transition(k, cfg$alpha, mp, cfg$objective)

    res <- grid_search_k(
      k              = k,
      alpha          = cfg$alpha,
      mp             = mp,
      w_step         = cfg$w_step,
      g_step         = cfg$g_step,
      sim_n          = cfg$sim_n,
      seed           = cfg$seed,
      top_n          = cfg$top_n,
      cl             = cl,
      allow_large_k  = cfg$allow_large_k,
      max_candidates = cfg$max_candidates,
      w_fixed        = cfg$w_fixed,
      objective      = cfg$objective
    )
    report_best(k, res)
    results[[key]] <- res

    # Tag output files with the marginal powers so array jobs don't clash.
    tag <- paste0("mp", paste(sprintf("%02d", round(mp * 100)), collapse = "_"))
    if (!is.null(cfg$w_fixed)) tag <- paste0(tag, "_fixedw")
    if (cfg$save_results) {
      save_best(k, res, out_dir, cfg$save_full, tag = tag,
                stem_prefix = cfg$stem_prefix)
    }
  }
  invisible(results)
}
