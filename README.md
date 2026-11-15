# gogt — graph optimization ground truth

Brute-force grid search over multiplicity graphs, used as **ground truth** for the
analytic/numeric optimizers in the `optimalMCP` package.

A multiplicity graph is a pair `(w, G)`: initial hypothesis weights `w` (summing to 1)
and a row-stochastic transition matrix `G` (zero diagonal, rows summing to 1). This
repo enumerates both on a regular grid, runs the full sequentially-rejective
weighted-Bonferroni graphical procedure for every candidate on **one shared matrix of
simulated p-values**, evaluates **all metrics together** on the resulting rejections,
and reports the best graphs for each metric.

Everything is under **independence** (`sim_corr = diag(k)`) with Bonferroni tests.

## Metrics

A metric is any `function(R)` returning one number to **maximize**, where `R` is the
`sim_n × k` logical rejection matrix (columns `H1..Hk`, one row per simulation).
Defaults (`GOGT_METRICS` in `R/gridCore.R`):

| key  | metric               | definition                    |
| ---- | -------------------- | ----------------------------- |
| `er` | expected rejections  | `sum(R) / nrow(R)`            |
| `dp` | disjunctive power    | `mean(rowSums(R) > 0)`        |
| `cp` | conjunctive power    | `mean(rowSums(R) == ncol(R))` |

DP depends on `w` only (the first rejection always happens at the initial weights), so
DP ties across `G` are broken by the other metrics.

Custom metrics, either in the `cfg` block of `scripts/gridSearchGraph.R`:

```r
metrics = c(GOGT_METRICS, list(h1h2 = function(R) mean(R[, "H1"] & R[, "H2"])))
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
names and not `G`, `g_id`, `w_id`, `w<i>` or `rank_*`.

## Layout

```
R/
  rootPath.R           gogt_root() / gogt_source(): cwd-independent path resolution
  utils.R              solve_eta, sigma_matrix, inverse_derivative
  constraintBonf.R     Bonferroni equality constraint for nloptr
  expectedRejections.R analytic E[R] + weight optimizer (optim_w_er)
  analyticDP.R         analytic DP/CP under independence
  gridCore.R           metrics, simplex/transition grids, rejection engine, grid_search_k, reporting
  gridRunner.R         config, CLI parsing, verification, main loop
scripts/
  gridSearchGraph.R    entry point (all metrics in one run)
  compareExpectedRejections.R  analytic E[R] vs graphicalMCP simulation
cluster/
  lsf/submit.sh        LSF (bsub): one multi-node job
  lsf/submit_array.sh  LSF job array: independent shards + merge job
  slurm/submit.sh      Slurm (sbatch): one multi-node job
  slurm/submit_array.sh  Slurm job array: independent shards + merge job
  slurm/srun-rsh.sh    starts remote PSOCK workers via srun instead of ssh
results/               default out_dir for RDS/CSV artifacts
```

`R/utils.R`, `R/constraintBonf.R` and `R/expectedRejections.R` are vendored from
`optimalMCP` so this repo runs standalone — there is no `library(optimalMCP)` anywhere.

## Requirements

- R, plus `graphicalMCP` and `parallelly` (`parallel` ships with base R).
- `nloptr` only for `optim_w_er()` in `R/expectedRejections.R` (not used by the grid search).

On a cluster, those packages must be visible from **every** compute node.

## Running

Scripts resolve `R/` relative to their own location, so any working directory works.

```sh
# Smoke-sized run: 3 hypotheses, coarse grid, nothing written to disk
Rscript scripts/gridSearchGraph.R 0.9 0.8 0.7 \
  w_step=0.25 g_step=0.5 sim_n=2000 top_n=5 save_results=FALSE

# Default k=3 run (er, dp, cp), results written to results/
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70

