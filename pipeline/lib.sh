# Shared helpers for the MRMS → S3 pipeline. Sourced by every pipeline step.
# Not meant to be executed standalone.

# shellcheck disable=SC2034  # consumers source and read these

set -euo pipefail

if [[ -f /etc/noaa-radar.env ]]; then
  # shellcheck disable=SC1091
  source /etc/noaa-radar.env
fi

: "${BUCKET:?BUCKET must be set (normally via /etc/noaa-radar.env)}"
: "${REGION:=us-east-1}"
: "${TILE_ZOOM:=2-7}"
: "${RETENTION_MINUTES:=240}"

# MRMS product we consume. MergedReflectivityQComposite_00.50 is the 0.5 km
# resolution CONUS composite — the same feed RainViewer/Iowa State use
# under the hood. Product docs:
#   https://www.nssl.noaa.gov/projects/mrms/
MRMS_PRODUCT="MergedReflectivityQComposite_00.50"
MRMS_BUCKET="noaa-mrms-pds"
MRMS_PREFIX="CONUS/${MRMS_PRODUCT}"

# Web Mercator full extent (EPSG:3857). gdalwarp targets this box so
# gdal2tiles.py can slice at standard XYZ zoom levels.
MERC_EXTENT="-20037508.34 -20037508.34 20037508.34 20037508.34"

WORK_DIR="/var/lib/noaa-radar"
mkdir -p "$WORK_DIR"

# Round a timestamp (epoch seconds) down to the nearest 5-minute boundary
# in UTC; MRMS publishes on :00, :05, :10, ... wall clock.
floor_to_5min() {
  local epoch="${1:-$(date -u +%s)}"
  echo $(( epoch - (epoch % 300) ))
}

# Render a YYYYMMDDHHMM stamp from epoch seconds (UTC).
stamp_from_epoch() { date -u -d "@$1" +%Y%m%d%H%M; }

log() { printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*"; }
