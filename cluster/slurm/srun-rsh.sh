#!/bin/bash
# ssh-compatible launcher for parallelly PSOCK workers inside a Slurm job:
#   srun-rsh.sh <host> <command>
# Runs <command> on <host> as an overlapping job step, so it needs no ssh and
# inherits the job environment (loaded modules, R library paths).
host="$1"
shift
exec srun --overlap --nodes=1 --ntasks=1 --ntasks-per-node=1 --cpus-per-task=1 \
  --nodelist="$host" bash -c "$*"
