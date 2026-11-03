# gogt — graph optimization ground truth

Brute-force grid search over multiplicity graphs, used as **ground truth** for the
analytic/numeric optimizers in the `optimalMCP` package.

A multiplicity graph is a pair `(w, G)`: initial hypothesis weights `w` (summing to 1)
and a row-stochastic transition matrix `G` (zero diagonal, rows summing to 1). This
repo enumerates both on a regular grid, evaluates the objective of the full
sequentially-rejective graphical procedure for every candidate by Monte-Carlo
simulation (`graphicalMCP::graph_calculate_power`), and reports the best graphs.

Objectives (all under **independence**, `sim_corr = diag(k)`, `test_types = "bonferroni"`):

| key  | objective            | `$power` field       |
| ---- | -------------------- | -------------------- |
| `er` | expected rejections  | `rejection_expected` |
| `dp` | disjunctive power    | `power_at_least_1`   |
| `cp` | conjunctive power    | `power_all`          |

## Layout

```
R/
  rootPath.R           gogt_root() / gogt_source(): cwd-independent path resolution
  utils.R              solve_eta, sigma_matrix, inverse_derivative
  constraintBonf.R     Bonferroni equality constraint for nloptr
  expectedRejections.R analytic E[R] + weight optimizer (optim_w_er)
  analyticDP.R         analytic DP/CP under independence
  gridCore.R           simplex/transition grids, eval_graph, grid_search_k, reporting
  gridRunner.R         config, CLI parsing, G=0 verification, main loop
scripts/
  gridSearchGraphER.R  entry point, objective = er
  gridSearchGraphDP.R  entry point, objective = dp
  compareExpectedRejections.R  analytic E[R] vs graphicalMCP simulation
bsub/                  LSF submission scripts
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
Rscript scripts/gridSearchGraphER.R 0.9 0.8 0.7 \
  w_step=0.25 g_step=0.5 sim_n=2000 top_n=5 save_results=FALSE

# Default k=3 run, disjunctive power, results written to results/
Rscript scripts/gridSearchGraphDP.R 0.90 0.80 0.70
```

Positional numeric arguments are the marginal powers; their count defines `k`.
`key=value` arguments override config fields: `sim_n`, `w_step`, `g_step`, `w_fixed`,
`seed`, `top_n`, `out_dir`, `allow_large_k`, `max_candidates`, `save_full`,
`save_results`, `max_workers`, `objective`.

Pass `w_fixed=0.5,0.3,0.2` to skip the weight simplex and search only `G`; those runs
are tagged `_fixedw` so they do not overwrite full-grid results.

Defaults live in the `cfg <- gogt_config(...)` block of each script.

### Cluster

```sh
bsub < bsub/gridSearchGraphER.bsub
```

Workers are auto-detected via `parallelly::availableWorkers()`, which reads the LSF
allocation (`LSB_MCPU_HOSTS` / `LSB_HOSTS`) and spans every allocated core on every
node through a PSOCK cluster. See the comments in the `.bsub` files for the
`blaunch` and reverse-tunnel caveats.

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

- `gridSearch{ER,DP}_k<k>_mp<..>[_fixedw].rds` — the full `grid_search_k()` result
  (top-N rows, each carrying its own `G` matrix).
- `gridSearch{ER,DP}_k<k>_mp<..>[_fixedw]_top.csv` — flattened top-N table, `G`
  serialized as a semicolon-delimited string.

The tag encodes the marginal powers, e.g. `mp90_80_70`, so parallel runs do not clash.

## Verification

Every run starts with a zero-transition cross-check. With `G = 0` no alpha is
propagated, so the graphical procedure reduces to a single-step weighted-Bonferroni
test whose objective has a closed form. The printed line

```
[verify k=3] G=0 E[R]: analytic=... simulated=... diff=...
```

should show a difference within Monte-Carlo error (~`2/sqrt(sim_n)`).

`scripts/compareExpectedRejections.R` runs the same comparison across several
scenarios, including per-hypothesis rejection probabilities.
