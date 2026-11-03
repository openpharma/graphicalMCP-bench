# =============================================================================
# Repository root resolution
# =============================================================================
# Scripts in scripts/ need to source R/*.R regardless of the working directory
# (LSF jobs start in LS_SUBCWD, interactive sessions start anywhere). These two
# helpers locate the repo root from the running file's own path.
# =============================================================================

#' Absolute path of the gogt repository root.
#'
#' Resolution order:
#'   1. GOGT_ROOT environment variable (explicit override).
#'   2. The `--file=` argument of the running Rscript (scripts/<name>.R -> ..).
#'   3. `ofile` of the calling frame, set by `source()` in interactive sessions.
#'   4. The working directory, walked upwards until an R/gridCore.R is found.
#'
#' @return absolute path to the repository root
gogt_root <- function() {
  env <- Sys.getenv("GOGT_ROOT", "")
  if (nzchar(env)) return(normalizePath(env, winslash = "/", mustWork = TRUE))

  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg)) {
    script <- normalizePath(sub("^--file=", "", file_arg[1]),
                            winslash = "/", mustWork = FALSE)
    if (file.exists(script)) return(dirname(dirname(script)))
  }

  for (n in seq_len(sys.nframe())) {
    ofile <- tryCatch(get("ofile", envir = sys.frame(n), inherits = FALSE),
                      error = function(e) NULL)
    if (is.character(ofile) && length(ofile) == 1L && file.exists(ofile)) {
      return(dirname(dirname(normalizePath(ofile, winslash = "/"))))
    }
  }

  dir <- normalizePath(getwd(), winslash = "/")
  repeat {
    if (file.exists(file.path(dir, "R", "gridCore.R"))) return(dir)
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
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
