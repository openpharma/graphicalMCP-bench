# Scripts

Both entry points work from any working directory.

| Script | Purpose |
|--------|---------|
| `gridSearchGraph.R` | Grid search (or smoke test) for a scenario or for ad-hoc marginal powers |
| `renderDocs.R` | Rebuild `docs/` from saved results |

## gridSearchGraph.R

```sh
# Scenario: writes reference/<id>/ and docs/scenarios/<id>.md
Rscript scripts/gridSearchGraph.R scenario=example_k3 smoke=TRUE   # checks + estimate, nothing written
Rscript scripts/gridSearchGraph.R scenario=example_k3

# Ad hoc: positional marginal powers (their count is k); writes results/
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70
Rscript scripts/gridSearchGraph.R 0.90 0.80 0.70 metrics_file=my_metrics.R metrics=er,h1h2
```

### Arguments

`key=value` arguments override config fields: `scenario`, `alpha`, `corr`,
`sim_n`, `w_step`, `g_step`, `w_fixed`, `seed`, `top_n`, `validate_n`,
`validate_seed`, `out_dir`, `stem_prefix`, `allow_large_k`, `max_candidates`,
`save_results`, `max_workers`, `metrics`, `metrics_file`, `shard`,
`merge_shards` and `smoke`. Unknown keys and unparsable values are errors.

- **With `scenario=<id>`**, positional arguments are not allowed. Other
  `key=value` arguments override the scenario file. The scenario page lists them
  as overrides, except `shard`, `merge_shards`, `max_workers` and
  `save_results`. Results with overrides must not be committed.
- **Without a scenario**, the defaults come from the `cfg <- bench_config(...)`
  block of the script.
- **`corr=0.3`** sets an equicorrelation.
- **`w_fixed=0.5,0.3,0.2`** fixes all weights, so only `G` is searched;
  `w_fixed=0.5,NA,NA` fixes some of them. `G_fixed` can only be set in a
  scenario file or in the `cfg` block.
- **`metrics=er,h1h2`** selects and orders the metrics. The first one orders the
  result tables.
- **`metrics_file=<path.R>`** must define a named list `metrics`. It is merged
  into the defaults, and a metric with the same name replaces the default:

  ```r
  # my_metrics.R
  metrics <- list(
    h1h2 = function(R) mean(R[, "H1"] & R[, "H2"]),      # P(reject H1 and H2)
    wer  = function(R) sum(R %*% c(2, 1, 1)) / nrow(R)   # weighted E[R], k = 3
  )
  ```

- **`shard=i/N`** and **`merge_shards=N`** run one shard or the merge of a job
  array. The cluster scripts set them; see [cluster/README.md](../cluster/README.md).
- **`stem_prefix`** keeps ad-hoc runs with different metric sets apart.

