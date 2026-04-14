#!/bin/bash
# EC2 bootstrap: install deps, clone pipeline, configure cron.
#
# infra.sh renders this file via envsubst before attaching it to run-instances,
# substituting: ${RADAR_BUCKET} ${FORECAST_BUCKET} ${AWS_REGION}
#               ${CLOUDFRONT_RADAR_URL} ${CLOUDFRONT_FORECAST_URL} ${REPO_URL}
#
# All other ${...} tokens (heredoc contents, etc.) are intentionally left
# unexpanded by using single-quoted heredoc delimiters.
set -euxo pipefail

exec > >(tee -a /var/log/noaa-bootstrap.log) 2>&1

dnf -y update
# gdal310 / gdal310-python-tools: gdalwarp, gdal_calc.py, gdaldem, gdal_merge.py, gdal2tiles.py
# nodejs20 + npm: TypeScript pipeline runtime
# cronie: cron daemon (not installed by default on AL2023)
# git: clone the repo
dnf -y install gdal310 gdal310-python-tools nodejs20 npm cronie git

systemctl enable --now crond

# 512 MB swap — GDAL can spike during raster operations on memory-constrained instances.
dd if=/dev/zero of=/swapfile bs=1M count=512
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

# Dedicated user for the pipeline processes.
useradd -m -s /bin/bash mrms

# Log rotation for both pipelines.
cat > /etc/logrotate.d/noaa-radar << 'EOF'
/var/log/noaa-mrms.log /var/log/noaa-hrrr.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
EOF

# Clone the pipeline repo.
git clone ${REPO_URL} /home/mrms/noaa-radar-pipeline
chown -R mrms:mrms /home/mrms/noaa-radar-pipeline

# Write runtime .env — values are substituted by envsubst in infra.sh.
cat > /home/mrms/noaa-radar-pipeline/.env << 'DOTENV'
AWS_REGION=${AWS_REGION}
S3_RADAR_BUCKET=${RADAR_BUCKET}
S3_FORECAST_BUCKET=${FORECAST_BUCKET}
CLOUDFRONT_RADAR_URL=https://${CLOUDFRONT_RADAR_URL}
CLOUDFRONT_FORECAST_URL=https://${CLOUDFRONT_FORECAST_URL}
DOTENV
chmod 600 /home/mrms/noaa-radar-pipeline/.env
chown mrms:mrms /home/mrms/noaa-radar-pipeline/.env

# Install Node.js dependencies (runs npm postinstall, downloads sharp ARM64 binary).
cd /home/mrms/noaa-radar-pipeline
npm install
chown -R mrms:mrms /home/mrms/noaa-radar-pipeline

# Wrapper scripts with flock to prevent concurrent runs.
# cron runs as root; su switches to mrms for the actual pipeline work.
cat > /usr/local/bin/run-mrms.sh << 'SCRIPT'
#!/bin/bash
flock -n /var/run/noaa-mrms.lock \
  su - mrms -c 'cd /home/mrms/noaa-radar-pipeline && npm run mrms' \
  >> /var/log/noaa-mrms.log 2>&1
SCRIPT
chmod +x /usr/local/bin/run-mrms.sh

cat > /usr/local/bin/run-hrrr.sh << 'SCRIPT'
#!/bin/bash
flock -n /var/run/noaa-hrrr.lock \
  su - mrms -c 'cd /home/mrms/noaa-radar-pipeline && npm run hrrr' \
  >> /var/log/noaa-hrrr.log 2>&1
SCRIPT
chmod +x /usr/local/bin/run-hrrr.sh

# Cron: MRMS every 5 minutes (matches NOAA publish cadence), HRRR hourly at :30.
cat > /etc/cron.d/noaa-radar << 'CRON'
*/5 * * * * root /usr/local/bin/run-mrms.sh
30 * * * * root /usr/local/bin/run-hrrr.sh
CRON
chmod 644 /etc/cron.d/noaa-radar

# Kick off first MRMS run immediately; failure is non-fatal (cron retries in 5 min).
/usr/local/bin/run-mrms.sh || true
