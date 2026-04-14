# noaa-radar-aws

A self-hosted radar tile pipeline. Pulls MRMS composite reflectivity from
the NOAA Open Data S3 bucket every 5 minutes, reprojects to Web Mercator,
slices into XYZ PNG tiles, and serves them via S3 + CloudFront.

Designed to be consumed by [Raceday-itinerary](../Raceday-itinerary) as the
`noaa-aws` radar provider, but any Leaflet/MapLibre client that can load
`{z}/{x}/{y}.png` tiles works.

## Cost

At the default settings — `t4g.small` on-demand + ~20 GB rolling tile
storage + CloudFront free tier (year 1):

| Component | Monthly |
|---|---|
| EC2 t4g.small | ~$12 |
| S3 storage (20 GB, 1-day lifecycle) | ~$0.50 |
| CloudFront egress (under 1 TB/mo free tier) | $0 |
| **Total** | **~$13** |

Savings paths:

- 1-yr or 3-yr Reserved Instance on the EC2 → ~$4/mo compute → **~$5/mo total**
- Spot Instance with a respawn script → ~$3/mo compute → **~$4/mo total**

## Prerequisites

- AWS CLI v2, authenticated, with a default region or `AWS_REGION` set
- `envsubst` (`gettext` package) for `infra.sh up`
- An EC2 key pair (optional, only if you want SSH access)

## Quick start

```sh
cp .env.example .env
# edit .env, at minimum set KEY_NAME if you want SSH
./infra.sh up
```

After ~5 min the EC2 boots and CloudFront begins deploying (another 10 min).
`infra.sh status` will show `distribution_state` → `Deployed` when it's
ready. The final stdout from `up` prints the CloudFront domain — paste that
into **Raceday-itinerary > Config > Providers > NOAA AWS tile host**.

## Contracts

Tile keys in S3 (and therefore CloudFront URLs):

```
https://<distribution>.cloudfront.net/{YYYYMMDDHHMM}/{z}/{x}/{y}.png
```

where `YYYYMMDDHHMM` is the UTC observation time, floored to the 5-min
MRMS cadence. A `latest.json` manifest at the bucket root records the most
recent upload, which clients can poll for freshness checks.

Zoom levels: `2-7` by default (CONUS through regional). Widen via
`TILE_ZOOM` in `.env` only if you genuinely need street-level radar.

## Operations

```sh
./infra.sh up       # create / update the stack
./infra.sh down     # tear everything down (idempotent)
./infra.sh status   # dump current resource state
./infra.sh logs     # tail the pipeline log via SSM (no SSH required)
```

`down` is safe to re-run; it's idempotent and tolerates partial state.
CloudFront teardown is the slow step (~15 min to disable before delete).

## Pipeline internals

`pipeline/` contains the scripts baked onto the EC2:

- `fetch-mrms.sh`  — lists `s3://noaa-mrms-pds/CONUS/MergedReflectivityQComposite_00.50/` and pulls the newest `.grib2.gz`
- `build-tiles.sh` — `gdalwarp` → `gdaldem color-relief` → `gdal2tiles.py`
- `upload-tiles.sh` — `aws s3 sync` into the timestamp prefix + writes `latest.json`
- `prune.sh`      — deletes timestamp prefixes older than `RETENTION_MINUTES`
- `run.sh`        — cron orchestrator (flock-guarded)

MRMS product: `MergedReflectivityQComposite_00.50` — 0.5 km CONUS composite,
published on the :00/:05/:10... UTC wall-clock boundary.

## State

`./.state/` holds resource IDs so `down` knows what to delete. Don't commit
it; the `.gitignore` excludes it. If you lose `.state`, `down` becomes
best-effort — check the AWS console for stragglers.
