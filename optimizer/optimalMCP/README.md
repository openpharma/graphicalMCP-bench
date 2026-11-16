# optimalMCP

Weight optimization from the `optimalMCP` package. **Status: placeholder.** It is not yet
compared against the grid-search ground truth.

## Method

`optim_w_er(alpha, mp, ...)` finds the initial weights `w` that maximize the expected
number of rejections of a **single-step** weighted-Bonferroni test:

$$E[R] = \sum_i \Phi\big(\mu_i - \Phi^{-1}(1 - w_i \alpha)\big), \qquad \mu_i = \Phi^{-1}(1 - \alpha) - \Phi^{-1}(1 - mp_i),$$

subject to $\sum_i w_i = 1$, using `nloptr` (SLSQP) with the analytic gradient.

- `constraint.w`: per-hypothesis constraints; `NA` = optimized, a number = fixed,
  `0` = hypothesis dropped. `lb` / `ub` bound the free weights.
- `rho` is accepted but ignored: E[R] is a sum of marginals, so it does not depend on the
  correlation under Bonferroni.
- Returns `w`, `alphas = w * alpha`, `power` (E[R] at the optimum) and the raw `nloptr`
  result in `detail`.

**Not covered yet:** the transition matrix `G`. The method optimizes the single-step test
only (no alpha propagation).

## Files

| File | Origin |
| ---- | ------ |
| `utils.R` | optimalMCP `R/utils.R`: `sigma_matrix`, `solve_eta`, `inverse_derivative` |
| `constraintBonf.R` | optimalMCP `R/constraintBonf.R`: Bonferroni equality constraint |
| `expectedRejections.R` | optimalMCP `src/expectedRejections.R`: `expected_rejections`, loss, gradient, `optim_w_er` |
| `compareExpectedRejections.R` | check of `expected_rejections()` against a graphicalMCP simulation |

The three source files are vendored copies; keep them in sync with upstream. Once
`optim_w_er` is exported by the installed `optimalMCP` package, they can be replaced
by `optimalMCP::` calls.

## Requirements

`nloptr` for `optim_w_er`; `graphicalMCP` for the check script.

## Check

```sh
Rscript optimizer/optimalMCP/compareExpectedRejections.R
```

It compares the analytic E[R] (overall and per hypothesis) with a graphicalMCP
simulation of the `G = 0` graph, for equal weights, the `optim_w_er` weights, and a
5-hypothesis case.

## Usage

```r
source("R/rootPath.R")
gogt_source("optimizer", "optimalMCP", "utils.R")
gogt_source("optimizer", "optimalMCP", "constraintBonf.R")
gogt_source("optimizer", "optimalMCP", "expectedRejections.R")

opt <- optim_w_er(alpha = 0.025, mp = c(0.9, 0.8, 0.7), constraint.w = c(NA, NA, 0))
opt$w
```
