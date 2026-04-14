#!/usr/bin/env bash
# GRIB2 → Web-Mercator PNG tile pyramid. Takes a raw .grib2 path; writes
# a tile tree under $WORK_DIR/tiles/{z}/{x}/{y}.png.
#
# Pipeline:
#   1. gdalwarp reprojects to EPSG:3857 at a fixed CONUS extent
#   2. gdaldem applies a radar reflectivity color ramp (dBZ → RGBA)
#   3. gdal2tiles.py slices into XYZ tiles for zoom range $TILE_ZOOM
#
# All intermediates are rewritten each run; nothing is incremental. That's
# fine because each input is ~15 MB and the warp/recolor/slice pass
# completes in <90s on t4g.small.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

input="${1:?path to .grib2 required}"
[[ -s "$input" ]] || { log "input GRIB2 missing: $input"; exit 1; }

warped="${WORK_DIR}/warped.tif"
colored="${WORK_DIR}/colored.tif"
ramp="${WORK_DIR}/ramp.txt"
tiles_out="${WORK_DIR}/tiles"

# Radar reflectivity color ramp. dBZ values → RGBA. Below 5 dBZ is
# transparent so light/no-return areas don't obscure the basemap. Matches
# the green-dominant look the Raceday-itinerary client expects; the
# client has its own recolor pipeline if operators prefer blue.
cat > "$ramp" <<RAMP
nv       0 0 0 0
-999     0 0 0 0
5        0 236 236 255
10       1 160 246 255
15       0 0 246 255
20       0 255 0 255
25       0 200 0 255
30       0 144 0 255
35       255 255 0 255
40       231 192 0 255
45       255 144 0 255
50       255 0 0 255
55       214 0 0 255
60       192 0 0 255
65       255 0 255 255
70       153 85 201 255
RAMP

log "reprojecting GRIB2 to EPSG:3857"
rm -f "$warped"
# MRMS GRIB2 uses EPSG:4326 source. -te sets Web-Mercator full extent,
# -ts 3072 3072 sets output pixel grid (chosen to keep z=7 tiles at
# reasonable resolution without blowing memory). -r near preserves
# reflectivity values for the ramp step — bilinear would blur the colors.
gdalwarp -q \
  -s_srs EPSG:4326 -t_srs EPSG:3857 \
  -te $MERC_EXTENT \
  -ts 3072 3072 \
  -r near \
  -of GTiff \
  "$input" "$warped"

log "applying reflectivity color ramp"
rm -f "$colored"
gdaldem color-relief -q -alpha \
  -of GTiff \
  "$warped" "$ramp" "$colored"

log "slicing XYZ tile pyramid (zoom $TILE_ZOOM)"
rm -rf "$tiles_out"
# --xyz forces the standard XYZ scheme (gdal2tiles defaults to TMS,
# which has Y flipped). Newer gdal2tiles also supports -w none to skip
# HTML; on older builds that flag is ignored and some HTML gets generated,
# which we'll just ignore.
gdal2tiles.py --xyz -q -z "$TILE_ZOOM" -w none "$colored" "$tiles_out" \
  || gdal2tiles.py --xyz -q -z "$TILE_ZOOM" "$colored" "$tiles_out"

# Quick sanity check that at least one PNG was emitted.
if ! find "$tiles_out" -name '*.png' -print -quit | grep -q .; then
  log "tile output is empty"
  exit 2
fi

echo "$tiles_out"