A scenario with `grid = FALSE` is not searched: the run (or `smoke=TRUE`) only
runs the checks, and the full run writes `reference/<id>/<id>.rds` with the
settings and evaluation simulations that optimizer solutions are scored on.
The search options (`sim_n`, `w_step`, `g_step`, `seed`, `top_n`,
`allow_large_k`, `max_candidates`, `shard`, `merge_shards`) are errors there.
See [Without grid search](../scenarios/README.md#without-grid-search).

See [scenarios/README.md](../scenarios/README.md) for correlation, constraints
and metrics.

### Smoke test

`smoke=TRUE` runs the start-up checks and then times a random sample of the real
grid: 10 transition matrices × up to 200 weight vectors, at the run's `sim_n`,
metrics and constraints. It prints:

- the grid size;
- the search CPU time and the validation time;
- the memory per worker and of the main process;
- the wall time and memory of the default cluster jobs.

The full grid is counted, never built, so the smoke test is safe for any grid
size. The [cluster guide](../cluster/README.md#1-estimate-the-run-first)
explains how to use the numbers.

### How a run works

1. `sim_n × k` p-values are simulated **once** per `k` (by graphicalMCP, with
   `seed`), so every candidate sees the same random numbers.
2. For each `G`, the intersection weights are linear in `w`. They are built once
   from the `k` unit-weight graphs and reused for every `w`.
3. Each candidate's rejection matrix `R` comes from a vectorized form of
   graphicalMCP's Bonferroni shortcut, and every metric is evaluated on that `R`.
4. Workers keep only the union of the per-metric top `top_n`, so memory stays
   small.
5. The kept graphs are re-evaluated on `validate_n` fresh simulations
   (`validate_seed`, default `seed + 1`). The search values of the winners are
   optimistic, because the winners were selected on the same p-values; the
   re-evaluated values are unbiased. Standard errors come from 20 batch means,
   so they work for any metric that averages over simulations. The ranking still
   uses the search values. `validate_n=0` skips this step.

The results are identical to calling `graph_calculate_power()` for each
candidate, but much faster.

### Verification

Every run starts with two cross-checks and stops if either fails:

```text
[verify k=3] engine matches graphicalMCP on 5 random graphs
[verify k=3] G=0 er: analytic=... simulated=... diff=...
```

1. The rejection engine runs on random graphs, including zero weights and
   transitions. It must reproduce the rejection matrix of
   `graph_calculate_power()` exactly.
2. With `G = 0` no alpha is propagated, so the procedure reduces to a single-step
   weighted-Bonferroni test with closed-form E[R], DP and CP (`R/analytic.R`). On
   the run's own p-values, the difference must be within `2 * sqrt(k / sim_n)`.
   Only the default `er`, `dp` and `cp` metrics are checked. With correlation,
   only `er` is checked, because the closed-form DP and CP assume independence.

### Output

A scenario run writes to `reference/<id>/` with stem `<id>`. An ad-hoc run
writes to `out_dir` (default `results/`, not committed) with stem
`gridSearch_k<k>_mp<..>[_rho<xx>|_corr][_fixedw][_fixedg]`, so that runs with
different settings do not overwrite each other. For job arrays, see
[cluster/README.md](../cluster/README.md#output).

- **`<stem>_best.csv`** is the key result. It has one row per metric, with the
  graph that is optimal for it: `metric`, `w1..wk`, every metric's search value,
  `<metric>_val`, `<metric>_se` and `G`.
- **`<stem>_top.csv`** is the `top` table, flattened.
- **`<stem>.rds`** is the full result:
  - `top`: the table of kept graphs;
  - `k`, `metrics` and `n_candidates`;
  - `settings`: alpha, mp, corr, constraints, grid and seed;
  - `validation`: sim_n, seed and batches;
  - `meta`: scenario, overrides, run date, git commit, R and graphicalMCP
    versions, and metric definitions.

With `grid = FALSE` only `<id>.rds` is written. It has no `top`, and
`settings$grid` is `FALSE`. Its `validation` also holds `p_colsums`, the column
sums of the evaluation p-values, which `bench_save_solution()` uses to check
that it still reproduces the same simulations.

`top` is the union of the top `top_n` graphs of every metric, with one row per
graph and these columns:

- `w1..wk`;
- for each metric: the search value, the re-evaluated value `<metric>_val` and
  its standard error `<metric>_se`;
- `g_id`;
- `rank_<metric>`, which is `NA` outside that metric's top `top_n`;
- `G`.

Rows are sorted by the first metric, and ties are broken by the other metrics.
In the CSV files, `G` is a semicolon-delimited string in column-major order:
`matrix(as.numeric(strsplit(G, ";")[[1]]), k)`.

## renderDocs.R

```sh
Rscript scripts/renderDocs.R            # all scenarios
Rscript scripts/renderDocs.R my_id      # one page + the index
```

`renderDocs.R` rebuilds `docs/scenarios/<id>.md` and `docs/README.md` from
`reference/<id>/<id>.rds`. Scenario runs do this automatically. Run it by hand
after changing `R/report.R`, or to resolve a merge conflict in `docs/README.md`.
