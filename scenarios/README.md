# Scenarios

A scenario is one benchmark case. Each one is a file `scenarios/<id>.R` that
defines a list called `scenario`. The `<id>` uses lowercase letters, digits and
`_`. It names the results in `reference/<id>/` and the page
`docs/scenarios/<id>.md`.

Start from [_template.R](_template.R), which documents every field with its
default. [example_k3.R](example_k3.R) is a worked example. To add a scenario to
the repository, follow [CONTRIBUTING.md](../CONTRIBUTING.md).

## Fields

| Field | Required | Meaning (default) |
|-------|----------|-------------------|
| `title`, `author` | yes | Shown on the scenario page and in the index |
| `date`, `description` | no | Shown on the scenario page |
| `alpha` | yes | One-sided family-wise type I error |
| `mp` | yes | Marginal power of H1..Hk; its length is k |
| `corr` | no | Correlation of the test statistics (independence) |
| `metrics` | no | Metrics to maximize (`er`, `dp`, `cp`) |
| `w_fixed`, `G_fixed` | no | Constraints on weights and transitions (none) |
| `grid` | no | `FALSE` turns the grid search off (`TRUE`; see [Without grid search](#without-grid-search)) |
| `w_step`, `g_step` | no | Grid steps for the weights (0.05) and transitions (0.1) |
| `sim_n`, `seed` | no | Simulations shared by all candidates (1e4) and their seed (2024) |
| `top_n` | no | Graphs kept per metric (50; at most 50 for committed results) |
| `validate_n`, `validate_seed` | no | Fresh simulations to re-evaluate the kept graphs and score optimizer solutions (1e5) and their seed (`seed + 1`) |
| `allow_large_k`, `max_candidates` | no | Safety gate for large grids (`FALSE`, 1e8; see [Feasibility](#feasibility)) |

Any other field is an error. Delete the fields you leave at their defaults.

## Correlation

`corr` is `NULL` (independence), one number (equicorrelation) or a `k × k`
correlation matrix. A matrix must be symmetric, have a unit diagonal and be
positive semi-definite. The tests stay weighted Bonferroni, so the correlation
only changes the simulated p-values. E[R] does not depend on the correlation,
but DP, CP and joint metrics do.

## Constraints

`w_fixed` (length `k`) and `G_fixed` (`k × k`, rows = from) fix single entries.
`NA` means free and a number means fixed; 0 removes a weight or an edge. The free
entries share what the fixed ones leave, on the same grid, so every row with a
free entry still sums to 1. Fixed values must therefore leave a multiple of the
step, or the run stops. A row whose entries are all fixed may sum to less
than 1. The diagonal of `G_fixed` must be `NA` or 0.

```r
w_fixed = c(NA, NA, 0)                         # H3 starts with no alpha
G_fixed = matrix(c(NA, NA, NA,
                   NA, NA,  0,                 # no edge H2 -> H3
                   NA, NA, NA), 3, byrow = TRUE)
```

Constraints are applied while the grid is built. They shrink the candidate
space, which makes larger `k` more feasible.

## Metrics

A metric is any `function(R)` that returns one number to **maximize**. `R` is the
`sim_n × k` logical rejection matrix, with columns `H1..Hk` and one row per
simulation. The defaults (`BENCH_METRICS`) are:

| Key | Metric | Definition |
|-----|--------|------------|
| `er` | expected rejections | `sum(R) / nrow(R)` |
| `dp` | disjunctive power | `mean(rowSums(R) > 0)` |
| `cp` | conjunctive power | `mean(rowSums(R) == ncol(R))` |

Add your own next to the defaults:

```r
metrics = c(BENCH_METRICS, list(
  h1h2 = function(R) mean(R[, "H1"] & R[, "H2"])   # P(reject H1 and H2)
))
```

- The first metric orders the result tables.
- To minimize a quantity, return its negative.
- DP depends on `w` only, so DP ties across `G` are broken by the other metrics.
- Metric names must be valid R names and must not be `G`, `g_id`, `w_id`,
  `metric`, `time_s`, `w<i>`, `rank_*`, `*_val` or `*_se`.

## Feasibility

The candidate space is (number of weight vectors) × (number of transition
matrices). With a fine grid (`w_step = 0.01`, `g_step = 0.05`):

| k | Weight vectors | Transition matrices | Candidates |
|---|----------------|---------------------|------------|
| 3 | 5,151 | 9,261 | ~4.8e7 |
| 4 | 1.8e5 | 2.9e9 | ~5e14 |
| 5 | 4.6e6 | 1.7e16 | ~8e22 |

For `k > 3` you therefore need a much coarser grid **and**
`allow_large_k=TRUE`. Runs above `max_candidates` stop otherwise. Fixed entries
(`w_fixed`, `G_fixed`) shrink both factors. The smoke test prints the grid size
and the estimated cost before you commit to a run. If no grid is feasible, turn
it off and compare the optimizers only (see below).

## Without grid search

`grid = FALSE` skips the grid search, so the scenario has no reference graphs.
The optimizers are then compared with each other only:

```r
scenario <- list(
  title = "Five endpoints", author = "Your Name",
  alpha = 0.025, mp = c(0.90, 0.85, 0.80, 0.70, 0.60),
  grid  = FALSE
)
```

- The run (`Rscript scripts/gridSearchGraph.R scenario=<id>`) takes seconds and
  needs no cluster. It runs the checks and writes `reference/<id>/<id>.rds` with
  the settings and the evaluation simulations (`validate_n`, `validate_seed`).
  It also renders the scenario page. Job arrays (`shard`, `merge_shards`) are
  errors.
- Every optimizer solution is scored on these simulations, so solutions compare
  directly with each other. Their `ref_val`, `diff_val` and `diff_se` are `NA`
  (see [optimizer/README.md](../optimizer/README.md#solutions)).
- `w_step`, `g_step`, `sim_n`, `seed`, `top_n`, `allow_large_k` and
  `max_candidates` only configure the search, so setting them is an error, in
  the file or on the command line. `validate_n` must be greater than 0. The
  evaluation seed defaults to 2025; set `validate_seed` to change it.
- To add the grid search later, remove `grid = FALSE`, re-run the scenario and
  every solution in `solutions/<id>/`.

## Running a scenario

```sh
Rscript scripts/gridSearchGraph.R scenario=<id> smoke=TRUE   # checks + estimate, nothing written
Rscript scripts/gridSearchGraph.R scenario=<id>              # full run
```

A full run writes `reference/<id>/<id>.rds`, `<id>_best.csv` and `<id>_top.csv`,
renders `docs/scenarios/<id>.md` and updates `docs/README.md`. With
`grid = FALSE` it writes only `<id>.rds`.

- [scripts/README.md](../scripts/README.md): command-line overrides and the
  contents of the output files.
- [cluster/README.md](../cluster/README.md): running on Slurm or LSF.

Everyone with access to the repository can read the scenarios, so leave out
confidential trial details.
