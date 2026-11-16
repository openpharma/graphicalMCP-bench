# Contributing a scenario

A **scenario** is one worked example: k hypotheses with alpha, marginal powers,
correlation, metrics and optional constraints. Each scenario is one R file in
`scenarios/`. Its key results are committed, and the generated page in
[docs/](docs/README.md) lets everyone see them without re-running anything.

## Steps

1. **Branch:** `git switch -c scenario/<id>`.
2. **Create the file:** copy `scenarios/_template.R` to `scenarios/<id>.R`.
   `<id>` uses lowercase letters, digits and `_` (e.g. `onco_dose_k3`) and must
   be new. Fill in `title`, `author`, `date`, `description`, `alpha` and `mp`,
   then `corr`, `metrics` and constraints as needed. Delete fields you leave at
   their defaults.
3. **Smoke test** (seconds, nothing written):

   ```sh
   Rscript scripts/gridSearchGraph.R scenario=<id> w_step=0.25 g_step=0.5 sim_n=2000 validate_n=0 save_results=FALSE
   ```

   It prints the number of candidates of the full grid. Check that the size is
   feasible before the full run (see *Feasibility* in the [README](README.md)).
4. **Full run** with no extra `key=value` overrides, locally or on a cluster:

   ```sh
   Rscript scripts/gridSearchGraph.R scenario=<id>
   bash cluster/slurm/submit.sh scenario=<id>        # or submit_array.sh, or cluster/lsf/
   ```

   This writes `results/<id>/` (`<id>.rds`, `<id>_best.csv`, `<id>_top.csv`)
   and `docs/scenarios/<id>.md`, and updates `docs/README.md`.
5. **Review** `docs/scenarios/<id>.md`. It must not show the
   "command-line overrides" note.
6. **Commit** and open a merge request:

   ```sh
   git add scenarios/<id>.R results/<id>/ docs/scenarios/<id>.md docs/README.md
   ```

## Rules

- Do not change someone else's scenario; copy it to a new id instead.
- Committed results must come from the committed scenario file. If you change
  the file, re-run it.
- Files in `docs/` are generated. Change `R/report.R` instead, then run
  `Rscript scripts/renderDocs.R`.
- Merge conflict in `docs/README.md`: accept either side, run
  `Rscript scripts/renderDocs.R` and commit the result.
- Keep `top_n` at most 50 so that the committed results stay small.
- Everyone with access to the repository can read the scenarios. Leave out
  confidential trial details.
