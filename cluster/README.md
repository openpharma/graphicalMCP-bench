# Running on a cluster

Each scheduler has two submission scripts. Both run `scripts/gridSearchGraph.R`
with the same arguments and produce the same result:

| Script | What it submits |
|--------|-----------------|
| `slurm/submit.sh`, `lsf/submit.sh` | One job that runs the whole search |
| `slurm/submit_array.sh`, `lsf/submit_array.sh` | A job array that splits the search into shards, plus a merge job |

Start with a single job. Use a job array when a single job would not fit your
queue's time limit, or would wait long for a large allocation.

## 1. Estimate the run first

Run time and memory depend on the grid size (k, `w_step`, `g_step` and
constraints), `sim_n`, the number of metrics and `validate_n`. Small grids take
seconds; large ones can take many core-hours. The smoke test times a random
sample of the real grid and estimates the full run without writing anything:

```sh
Rscript scripts/gridSearchGraph.R scenario=example_k3 smoke=TRUE
```

Example output for `example_k3` on a laptop:

```text
grid        21 weight vectors x 121 transition matrices = 2,541 candidates
search      2.7 s CPU time (0.000737 core-hours)
validation  up to 200 graphs x 100,000 simulations: 3.3 s (serial)
startup     0.1 s per job (checks + p-values; worker start-up not included)
memory      155 MB per worker, 172 MB main process (includes process overhead)
single job  16 cores: wall time 3.6 s, memory 2.59 GB
job array   16 shards x 4 cores: wall time 0.1 s, memory 793 MB per shard
            merge job: wall time 3.3 s, memory 172 MB
```

- **`single job`** uses the `submit.sh` default (16 cores) and **`job array`**
  uses the `submit_array.sh` defaults (16 shards × 4 cores).
- **Other layouts:** a shard takes about `startup + search / (N_SHARDS × CORES)`.
  A single job takes about `startup + search / CORES + validation`. The merge
  takes about `validation`.
