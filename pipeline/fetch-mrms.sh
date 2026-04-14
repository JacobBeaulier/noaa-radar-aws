#!/usr/bin/env bash
# Fetch the most recent MRMS MergedReflectivityQComposite GRIB2 file from
# the NOAA public S3 bucket (noaa-mrms-pds). Prints the local uncompressed
# .grib2 path on stdout, and the wall-clock timestamp (YYYYMMDDHHMM,
# 5-min floored) on fd 3 if the caller opens one.
#
# Exits non-zero with no output if no file is available yet for the current
# window (typical for a cron run hitting before NOAA publishes a new file).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

target_epoch="$(floor_to_5min)"
today="$(date -u +%Y%m%d)"
yesterday="$(date -u -d 'yesterday' +%Y%m%d)"

# MRMS keys files by the original observation time in the filename; the day
# directory is UTC date. Near midnight we might need yesterday's directory,
# so try today first and fall back.
pick_latest() {
  local day="$1"
  aws s3 ls --no-sign-request \
    "s3://${MRMS_BUCKET}/${MRMS_PREFIX}/${day}/" 2>/dev/null \
    | awk '{print $4}' | grep '\.grib2\.gz$' | sort | tail -n 1
}

latest="$(pick_latest "$today" || true)"
day="$today"
if [[ -z "$latest" ]]; then
  latest="$(pick_latest "$yesterday" || true)"
  day="$yesterday"
fi
[[ -z "$latest" ]] && { log "no MRMS files found"; exit 10; }

remote_key="${MRMS_PREFIX}/${day}/${latest}"
local_gz="${WORK_DIR}/mrms.grib2.gz"
local_raw="${WORK_DIR}/mrms.grib2"

log "downloading s3://${MRMS_BUCKET}/${remote_key}"
aws s3 cp --no-sign-request "s3://${MRMS_BUCKET}/${remote_key}" "$local_gz" >/dev/null

gunzip -f "$local_gz"
[[ -s "$local_raw" ]] || { log "decompressed GRIB2 is empty"; exit 11; }

# Use the filename's embedded timestamp so downstream keys match the
# observation time exactly. Format: MRMS_{product}_{YYYYMMDD}-{HHMMSS}.grib2
raw_stamp="$(echo "$latest" | sed -n 's/.*_\([0-9]\{8\}\)-\([0-9]\{6\}\)\.grib2\.gz/\1\2/p')"
# Truncate HHMMSS → HHMM and snap to 5-min boundary.
obs_hhmm="${raw_stamp:8:4}"
obs_hhmm="${obs_hhmm:0:3}$(( ${obs_hhmm:3:1} / 5 * 5 ))"
# Pad to 2 digits if the snap rounded to a 10s multiple.
stamp="${raw_stamp:0:8}${obs_hhmm}"
[[ ${#stamp} -eq 12 ]] || stamp="$(stamp_from_epoch "$target_epoch")"

echo "$local_raw"
if { true >&3; } 2>/dev/null; then echo "$stamp" >&3; fi
