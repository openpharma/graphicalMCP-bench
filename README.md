# graphicalMCP-bench

This repository benchmarks optimization methods for multiplicity graphs using
[`graphicalMCP`](https://cran.r-project.org/package=graphicalMCP). Scenarios define
the testing setup; a grid search produces reference results that can be compared
with optimizer solutions.

## Folder structure

```text
.
├── CONTRIBUTING.md
├── R/
├── cluster/
│   ├── lsf/
│   └── slurm/
├── docs/
│   ├── README.md
│   └── scenarios/
├── optimizer/
│   └── optimalMCP/
├── reference/
│   └── <scenario>/
├── scenarios/
│   ├── _template.R
│   └── <scenario>.R
├── scripts/
└── solutions/              # optimizer results, when present
```

## Project parts

- **`scenarios/`** — Scenario definitions and a template for new cases.
- **`R/`** — Core grid search, graphical procedure, analytic calculations,
  reporting, and optimizer-solution scoring.
- **`scripts/`** — Entry points for running a search and rendering result pages.
- **`optimizer/`** — Optimizer implementations and their method-specific
  documentation.
- **`reference/`** — Saved grid-search results for scenarios.
- **`cluster/`** — Submission scripts for LSF and Slurm clusters.
- **`docs/`** — Generated index and scenario result pages.
- **`solutions/`** — Saved optimizer proposals and their scored results, organized
  by scenario.
- **`CONTRIBUTING.md`** — Instructions for adding scenarios and optimizer
  solutions.

## Getting started

Install R and the `graphicalMCP` and `parallelly` packages. Then run the included
example scenario:

```sh
Rscript scripts/gridSearchGraph.R scenario=example_k3
```

The search saves its reference results under `reference/` and updates the
corresponding page in `docs/`. To see the current scenarios and their results,
start with the [scenario index](docs/README.md).

## Learn more

- [Contributing a scenario or optimizer solution](CONTRIBUTING.md)
- [Example scenario definition](scenarios/example_k3.R)
- [Optimizer method notes](optimizer/optimalMCP/README.md)
