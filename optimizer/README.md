# Optimizers

The optimization methods compared against the grid search live in
`optimizer/<method>/`, one folder per method:

| Method | Status | Optimizes |
|--------|--------|-----------|
| [optimalMCP](optimalMCP/README.md) | placeholder | Weights `w` maximizing E[R] of the single-step test (no `G` yet) |

Each folder is self-contained, with its own code, its own dependencies and a
`README.md` that describes the method, its origin and its limits. Optimizers
never change `R/`, and the grid search never loads anything from `optimizer/`,
so the cluster only needs the grid's packages. To add a method or a solution,
see [CONTRIBUTING.md](../CONTRIBUTING.md#contributing-an-optimizer-solution).

## Solutions

For a scenario, an optimizer proposes one graph per metric, as a graphicalMCP
graph from `graph_create()`. `bench_save_solution()` (`R/solutions.R`) scores
the graphs and saves them to `solutions/<id>/`, next to `reference/<id>/`:

```r
source("R/rootPath.R")
bench_source("R", "gridCore.R")
bench_source("R", "gridRunner.R")
bench_source("R", "solutions.R")

sc <- bench_load_scenario(bench_config(), "example_k3")   # sc$alpha, sc$mp_list[[1]], sc$corr, ...
# ... run the optimizer on the scenario, one graph per metric it optimizes ...
bench_save_solution("example_k3", "optimalMCP",
  graphs = list(er = graphicalMCP::graph_create(w_opt, matrix(0, 3, 3))),
  time_s = c(er = 0.2),
  info   = list(version = "vendored optim_w_er"))
```

The hypotheses must be named `H1..Hk` in the scenario's order, which is
`graph_create()`'s default for unnamed weights.

The grid's rejection engine re-evaluates the graphs on **the same p-values as the
reference's re-evaluation** (its `validate_n` and `validate_seed`). Their values
therefore compare directly with the reference `_val` columns. The difference to
the reference graph of the same metric is paired (same simulations), so its
standard error shrinks as the two graphs get closer.

`bench_save_solution()` stops if:

- `reference/<id>/` is missing, was run with overrides or with `validate_n=0`, or
  no longer matches `scenarios/<id>.R` (alpha, `mp`, `corr`, constraints or
  metric definitions);
- a graph is invalid for graphicalMCP, or breaks the scenario's `w_fixed` /
  `G_fixed`;
- the reference values cannot be reproduced (e.g. graphicalMCP changed its
  simulation).

It writes two files:

- **`solutions/<id>/<method>.rds`:** the scored table, the input graphs,
  settings, `info` and provenance.
- **`<method>_best.csv`:** one row per proposed graph, with these columns:
  - `metric` and `w1..wk`;
  - `<m>_val` and `<m>_se` for every metric `m`;
  - `ref_val`, the reference graph's value on that metric;
  - `diff_val` and `diff_se`, the solution minus the reference (paired);
  - `time_s`;
  - `G`, column-major at full precision.

Pass `out_dir = "results/..."` for trial runs that should not be committed, or
`save = FALSE` to score only. The scenario pages in `docs/` do not show
solutions yet.
