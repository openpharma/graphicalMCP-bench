# Sourced by the submit scripts to split their arguments: positional numbers
# replace MP, key=value pairs become EXTRA (appended after ARGS, so they win).
MP_CLI=""
EXTRA=""
for a in "$@"; do
  case "$a" in
    *=*)          EXTRA="${EXTRA} ${a}" ;;
    ""|*[!0-9.]*) echo "Expected a marginal power or key=value, got '${a}'." >&2; exit 1 ;;
    *)            MP_CLI="${MP_CLI} ${a}" ;;
  esac
done
if [ -n "$MP_CLI" ]; then MP="${MP_CLI# }"; fi