- **Machine speed:** timings depend on the CPU, so run the smoke test where the
  job will run (for example as a short single job, see the
  [README](../README.md#smoke-test)). Then add a margin to the
  estimates.
- **Grid size:** grids above `max_candidates` (default 10^8) also need
  `allow_large_k=TRUE`; the smoke test says so.

## 2. Single job

```sh
bash cluster/slurm/submit.sh scenario=example_k3
bash cluster/lsf/submit.sh scenario=example_k3
```

The job starts `CORES` R workers on one node, or on `NODES` nodes. It searches
the whole grid, re-evaluates the kept graphs on independent simulations
(`validate_n`) and writes the result.

| Variable | Default | Meaning |
|----------|---------|---------|
| `CORES` | 16 | Workers per node (keep at most the CPUs per node) |
| `NODES` | empty (one node) | Number of nodes; the workers span all of them |
| `WALLTIME` | `08:00:00` (Slurm) / `8:00` (LSF) | Time limit |
| `PARTITION` (Slurm) / `QUEUE` (LSF) | cluster default | Where to submit; list them with `sinfo -s` / `bqueues` |

Memory is 1000 MB per core. On Slurm the script sets `--mem-per-cpu=1000`;
override it with an environment variable such as `SBATCH_MEM_PER_CPU=2000`. On
LSF it sets `rusage[mem=1000]`; edit the `#BSUB` line to change it.

The R script detects the allocation with `parallelly::availableWorkers()` and
starts a PSOCK worker on every allocated core. For multi-node runs, graphicalMCP
and parallelly must be in an R library that every node can see. Remote workers
are started as follows:

- **Slurm:** `cluster/slurm/srun-rsh.sh` starts each worker as an
  `srun --overlap` job step, so no ssh is needed. This needs Slurm ≥ 20.11.
- **LSF:** workers start over ssh by default. If ssh between nodes is blocked,
  add `export R_PARALLELLY_MAKENODEPSOCK_RSHCMD=blaunch` to the job body.

See the notes at the end of each `submit.sh` for the reverse-tunnel caveat.

## 3. Job array

```sh
N_SHARDS=5 CORES=2 bash cluster/slurm/submit_array.sh scenario=example_k3
N_SHARDS=5 CORES=2 bash cluster/lsf/submit_array.sh scenario=example_k3
```

### How it works

1. **Array tasks.** Task `i` runs `gridSearchGraph.R ... shard=i/N_SHARDS`. It
   searches only its share of the transition matrices on `CORES` cores of one
   node and saves its candidates to a shard file. Tasks do not communicate, so
   they can run on any nodes in any order.
2. **Merge job.** The merge job depends on the whole array (`afterok` on Slurm,
   `done()` on LSF). It runs `gridSearchGraph.R ... merge_shards=N_SHARDS`, which:
   - checks that all `N_SHARDS` shard files exist and that they were run with
     the same settings and metrics;
   - reads the shards one at a time and keeps the best `top_n` graphs per
     metric;
   - re-evaluates the kept graphs on `validate_n` independent simulations;
   - writes the final result, exactly what a single job would produce.
3. **Failures.** If a task fails (error, time limit or memory limit), the
   scheduler cancels the merge automatically. Slurm uses
   `--kill-on-invalid-dep=yes`; LSF uses `-ti`.

Validation runs only in the merge job, so the shards contain only the search.

### Options

| Variable | Default | Meaning |
|----------|---------|---------|
| `N_SHARDS` | 16 | Number of array tasks; re-runs must use the same value |
| `CORES` | 4 | Cores per task (each task uses one node) |
| `SHARD_MEM` | `CORES × 1000` MB | Memory per task, all its cores together |
| `MERGE_MEM` | 2000 MB | Memory of the merge job (including validation) |
| `WALLTIME` | `08:00:00` (Slurm) / `8:00` (LSF) | Time limit per task |
| `MERGE_WALLTIME` | `08:00:00` (Slurm) / `8:00` (LSF) | Time limit of the merge job |
| `PARTITION` (Slurm) / `QUEUE` (LSF) | cluster default | Where to submit |
| `MAX_RUNNING` | no limit | Maximum number of tasks running at the same time |
| `ARRAY` | `1-N_SHARDS` | Tasks to submit, e.g. `3,7` to re-run two shards |

Set `WALLTIME`, `SHARD_MEM` and `MERGE_MEM` from the smoke test, plus a margin:

```sh
N_SHARDS=32 CORES=4 WALLTIME=01:00:00 SHARD_MEM=4000 MERGE_MEM=3000 \
  bash cluster/slurm/submit_array.sh scenario=my_id
```

## Arguments

All arguments after the script name are passed to `gridSearchGraph.R` for every
job; see [scripts/README.md](../scripts/README.md#arguments).

- **`scenario=<id>`:** the scenario file defines the run, and the built-in `MP`
  and `ARGS` at the top of each script are ignored.
- **Without a scenario:** the scripts run an ad-hoc search with
  `MP="0.90 0.80 0.70 0.60"` and
  `ARGS="w_step=0.1 g_step=0.25 sim_n=10000 top_n=50 allow_large_k=TRUE out_dir=results"`.
  Positional numbers replace `MP`, and `key=value` arguments override `ARGS`;
  the last value wins.

## Output

| Run | Files |
|-----|-------|
| Scenario, single job | `reference/<id>/`; `docs/scenarios/<id>.md` and `docs/README.md` are re-rendered |
| Scenario, job array | Shards: `results/<id>/shards/<id>_shard<i>of<N>.rds`; the merge writes the same files as a single job |
| Ad hoc, single job | `results/<stem>.rds`, `_best.csv`, `_top.csv` |
| Ad hoc, job array | Shards: `results/<stem>/shards/`; merged result: `results/<stem>/` |

The file contents and the `<stem>` naming are described in
[scripts/README.md](../scripts/README.md#output).

Logs are written to `logs/`. Each job is named `bench_<id>`, or `bench_k<k>`
for an ad-hoc run, and the merge job has a `_merge` suffix. Shard files can be
deleted after a successful merge.

## Monitoring and failures

```sh
# Slurm
squeue -u $USER
sacct -j <array id> --format=JobID,State,ExitCode,Elapsed,MaxRSS

# LSF
bjobs -a <array id>
bhist -l "<array id>[3]"
```

**A task failed.** The merge has already been cancelled. Re-run only the failed
tasks, using the same `N_SHARDS` and arguments. Raise `WALLTIME` or `SHARD_MEM`
if the task hit a limit:

```sh
ARRAY=3,7 N_SHARDS=16 SHARD_MEM=8000 bash cluster/slurm/submit_array.sh scenario=my_id
```

This also submits a new merge job, which reuses the shard files of the tasks
that succeeded.

**The merge failed.** Check `logs/<name>_merge.*.err`:

- **Time or memory limit.** Re-submit only the merge, with more resources and
  the same arguments plus `merge_shards=N_SHARDS`:

  ```sh
  sbatch --mem=4000 --time=02:00:00 \
    --wrap="Rscript scripts/gridSearchGraph.R scenario=my_id merge_shards=16"
  ```

- **`Missing ... shard(s) ...: 3, 7`.** Re-run those tasks as shown above.
- **`Shards were run with different settings or metrics`.** The shard folder
  mixes files from runs with different settings. Delete the folder (e.g.
  `results/<id>/shards/`) and submit the array again.
