#!/usr/bin/env Rscript
# =============================================================================
# Rebuild the scenario docs from saved results
# =============================================================================
# Writes docs/scenarios/<id>.md for the given scenario ids (default: every
# results/<id>/<id>.rds) and always rebuilds the index docs/README.md.
# Scenario runs do this automatically; use it after changing R/report.R or to
# resolve a merge conflict in docs/README.md.
#
# USAGE
#     Rscript scripts/renderDocs.R            # all scenarios
#     Rscript scripts/renderDocs.R my_id      # one page + index
# =============================================================================

local({
  this <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  root <- if (length(this)) {
    dirname(dirname(normalizePath(sub("^--file=", "", this[1]), winslash = "/")))
  } else {
    getwd()
  }
  source(file.path(root, "R", "rootPath.R"), local = globalenv())
})
gogt_source("R", "gridCore.R")
gogt_source("R", "report.R")

if (!interactive() && sys.nframe() == 0L) {
  ids <- commandArgs(trailingOnly = TRUE)
  gogt_render_docs(if (length(ids)) ids else NULL)
}
