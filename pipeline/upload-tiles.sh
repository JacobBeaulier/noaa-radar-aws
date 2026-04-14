#!/usr/bin/env bash
# Upload a freshly generated tile tree to S3 under a timestamp prefix.
# Key layout: s3://$BUCKET/{YYYYMMDDHHMM}/{z}/{x}/{y}.png
# matches the contract the noaa-aws provider in raceday-itinerary expects.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

tiles_dir="${1:?tiles directory required}"
stamp="${2:?YYYYMMDDHHMM required}"
[[ -d "$tiles_dir" ]] || { log "tiles dir missing: $tiles_dir"; exit 1; }
[[ ${#stamp} -eq 12 ]] || { log "bad timestamp: $stamp"; exit 1; }

log "uploading tiles → s3://${BUCKET}/${stamp}/"
# --exclude filters the HTML/JS leaflet preview gdal2tiles sometimes emits.
# --cache-control keeps tiles in browser cache for an hour (they're
# immutable once written).
aws s3 sync "$tiles_dir" "s3://${BUCKET}/${stamp}/" \
  --region "$REGION" \
  --exclude "*" --include "*.png" \
  --cache-control "public, max-age=3600" \
  --content-type "image/png" \
  --only-show-errors

# Publish a latest.json manifest so the client (or debugging humans) can
# discover the newest available timestamp without a LIST call.
latest_json="${WORK_DIR}/latest.json"
cat > "$latest_json" <<JSON
{
  "latest": "${stamp}",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "product": "${MRMS_PRODUCT}"
}
JSON
aws s3 cp "$latest_json" "s3://${BUCKET}/latest.json" \
  --region "$REGION" \
  --cache-control "no-cache, max-age=0" \
  --content-type "application/json" \
  --only-show-errors
log "uploaded manifest → s3://${BUCKET}/latest.json"
