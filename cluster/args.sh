# Sourced by the submit scripts to split their arguments: positional numbers
# replace MP, key=value pairs become EXTRA (appended after ARGS, so they win).
# With scenario=<id> the scenario file defines the run, so MP and ARGS are
# dropped. Sets NAME, the job name: gogt_<id> or gogt_k<k>.
MP_CLI=""
EXTRA=""
SCENARIO=""
for a in "$@"; do
  case "$a" in
    scenario=*)   SCENARIO="${a#scenario=}"; EXTRA="${EXTRA} ${a}" ;;
    *=*)          EXTRA="${EXTRA} ${a}" ;;
    ""|*[!0-9.]*) echo "Expected a marginal power or key=value, got '${a}'." >&2; exit 1 ;;
    *)            MP_CLI="${MP_CLI} ${a}" ;;
  esac
done
if [ -n "$SCENARIO" ]; then
  if [ -n "$MP_CLI" ]; then
    echo "With scenario= the marginal powers come from the scenario file; drop '${MP_CLI# }'." >&2
    exit 1
  fi
  MP=""
  ARGS=""
  NAME="gogt_$(basename "${SCENARIO%.R}")"
else
  if [ -n "$MP_CLI" ]; then MP="${MP_CLI# }"; fi
  NAME="gogt_k$(wc -w <<< "$MP")"
fi
