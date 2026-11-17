# graphicalmcp-bench

Case studies for comparing optimizers of multiplicity graphs, built on the R package
`graphicalMCP` (not `gMCP`). Each case is a *scenario*, and a brute-force grid search
gives its **reference solution**, against which analytic/numeric graph optimizers are
compared (see [Optimizers](#optimizers)). The reference is optimal only on the grid and
up to Monte-Carlo error, so an optimizer that searches continuously may beat it.

A multiplicity graph is a pair `(w, G)`: initial hypothesis weights `w` (summing to 1)
and a row-stochastic transition matrix `G` (zero diagonal, rows summing to 1). This
repo enumerates both on a regular grid, runs the full sequentially-rejective
weighted-Bonferroni graphical procedure for every candidate on **one shared matrix of
simulated p-values**, evaluates **all metrics together** on the resulting rejections,
and reports the best graphs for each metric.

Tests are weighted Bonferroni. The test statistics may be correlated; the correlation
only changes the simulated p-values.

The scenarios live in `scenarios/` (one file each), and their reference results are
presented in [docs/](docs/README.md). To add one, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Scenarios

A scenario file `scenarios/<id>.R` defines a list `scenario` with `title`, `author`,
`alpha` and `mp` (marginal powers; their count is `k`), and optionally `corr`, `metrics`,
`w_fixed`, `G_fixed`, grid and simulation settings. See `scenarios/_template.R` for every
field, and `scenarios/example_k3.R` for a worked example.

```sh
Rscript scripts/gridSearchGraph.R scenario=example_k3
```

This writes the reference solution to `reference/<id>/<id>.rds`, `_best.csv` and
`_top.csv`, renders `docs/scenarios/<id>.md` and rebuilds the index `docs/README.md`.
Other `key=value` arguments override the file (e.g. a coarser grid); the page then shows
the overrides. `Rscript scripts/renderDocs.R [id ...]` rebuilds the pages from the saved
results.

## Correlation

`corr` is `NULL` (independence, the default), one number (equicorrelation) or a `k × k`
correlation matrix. It must be symmetric, have a unit diagonal and be positive
semi-definite. On the command line, `corr=0.3` sets an equicorrelation. E[R] does not
depend on the correlation; DP, CP and joint metrics do.

## Constraints

`w_fixed` (length `k`) and `G_fixed` (`k × k`, rows = from) fix single entries: `NA`
means free and a number means fixed (0 removes a weight or an edge). Free entries share
what the fixed ones leave, on the same grid, so every row still sums to 1 when it has a
free entry. Fixed values must therefore leave a multiple of the step, or the run stops.
A row whose entries are all fixed may sum to less than 1. The diagonal of `G_fixed` must
be `NA` or 0.

```r
w_fixed = c(NA, NA, 0)                         # H3 starts with no alpha
G_fixed = matrix(c(NA, NA, NA,
                   NA, NA,  0,                 # no edge H2 -> H3
                   NA, NA, NA), 3, byrow = TRUE)
```

Constraints are applied while the grid is built, so they shrink the candidate space and
make larger `k` more feasible. On the command line, `w_fixed=0.5,NA,NA` works; `G_fixed`
can only be set in a scenario file or in the `cfg` block of the script.

## Metrics

A metric is any `function(R)` returning one number to **maximize**, where `R` is the
`sim_n × k` logical rejection matrix (columns `H1..Hk`, one row per simulation).
Defaults (`BENCH_METRICS` in `R/gridCore.R`):

| key  | metric               | definition                    |
| ---- | -------------------- | ----------------------------- |
| `er` | expected rejections  | `sum(R) / nrow(R)`            |
| `dp` | disjunctive power    | `mean(rowSums(R) > 0)`        |
| `cp` | conjunctive power    | `mean(rowSums(R) == ncol(R))` |

DP depends on `w` only (the first rejection always happens at the initial weights), so
DP ties across `G` are broken by the other metrics.

Custom metrics, either in the `cfg` block of `scripts/gridSearchGraph.R`:

```r
metrics = c(BENCH_METRICS, list(h1h2 = function(R) mean(R[, "H1"] & R[, "H2"])))
```

or in a file passed as `metrics_file=<path.R>`, which must define a named list
`metrics`; it is merged into the defaults (same name overrides):

```r
# my_metrics.R
metrics <- list(
  h1h2 = function(R) mean(R[, "H1"] & R[, "H2"]),           # P(reject H1 and H2)
  wer  = function(R) sum(R %*% c(2, 1, 1)) / nrow(R)        # weighted E[R], k = 3
)
```

`metrics=er,h1h2` selects / orders the metrics to evaluate (the first one orders the
output table). To minimize something, return its negative. Metric names must be valid R
names and not `G`, `g_id`, `w_id`, `metric`, `w<i>`, `rank_*`, `*_val` or `*_se`.

## Optimizers

The optimization methods to be compared against the grid search live in
`optimizer/<method>/`, one folder per method:

| method | status | optimizes |
| ------ | ------ | --------- |
| [optimalMCP](optimizer/optimalMCP/README.md) | placeholder | weights `w` maximizing E[R] of the single-step test (no `G` yet) |

Each folder is self-contained: its own code, its own dependencies and a `README.md`
that describes the method, its origin and its limits. Optimizers never change `R/`,
and the grid search never loads anything from `optimizer/`, so the cluster only needs
the grid's packages. How optimizers are run and scored against the grid is still to be
designed.

## Layout

```
CONTRIBUTING.md        how to add a scenario
R/
  rootPath.R           bench_root() / bench_source(): cwd-independent path resolution
  analytic.R           closed-form E[R] (any correlation) and DP/CP (independence) for G = 0
  gridCore.R           metrics, constrained grids, rejection engine, grid_search_k,
                       re-evaluation, saving
  gridRunner.R         config, CLI parsing, scenario loading, verification, main loop
  report.R             markdown pages of scenario results
scenarios/
  _template.R          documented template (copy to <id>.R)
  <id>.R               one shared example per file
scripts/
  gridSearchGraph.R    entry point (all metrics in one run)
  renderDocs.R         rebuild docs/ from reference/<id>/<id>.rds
optimizer/
  optimalMCP/          optim_w_er (vendored from optimalMCP) + its check script
cluster/
  args.sh              argument handling shared by the submit scripts
  lsf/submit.sh        LSF (bsub): one multi-node job
  lsf/submit_array.sh  LSF job array: independent shards + merge job
  slurm/submit.sh      Slurm (sbatch): one multi-node job
  slurm/submit_array.sh  Slurm job array: independent shards + merge job
  slurm/srun-rsh.sh    starts remote PSOCK workers via srun instead of ssh
reference/<id>/        committed scenario reference solutions
results/               ad-hoc runs (local, not committed)
docs/                  generated: README.md (index) + scenarios/<id>.md
```

## Requirements

- R, plus `graphicalMCP` and `parallelly` (`parallel` ships with base R).
- Optimizers have their own requirements (see their README), e.g. `nloptr` for
  `optimizer/optimalMCP`.

On a cluster, those packages must be visible from **every** compute node.

## Running

Scripts resolve `R/` relative to their own location, so any working directory works.

```sh
# Smoke test: checks plus a time / memory estimate of the full run, nothing written
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70 smoke=TRUE

# Default k=3 run (er, dp, cp), results written to results/
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70

# Add custom metrics and evaluate only some of them
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70 metrics_file=my_metrics.R metrics=er,h1h2
```

Positional numeric arguments are the marginal powers; their count defines `k`.
`key=value` arguments override config fields: `scenario`, `alpha`, `corr`, `sim_n`,
`w_step`, `g_step`, `w_fixed`, `seed`, `top_n`, `validate_n`, `validate_seed`, `out_dir`,
`stem_prefix`, `allow_large_k`, `max_candidates`, `save_results`, `max_workers`,
`metrics` (comma list), `metrics_file`, `shard`, `merge_shards`, `smoke`. Unknown keys and
unparsable values are errors. With `scenario=`, positional arguments are not allowed.

`smoke=TRUE` runs the checks on a random sample of the real grid (10 transition
matrices × 200 weight vectors at the run's `sim_n`, metrics and constraints) and prints
the grid size, the search CPU time, the validation time, the memory per worker and of
the main process, and the wall time and memory of the default cluster jobs. The full
grid is counted, never built, so this is safe for any grid size.

Pass `w_fixed=0.5,0.3,0.2` to skip the weight simplex and search only `G`, or
`w_fixed=0.5,NA,NA` to fix only some weights. Ad-hoc runs are tagged `_fixedw` /
`_fixedg` / `_rho<xx>` / `_corr` so they do not overwrite unconstrained or independent
results. Use `stem_prefix` to keep runs with different metric sets apart.

Defaults live in the `cfg <- bench_config(...)` block of the script.

### How a run works

1. `sim_n × k` p-values are simulated **once** per `k` (by graphicalMCP, with `seed`),
   so every candidate sees the same random numbers.
2. For each `G`, the intersection weights are linear in `w`, so they are built once
   from the `k` unit-weight graphs and reused for every `w`.
3. Each candidate's rejection matrix `R` comes from a vectorised form of
   graphicalMCP's Bonferroni shortcut; every metric is evaluated on that `R`.
4. Workers keep only the union of the per-metric top `top_n`, so memory stays small.
5. The kept graphs are re-evaluated on `validate_n` (default 1e5) fresh simulations
   (`validate_seed`, default `seed + 1`). The search values of the winners are
   optimistic because they were selected on the same p-values; the re-evaluated values
   are unbiased. Their standard errors come from 20 batch means, so they work for any
   metric that averages over simulations. The ranking still uses the search values.
   `validate_n=0` skips this step.

This gives results identical to calling `graph_calculate_power()` per candidate, at
~2–3 ms per candidate for all metrics (`sim_n = 1e4`) instead of ~55 ms per metric.

### Cluster

One job runs all metrics. Size it with the smoke test (`smoke=TRUE`) first. Pick the
script for your scheduler:

```sh
bash cluster/slurm/submit.sh scenario=my_id            # a scenario file defines the run
bash cluster/lsf/submit.sh                             # LSF:   er, dp, cp in one job
bash cluster/slurm/submit.sh                           # Slurm: er, dp, cp in one job
bash cluster/slurm/submit.sh 0.9 0.8 0.7 w_step=0.02 metrics_file=my_metrics.R
PARTITION=short WALLTIME=02:00:00 bash cluster/slurm/submit.sh
QUEUE=short WALLTIME=2:00 bash cluster/lsf/submit.sh
NODES=2 CORES=32 bash cluster/slurm/submit.sh          # 2 nodes x 32 cores = 64 workers
```

Defaults (`MP`, `ARGS`, partition/queue, resources) are set at the top of each script.
With `scenario=<id>`, `MP` and `ARGS` are ignored and the job is named `bench_<id>`.
On the command line, positional numbers replace `MP` (the marginal powers), `key=value`
arguments override `ARGS` (last value wins), and `PARTITION` (Slurm) / `QUEUE` (LSF)
select the partition/queue (unset = the cluster's default; list them with `sinfo -s` /
`bqueues`). `NODES` and `CORES` (per node) set the allocation of the single-job
scripts (default: no node count, i.e. 1 node, × 16 cores; keep `CORES` ≤ the CPUs per
node). `WALLTIME` sets the time limit: `HH:MM` on LSF (default `8:00`),
`[D-]HH:MM:SS` on Slurm (default `08:00:00`). On Slurm, account, memory etc. can be
overridden with the matching `SBATCH_*` environment variable. The job is named
and logged as `bench_k<k>` under `logs/`.

Workers are auto-detected via `parallelly::availableWorkers()`, which reads the
allocation (LSF: `LSB_MCPU_HOSTS` / `LSB_HOSTS`; Slurm: `SLURM_JOB_NODELIST` /
`SLURM_JOB_CPUS_PER_NODE`) and spans every allocated core on every node through a PSOCK
cluster. Remote workers are started with:

- **LSF**: ssh by default; `R_PARALLELLY_MAKENODEPSOCK_RSHCMD=blaunch` if ssh between
  nodes is blocked.
- **Slurm**: `cluster/slurm/srun-rsh.sh` (an `srun --overlap` job step per worker), so
  no ssh is needed and workers inherit the job environment. Needs Slurm ≥ 20.11.
  Each node gets one task with `CORES` CPUs (`--cpus-per-task`), which parallelly uses
  as the worker count; some clusters reject `--ntasks-per-node` > 1.

See the notes at the end of each script for the reverse-tunnel caveat.

### Job arrays

Alternatively, split the search into independent shards (no communication between
nodes, small jobs that queue easily, failed shards can be re-run alone):

```sh
bash cluster/slurm/submit_array.sh             # or cluster/lsf/submit_array.sh
bash cluster/slurm/submit_array.sh 0.9 0.8 0.7 sim_n=20000   # same arguments as above
N_SHARDS=32 CORES=2 bash cluster/slurm/submit_array.sh       # array size / cores per task
MAX_RUNNING=4 bash cluster/slurm/submit_array.sh             # at most 4 tasks at once
WALLTIME=00:20:00 MERGE_WALLTIME=00:15:00 bash cluster/slurm/submit_array.sh
ARRAY=3,7 bash cluster/slurm/submit_array.sh   # re-run shards 3 and 7, then merge again
```

Arrays have no node count: each task takes `CORES` cores on one node and the scheduler
places the tasks; `MAX_RUNNING` caps how many run at the same time. `WALLTIME` is the
limit per task and `MERGE_WALLTIME` that of the merge job (both default 8 h).

Each array task runs `gridSearchGraph.R ... shard=i/N`: it searches every `N`-th
transition matrix starting at `i` on its own node's cores and writes
`<out_dir>/shards/<stem>_shard<i>of<N>.rds`. For a scenario the shards go to
`results/shards/<id>_shard<i>of<N>.rds` instead, so `reference/` only holds committed
files. A dependent job then runs
`... merge_shards=N`, which combines the shards into `<out_dir>/<stem>.rds` /
`_top.csv` / `_best.csv`, re-evaluates the kept graphs and, for a scenario, renders its
page. All shards use the same seed and hence the same p-values, so the merged
result is identical to a single run. Re-runs must use the same `N_SHARDS` and arguments
as the original submission.

## Feasibility

The candidate space is (# weight vectors) × (# transition matrices). With a fine grid
(`w_step = 0.01`, `g_step = 0.05`):

| k | weight vectors | transition matrices | candidates |
| - | -------------- | ------------------- | ---------- |
| 3 | 5,151          | 9,261               | ~4.8e7     |
| 4 | 1.8e5          | 2.9e9               | ~5e14      |
| 5 | 4.6e6          | 1.7e16              | ~8e22      |

`k > 3` therefore requires a much coarser grid **and** `allow_large_k=TRUE`; runs above
`max_candidates` (1e8) abort otherwise. Fixed entries (`w_fixed`, `G_fixed`) shrink both
factors.

## Output

A scenario run writes to `reference/<id>/` with stem `<id>`. An ad-hoc run writes to
`out_dir` (default `results/`, not committed) with stem
`gridSearch_k<k>_mp<..>[_rho<xx>|_corr][_fixedw][_fixedg]`:

- `<stem>.rds`: the full result, with `best` (data frame), `k`, `metrics`,
  `n_candidates`, `settings` (alpha, mp, corr, constraints, grid, seed),
  `validation` (sim_n, seed, batches) and `meta` (scenario, overrides, run date, git
  commit, R / graphicalMCP versions, metric definitions).
- `<stem>_best.csv`: **the key result**, one row per metric with the graph that is
  optimal for it (`metric`, `w1..wk`, every metric's search value, `_val` and `_se`, `G`).
- `<stem>_top.csv`: `best` flattened.

`best` holds the union of the top `top_n` graphs of every metric, one row per graph:
weights `w1..wk`; per metric the search value, the re-evaluated value `<metric>_val`
and its standard error `<metric>_se`; `g_id`; `rank_<metric>` (`NA` outside that
metric's top `top_n`); and `G`. Rows are sorted by the first metric; ties are broken by
the other metrics. In the CSV, `G` is a semicolon-delimited string in column-major
order: `matrix(as.numeric(strsplit(G, ";")[[1]]), k)`.

The page `docs/scenarios/<id>.md` shows the setup, the trade-off between the
metric-optimal graphs, every optimal `w` and `G`, and the top 10 per metric. Graphs
with identical values are collapsed into one row.

## Verification

Every run starts with two cross-checks, and stops if either fails:

```
[verify k=3] engine matches graphicalMCP on 5 random graphs
[verify k=3] G=0 er: analytic=... simulated=... diff=...
```

1. The rejection engine is run on random graphs (with zero weights/transitions) and
   must reproduce `graph_calculate_power()`'s rejection matrix exactly.
2. With `G = 0` no alpha is propagated, so the procedure reduces to a single-step
   weighted-Bonferroni test with closed-form E[R]/DP/CP (`R/analytic.R`). On the run's
   own p-values the difference must be within 4 MC standard errors
   (`2 * sqrt(k / sim_n)`). Only the default `er`/`dp`/`cp` metrics are checked. With
   correlation only `er` is checked, because the closed-form DP/CP assume independence.
