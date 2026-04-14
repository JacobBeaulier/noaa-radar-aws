#!/bin/bash
# user-data: runs as root on first boot of the pipeline EC2.
# infra.sh expands $BUCKET / $REGION / $TILE_ZOOM / $RETENTION_MINUTES /
# $CRON_EVERY_MINUTES via envsubst before attaching this to run-instances,
# then prepends an export of PIPELINE_B64 (the pipeline/ tarball).
set -euxo pipefail

exec > >(tee -a /var/log/noaa-bootstrap.log) 2>&1

dnf -y update
# Dependencies:
#   gdal      - gdalwarp, gdal_calc.py, gdaldem, gdal_merge.py, gdal2tiles.py
#   python3-gdal - the Python GDAL bindings gdal2tiles relies on
#   eccodes   - GRIB2 decoding backend GDAL uses when the file is compressed
#   wgrib2    - fallback + sanity-check on raw MRMS files
#   awscli-2  - we need v2 for sigv4 writes with the instance profile
#   cronie    - AL2023 doesn't ship cron by default
dnf -y install gdal gdal-devel python3-gdal eccodes eccodes-devel \
               wgrib2 awscli cronie jq tar gzip

systemctl enable --now crond

# Persist stack config for the pipeline scripts to source at run time.
cat > /etc/noaa-radar.env <<ENV
BUCKET=${BUCKET}
REGION=${REGION}
TILE_ZOOM=${TILE_ZOOM}
RETENTION_MINUTES=${RETENTION_MINUTES}
CRON_EVERY_MINUTES=${CRON_EVERY_MINUTES}
ENV

# Drop pipeline scripts baked into user-data (base64-wrapped tarball).
install -d -m 755 /opt/noaa-radar
echo "$PIPELINE_B64" | base64 -d | tar -xzf - -C /opt/noaa-radar
chmod +x /opt/noaa-radar/*.sh

# Cron: run every N minutes, wall-clock aligned (so we hit just after the
# MRMS :00/:05/:10 publish boundary). The pipeline self-locks via flock so
# a slow run can't double up.
cat > /etc/cron.d/noaa-radar <<CRON
*/${CRON_EVERY_MINUTES} * * * * root flock -n /var/run/noaa-radar.lock /opt/noaa-radar/run.sh >> /var/log/noaa-pipeline.log 2>&1
CRON
chmod 644 /etc/cron.d/noaa-radar

# Kick off a first run immediately so the bucket isn't empty when the
# operator looks at it; failure here doesn't abort bootstrap - cron will
# retry in a few minutes.
/opt/noaa-radar/run.sh >> /var/log/noaa-pipeline.log 2>&1 || true
