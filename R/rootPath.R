# =============================================================================
# Repository root resolution
# =============================================================================
# Scripts in scripts/ need to source R/*.R regardless of the working directory
# (cluster jobs start in the submission directory, interactive sessions start
# anywhere). These two helpers locate the repo root from the running file's own
# path.
# =============================================================================

#' Absolute path of the gogt repository root.
#'
#' Resolution order:
#'   1. GOGT_ROOT environment variable (explicit override).
#'   2. The `--file=` argument of the running Rscript.
#'   3. `ofile` of the calling frame, set by `source()` in interactive sessions.
#'   4. The working directory.
#' From 2-4 the directory is walked upwards until an R/gridCore.R is found, so
#' scripts may live at any depth (scripts/, optimizer/<method>/, ...).
#'
#' @return absolute path to the repository root
gogt_root <- function() {
  env <- Sys.getenv("GOGT_ROOT", "")
  if (nzchar(env)) return(normalizePath(env, winslash = "/", mustWork = TRUE))

  find_up <- function(dir) {
    dir <- normalizePath(dir, winslash = "/", mustWork = FALSE)
    repeat {
      if (file.exists(file.path(dir, "R", "gridCore.R"))) return(dir)
      parent <- dirname(dir)
      if (identical(parent, dir)) return(NULL)
      dir <- parent
    }
  }

  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg)) {
    script <- normalizePath(sub("^--file=", "", file_arg[1]),
                            winslash = "/", mustWork = FALSE)
    if (file.exists(script) && !is.null(root <- find_up(dirname(script)))) {
      return(root)
    }
  }

  for (n in seq_len(sys.nframe())) {
    ofile <- tryCatch(get("ofile", envir = sys.frame(n), inherits = FALSE),
                      error = function(e) NULL)
    if (is.character(ofile) && length(ofile) == 1L && file.exists(ofile) &&
        !is.null(root <- find_up(dirname(ofile)))) {
      return(root)
    }
  }

  root <- find_up(getwd())
  if (!is.null(root)) return(root)
  stop("Cannot locate the gogt repository root. Set the GOGT_ROOT environment ",
       "variable or run from inside the repository.")
}

#' Source a file given relative to the repository root.
#'
#' @param ... path components below the repo root, e.g. `"R", "utils.R"`
gogt_source <- function(...) {
  path <- file.path(gogt_root(), ...)
  if (!file.exists(path)) stop("File not found: ", path)
  source(path, local = globalenv())
  invisible(path)
}
