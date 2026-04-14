#!/usr/bin/env bash
# Orchestrator invoked by cron. Single entry point that runs:
#   fetch → build → upload → prune
# under a flock (done by cron) so overlapping runs can't stomp each other.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

log "=== pipeline run start ==="
start=$(date +%s)

# Fetch MRMS. File path on stdout, stamp on fd 3. Use a named pipe to
# capture both without a tempfile.
stamp=""
input_path=""
{ input_path=$("$HERE/fetch-mrms.sh" 3> >(read -r s && stamp=$s; echo "$s" > "$WORK_DIR/.stamp")); } || {
  log "fetch-mrms failed with $?; skipping this cycle"
  exit 0
}
# fd-3 capture is finicky under set -e / subshells in bash; fall back to the
# file we also wrote.
[[ -z "$stamp" && -s "$WORK_DIR/.stamp" ]] && stamp="$(cat "$WORK_DIR/.stamp")"
[[ -n "$stamp" ]] || { log "no timestamp recovered"; exit 1; }
log "input: $input_path"
log "stamp: $stamp"

tiles_dir="$("$HERE/build-tiles.sh" "$input_path")"
log "tiles: $tiles_dir"

"$HERE/upload-tiles.sh" "$tiles_dir" "$stamp"
"$HERE/prune.sh"

log "=== pipeline run complete in $(( $(date +%s) - start ))s ==="
