# Contributing a scenario

A **scenario** is one benchmark case: k hypotheses with alpha, marginal powers,
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
   Rscript scripts/gridSearchGraph.R scenario=<id> smoke=TRUE
   ```

   It runs the checks on a random sample of the scenario's grid and prints the
   size of the full grid with its estimated CPU time, memory and wall time for
   the default cluster settings. Check that the run is feasible (see
   *Feasibility* in the [README](README.md)) and use the numbers to set
   `WALLTIME`, `CORES` and `N_SHARDS` for the cluster scripts, and `SHARD_MEM` /
   `MERGE_MEM` (MB, plus a margin) for `submit_array.sh`.
4. **Full run** with no extra `key=value` overrides, locally or on a cluster:

   ```sh
   Rscript scripts/gridSearchGraph.R scenario=<id>
   bash cluster/slurm/submit.sh scenario=<id>        # or submit_array.sh, or cluster/lsf/
   ```

   This writes `reference/<id>/` (`<id>.rds`, `<id>_best.csv`, `<id>_top.csv`)
   and `docs/scenarios/<id>.md`, and updates `docs/README.md`.
5. **Review** `docs/scenarios/<id>.md`. It must not show the
   "command-line overrides" note.
6. **Commit** and open a merge request:

   ```sh
   git add scenarios/<id>.R reference/<id>/ docs/scenarios/<id>.md docs/README.md
   ```

## Rules

- Do not change someone else's scenario; copy it to a new id instead.
- Committed results must come from the committed scenario file. If you change
  the file, re-run it, and re-run every solution in `solutions/<id>/`.
- Files in `docs/` are generated. Change `R/report.R` instead, then run
  `Rscript scripts/renderDocs.R`.
- Merge conflict in `docs/README.md`: accept either side, run
  `Rscript scripts/renderDocs.R` and commit the result.
- Keep `top_n` at most 50 so that the committed results stay small.
- Everyone with access to the repository can read the scenarios. Leave out
  confidential trial details.

# Contributing an optimizer solution

A **solution** is the graph an optimization method proposes for each metric of
a scenario, scored on the same simulations as the scenario's reference.

1. **Branch:** `git switch -c solution/<method>`.
2. **Method folder:** put the code in `optimizer/<method>/` with a `README.md`
   (method, origin, limits, requirements) and add a row to the *Optimizers*
   table in the [README](README.md#optimizers). Skip this if the folder exists.
3. **Run and save** for each scenario, with the scenario's settings
   (`bench_load_scenario(bench_config(), "<id>")`):

   ```r
   bench_save_solution("<id>", "<method>",
     graphs = list(er = graphicalMCP::graph_create(w, G)),
     time_s = c(er = ...))
   ```

   See *Solutions* in the [README](README.md#solutions). It writes
   `solutions/<id>/<method>.rds` and `<method>_best.csv`, and stops if the
   reference is missing or out of date.
4. **Commit** and open a merge request:

   ```sh
   git add optimizer/<method>/ solutions/*/<method>.rds solutions/*/<method>_best.csv
   ```

- Only write your own method's files; `<method>` is the file stem.
- Propose graphs only for the metrics your method optimizes.