# Add custom metrics and evaluate only some of them
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70 metrics_file=my_metrics.R metrics=er,h1h2
```

Positional numeric arguments are the marginal powers; their count defines `k`.
`key=value` arguments override config fields: `alpha`, `sim_n`, `w_step`, `g_step`,
`w_fixed`, `seed`, `top_n`, `out_dir`, `stem_prefix`, `allow_large_k`, `max_candidates`,
`save_results`, `max_workers`, `metrics` (comma list), `metrics_file`, `shard`,
`merge_shards`. Unknown keys and unparsable values are errors.

Pass `w_fixed=0.5,0.3,0.2` to skip the weight simplex and search only `G`; those runs
are tagged `_fixedw` so they do not overwrite full-grid results. Use `stem_prefix` to
keep runs with different metric sets apart.

Defaults live in the `cfg <- gogt_config(...)` block of the script.

### How a run works

1. `sim_n × k` p-values are simulated **once** per `k` (by graphicalMCP, with `seed`),
   so every candidate sees the same random numbers.
2. For each `G`, the intersection weights are linear in `w`, so they are built once
   from the `k` unit-weight graphs and reused for every `w`.
3. Each candidate's rejection matrix `R` comes from a vectorised form of
   graphicalMCP's Bonferroni shortcut; every metric is evaluated on that `R`.
4. Workers keep only the union of the per-metric top `top_n`, so memory stays small.

This gives results identical to calling `graph_calculate_power()` per candidate, at
~2–3 ms per candidate for all metrics (`sim_n = 1e4`) instead of ~55 ms per metric.

### Cluster

One job runs all metrics. Pick the script for your scheduler:

```sh
bash cluster/lsf/submit.sh                             # LSF:   er, dp, cp in one job
bash cluster/slurm/submit.sh                           # Slurm: er, dp, cp in one job
bash cluster/slurm/submit.sh 0.9 0.8 0.7 w_step=0.02 metrics_file=my_metrics.R
PARTITION=short SBATCH_TIMELIMIT=02:00:00 bash cluster/slurm/submit.sh
```

Defaults (`MP`, `ARGS`, partition/queue, resources) are set at the top of each script.
On the command line, positional numbers replace `MP` (the marginal powers), `key=value`
arguments override `ARGS` (last value wins), and `PARTITION` (Slurm) / `QUEUE` (LSF)
select the partition/queue. On Slurm any other `#SBATCH` line can be overridden with
the matching `SBATCH_*` environment variable. The job is named and logged as
`gogt_k<k>` under `logs/`.

Workers are auto-detected via `parallelly::availableWorkers()`, which reads the
allocation (LSF: `LSB_MCPU_HOSTS` / `LSB_HOSTS`; Slurm: `SLURM_JOB_NODELIST` /
`SLURM_JOB_CPUS_PER_NODE`) and spans every allocated core on every node through a PSOCK
cluster. Remote workers are started with:

- **LSF**: ssh by default; `R_PARALLELLY_MAKENODEPSOCK_RSHCMD=blaunch` if ssh between
  nodes is blocked.
- **Slurm**: `cluster/slurm/srun-rsh.sh` (an `srun --overlap` job step per worker), so
  no ssh is needed and workers inherit the job environment. Needs Slurm ≥ 20.11.
  Don't request `--cpus-per-task=1`: parallelly then counts one worker per node.

See the notes at the end of each script for the reverse-tunnel caveat.

### Job arrays

Alternatively, split the search into independent shards (no communication between
nodes, small jobs that queue easily, failed shards can be re-run alone):

```sh
bash cluster/slurm/submit_array.sh             # or cluster/lsf/submit_array.sh
bash cluster/slurm/submit_array.sh 0.9 0.8 0.7 sim_n=20000   # same arguments as above
N_SHARDS=32 CORES=2 bash cluster/slurm/submit_array.sh       # array size / cores per task
ARRAY=3,7 bash cluster/slurm/submit_array.sh   # re-run shards 3 and 7, then merge again
```

Each array task runs `gridSearchGraph.R ... shard=i/N`: it searches every `N`-th
transition matrix starting at `i` on its own node's cores and writes
`<out_dir>/shards/<stem>_shard<i>of<N>.rds`. A dependent job then runs
`... merge_shards=N`, which combines the shards into `<out_dir>/<stem>.rds` /
`_top.csv`. All shards use the same seed and hence the same p-values, so the merged
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
`max_candidates` (1e8) abort otherwise.

## Output

Written to `out_dir` (default `results/`):

- `gridSearch_k<k>_mp<..>[_fixedw].rds` — the `grid_search_k()` result:
  `best` (data frame), `k`, `metrics`, `n_candidates`.
- `gridSearch_k<k>_mp<..>[_fixedw]_top.csv` — `best` flattened.

`best` holds the union of the top `top_n` graphs of every metric, one row per graph:
weights `w1..wk`, one column per metric, `rank_<metric>` (`NA` outside that metric's
top `top_n`), `g_id` and `G`. Rows are sorted by the first metric; ties are broken by
the other metrics. In the CSV, `G` is a semicolon-delimited string in column-major
order: `matrix(as.numeric(strsplit(G, ";")[[1]]), k)`.

The tag encodes the marginal powers, e.g. `mp90_80_70`, so parallel runs do not clash.

## Verification

Every run starts with two cross-checks, and stops if either fails:

```
[verify k=3] engine matches graphicalMCP on 5 random graphs
[verify k=3] G=0 er: analytic=... simulated=... diff=...
```

1. The rejection engine is run on random graphs (with zero weights/transitions) and
   must reproduce `graph_calculate_power()`'s rejection matrix exactly.
2. With `G = 0` no alpha is propagated, so the procedure reduces to a single-step
   weighted-Bonferroni test with closed-form E[R]/DP/CP. On the run's own p-values
   the difference must be within 4 MC standard errors (`2 * sqrt(k / sim_n)`).
   Only the default `er`/`dp`/`cp` metrics are checked.

`scripts/compareExpectedRejections.R` runs the analytic comparison across several
scenarios, including per-hypothesis rejection probabilities.
