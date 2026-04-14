#!/usr/bin/env bash
# Delete tile prefixes older than $RETENTION_MINUTES. The S3 lifecycle rule
# catches stragglers at 1-day granularity; this runs every cycle so the
# actual tile footprint stays bounded.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

cutoff_epoch=$(( $(date -u +%s) - RETENTION_MINUTES * 60 ))
cutoff_stamp="$(date -u -d "@$cutoff_epoch" +%Y%m%d%H%M)"
log "pruning prefixes older than $cutoff_stamp"

# Only top-level "folders" (CommonPrefixes) should be timestamped dirs.
# latest.json and anything else gets ignored.
prefixes="$(aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter '/' \
  --query 'CommonPrefixes[].Prefix' --output text --region "$REGION" 2>/dev/null || echo '')"

[[ -z "$prefixes" || "$prefixes" == "None" ]] && { log "no prefixes to consider"; exit 0; }

deleted=0
for p in $prefixes; do
  # Strip trailing slash
  stamp="${p%/}"
  # Only consider 12-digit numeric prefixes — leaves other folders alone.
  [[ "$stamp" =~ ^[0-9]{12}$ ]] || continue
  if [[ "$stamp" < "$cutoff_stamp" ]]; then
    aws s3 rm "s3://${BUCKET}/${p}" --recursive --region "$REGION" --only-show-errors >/dev/null
    deleted=$((deleted + 1))
  fi
done
log "pruned $deleted expired timestamp prefixes"
