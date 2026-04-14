#!/usr/bin/env bash
# NOAA MRMS + HRRR → AWS tile pipeline: infrastructure lifecycle.
#
# Usage:
#   ./infra.sh up        # provision S3 + CloudFront + EC2 + pipeline cron
#   ./infra.sh down      # tear everything down (idempotent)
#   ./infra.sh status    # show current state of the stack
#   ./infra.sh logs      # tail pipeline logs from the EC2 instance
#   ./infra.sh deploy    # pull latest code and restart pipelines on the instance
#
# Resources created (all prefixed with $STACK_NAME):
#   - Two S3 buckets: radar tiles and forecast tiles
#   - Two CloudFront distributions (one per bucket, Origin Access Control)
#   - IAM role + instance profile granting EC2 write access to both buckets
#   - Security group (SSH-only, optional)
#   - EC2 instance (Node.js + GDAL) running cron → MRMS (5 min) + HRRR (hourly)
#
# State is persisted to .state/ so teardown can reverse exactly what was
# created. If you lose .state, `down` becomes best-effort against the
# STACK_NAME-prefixed resources.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ ! -f .env ]]; then
  echo "error: .env not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env

: "${AWS_REGION:?AWS_REGION must be set}"
: "${STACK_NAME:?STACK_NAME must be set}"
: "${REPO_URL:?REPO_URL must be set}"
: "${INSTANCE_TYPE:=t4g.small}"
: "${KEY_NAME:=}"
: "${SSH_CIDR:=0.0.0.0/0}"

STATE_DIR="$HERE/.state"
mkdir -p "$STATE_DIR"

# --- helpers -----------------------------------------------------------------

log()  { printf '[infra] %s\n' "$*"; }
warn() { printf '[infra] WARN: %s\n' "$*" >&2; }
die()  { printf '[infra] ERROR: %s\n' "$*" >&2; exit 1; }

state_set() { printf '%s\n' "$2" > "$STATE_DIR/$1"; }
state_get() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1" || true; }
state_del() { rm -f "$STATE_DIR/$1"; }

aws_() { aws --region "$AWS_REGION" "$@"; }

# Cache the account ID to avoid repeated STS calls.
_ACCOUNT_ID=""
account_id() {
  if [[ -z "$_ACCOUNT_ID" ]]; then
    _ACCOUNT_ID="$(aws_ sts get-caller-identity --query Account --output text)"
  fi
  echo "$_ACCOUNT_ID"
}

require_aws() {
  command -v aws >/dev/null || die "aws CLI not installed"
  aws_ sts get-caller-identity >/dev/null \
    || die "aws CLI not authenticated for region $AWS_REGION"
}

# --- S3 bucket names ---------------------------------------------------------
# Account ID suffix guarantees global uniqueness without coordination.

radar_bucket_name()    { echo "${STACK_NAME}-radar-$(account_id)"; }
forecast_bucket_name() { echo "${STACK_NAME}-forecast-$(account_id)"; }

# --- resource operations -----------------------------------------------------

create_bucket() {
  local bucket="$1"
  local state_key="$2"   # e.g. "radar_bucket" or "forecast_bucket"
  log "creating S3 bucket: $bucket"
  if aws_ s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    log "  bucket already exists, reusing"
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws_ s3api create-bucket --bucket "$bucket" >/dev/null
    else
      aws_ s3api create-bucket --bucket "$bucket" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
  fi
  aws_ s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
    >/dev/null
  # Safety-net lifecycle: delete objects older than 7 days.
  # The pipeline's upload scripts manage their own rotation at a shorter window.
  aws_ s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "expire-old-tiles",
        "Status": "Enabled",
        "Filter": { "Prefix": "" },
        "Expiration": { "Days": 7 }
      }]
    }' >/dev/null
  state_set "$state_key" "$bucket"
}

# Provision a CloudFront OAC + distribution for a given S3 bucket.
# State keys: ${prefix}_oac_id, ${prefix}_dist_id, ${prefix}_dist_domain
provision_cdn() {
  local prefix="$1"   # "radar" or "forecast"
  local bucket="$2"
  local oac_name="${STACK_NAME}-${prefix}-oac"

  # --- OAC ---
  log "[$prefix] creating Origin Access Control"
  local existing_oac
  existing_oac="$(aws_ cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${oac_name}'].Id | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -n "$existing_oac" && "$existing_oac" != "None" ]]; then
    log "  OAC exists: $existing_oac"
    state_set "${prefix}_oac_id" "$existing_oac"
  else
    local oac_id
    oac_id="$(aws_ cloudfront create-origin-access-control \
      --origin-access-control-config "$(cat <<JSON
{
  "Name": "${oac_name}",
  "Description": "OAC for ${STACK_NAME} ${prefix} tile bucket",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
JSON
)" --query 'OriginAccessControl.Id' --output text)"
    log "  created OAC: $oac_id"
    state_set "${prefix}_oac_id" "$oac_id"
  fi

  # --- Distribution ---
  log "[$prefix] creating CloudFront distribution (5-15 min to deploy)"
  local existing_dist
  existing_dist="$(state_get "${prefix}_dist_id")"
  if [[ -n "$existing_dist" ]] \
      && aws_ cloudfront get-distribution --id "$existing_dist" >/dev/null 2>&1; then
    log "  distribution $existing_dist already exists"
  else
    local oac_id; oac_id="$(state_get "${prefix}_oac_id")"
    local out
    out="$(aws_ cloudfront create-distribution --distribution-config "$(cat <<JSON
{
  "CallerReference": "${STACK_NAME}-${prefix}-$(date +%s)",
  "Comment": "${STACK_NAME} ${prefix} tile CDN",
  "Enabled": true,
  "PriceClass": "PriceClass_100",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-origin",
      "DomainName": "${bucket}.s3.${AWS_REGION}.amazonaws.com",
      "OriginAccessControlId": "${oac_id}",
      "S3OriginConfig": { "OriginAccessIdentity": "" }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }
}
JSON
)")"
    local dist_id dist_domain
    dist_id="$(echo "$out" | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1)"
    dist_domain="$(echo "$out" | sed -n 's/.*"DomainName": "\([^"]*\.cloudfront\.net\)".*/\1/p' | head -1)"
    [[ -n "$dist_id" ]] || die "failed to parse ${prefix} distribution ID"
    log "  created distribution: $dist_id ($dist_domain)"
    state_set "${prefix}_dist_id" "$dist_id"
    state_set "${prefix}_dist_domain" "$dist_domain"
  fi

  # --- Bucket policy ---
  local acct; acct="$(account_id)"
  local dist_id; dist_id="$(state_get "${prefix}_dist_id")"
  log "[$prefix] granting CloudFront read access to $bucket"
  aws_ s3api put-bucket-policy --bucket "$bucket" --policy "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipal",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${bucket}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::${acct}:distribution/${dist_id}"
      }
    }
  }]
}
JSON
)" >/dev/null
}

create_iam_role() {
  local radar_bucket="$1"
  local forecast_bucket="$2"
  local role="${STACK_NAME}-ec2"
  log "creating IAM role $role"
  if aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "  role already exists"
  else
    aws_ iam create-role --role-name "$role" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": { "Service": "ec2.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }]
      }' >/dev/null
  fi
  # SSM for console access without SSH; tile-writer for both buckets.
  aws_ iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  aws_ iam put-role-policy --role-name "$role" --policy-name tile-writer \
    --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${radar_bucket}",
      "arn:aws:s3:::${radar_bucket}/*",
      "arn:aws:s3:::${forecast_bucket}",
      "arn:aws:s3:::${forecast_bucket}/*"
    ]
  }]
}
JSON
)" >/dev/null
  if ! aws_ iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    aws_ iam create-instance-profile --instance-profile-name "$role" >/dev/null
    aws_ iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role" >/dev/null
    # IAM is eventually consistent; give EC2 a moment to see the profile.
    sleep 10
  fi
  state_set iam_role "$role"
}

create_security_group() {
  local sg_name="${STACK_NAME}-sg"
  log "creating security group $sg_name"
  local sg_id
  sg_id="$(aws_ ec2 describe-security-groups \
    --filters "Name=group-name,Values=$sg_name" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(aws_ ec2 create-security-group --group-name "$sg_name" \
      --description "$STACK_NAME pipeline EC2" \
      --query 'GroupId' --output text)"
    if [[ -n "$KEY_NAME" ]]; then
      aws_ ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr "$SSH_CIDR" >/dev/null
    fi
  else
    log "  SG already exists: $sg_id"
  fi
  state_set sg_id "$sg_id"
}

# Latest Amazon Linux 2023 ARM64 AMI in the current region.
latest_al2023_arm64() {
  aws_ ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query 'Parameter.Value' --output text
}

launch_instance() {
  local radar_bucket="$1"
  local forecast_bucket="$2"
  local existing
  existing="$(state_get instance_id)"
  if [[ -n "$existing" ]] \
      && aws_ ec2 describe-instances --instance-ids "$existing" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null \
        | grep -qE '^(pending|running)$'; then
    log "instance $existing already running"
    return
  fi
  log "launching $INSTANCE_TYPE EC2 instance"
  local ami; ami="$(latest_al2023_arm64)"
  local sg; sg="$(state_get sg_id)"
  local role; role="$(state_get iam_role)"
  # Render user-data: substitute bucket names, region, CloudFront domains, and repo URL.
  local radar_domain forecast_domain
  radar_domain="$(state_get radar_dist_domain)"
  forecast_domain="$(state_get forecast_dist_domain)"
  local user_data
  user_data="$(RADAR_BUCKET="$radar_bucket" \
    FORECAST_BUCKET="$forecast_bucket" \
    AWS_REGION="$AWS_REGION" \
    CLOUDFRONT_RADAR_URL="$radar_domain" \
    CLOUDFRONT_FORECAST_URL="$forecast_domain" \
    REPO_URL="$REPO_URL" \
    envsubst '${RADAR_BUCKET} ${FORECAST_BUCKET} ${AWS_REGION} ${CLOUDFRONT_RADAR_URL} ${CLOUDFRONT_FORECAST_URL} ${REPO_URL}' \
    < ec2/user-data.sh)"
  # Build run-instances args as an array that is always non-empty so that
  # "${run_args[@]}" is safe under set -u (macOS bash 3.2 treats an empty
  # array's [@] expansion as unbound).
  local run_args=(
    --image-id "$ami" --instance-type "$INSTANCE_TYPE"
    --security-group-ids "$sg"
    --iam-instance-profile "Name=$role"
    --user-data "$user_data"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-pipeline},{Key=Stack,Value=${STACK_NAME}}]"
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}"
    --query 'Instances[0].InstanceId' --output text
  )
  [[ -n "$KEY_NAME" ]] && run_args+=(--key-name "$KEY_NAME")
  local instance_id
  instance_id="$(aws_ ec2 run-instances "${run_args[@]}")"
  log "  launched: $instance_id"
  state_set instance_id "$instance_id"
  log "  waiting for instance to enter running state..."
  aws_ ec2 wait instance-running --instance-ids "$instance_id"
  log "  instance running. bootstrap (git clone + npm install) takes ~5 min."
}

# --- teardown ----------------------------------------------------------------

down_cdn() {
  local prefix="$1"   # "radar" or "forecast"
  local dist_id; dist_id="$(state_get "${prefix}_dist_id")"
  [[ -z "$dist_id" ]] && return
  log "[$prefix] disabling CloudFront distribution $dist_id"
  local etag
  etag="$(aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  [[ -z "$etag" ]] && { state_del "${prefix}_dist_id"; return; }
  aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'DistributionConfig' --output json > /tmp/dist-config-${prefix}.json
  sed -i 's/"Enabled": true/"Enabled": false/' /tmp/dist-config-${prefix}.json
  aws_ cloudfront update-distribution --id "$dist_id" \
    --distribution-config file:///tmp/dist-config-${prefix}.json \
    --if-match "$etag" >/dev/null || warn "update-distribution failed"
  log "  [$prefix] waiting for disabled state to deploy (~15 min)..."
  aws_ cloudfront wait distribution-deployed --id "$dist_id" || warn "wait timed out"
  etag="$(aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  aws_ cloudfront delete-distribution --id "$dist_id" --if-match "$etag" \
    || warn "distribution delete failed; retry after it finishes disabling"
  state_del "${prefix}_dist_id"
  state_del "${prefix}_dist_domain"
}

down_oac() {
  local prefix="$1"
  local id; id="$(state_get "${prefix}_oac_id")"
  [[ -z "$id" ]] && return
  log "[$prefix] deleting OAC $id"
  local etag
  etag="$(aws_ cloudfront get-origin-access-control --id "$id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  [[ -n "$etag" ]] && aws_ cloudfront delete-origin-access-control \
    --id "$id" --if-match "$etag" 2>/dev/null \
    || warn "OAC delete failed"
  state_del "${prefix}_oac_id"
}

down_bucket() {
  local state_key="$1"
  local bucket; bucket="$(state_get "$state_key")"
  [[ -z "$bucket" ]] && return
  log "emptying and deleting bucket $bucket"
  aws_ s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  aws_ s3api delete-bucket --bucket "$bucket" 2>/dev/null \
    || warn "bucket delete failed (not empty or has policy)"
  state_del "$state_key"
}

down_instance() {
  local id; id="$(state_get instance_id)"
  [[ -z "$id" ]] && return
  log "terminating EC2 $id"
  aws_ ec2 terminate-instances --instance-ids "$id" >/dev/null || true
  aws_ ec2 wait instance-terminated --instance-ids "$id" || true
  state_del instance_id
}

down_sg() {
  local id; id="$(state_get sg_id)"
  [[ -z "$id" ]] && return
  log "deleting security group $id"
  aws_ ec2 delete-security-group --group-id "$id" 2>/dev/null \
    || warn "SG delete failed (may have lingering ENIs)"
  state_del sg_id
}

down_iam() {
  local role; role="$(state_get iam_role)"
  [[ -z "$role" ]] && return
  log "deleting IAM role $role"
  aws_ iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role" 2>/dev/null || true
  aws_ iam delete-instance-profile --instance-profile-name "$role" 2>/dev/null || true
  aws_ iam delete-role-policy --role-name "$role" --policy-name tile-writer 2>/dev/null || true
  aws_ iam detach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws_ iam delete-role --role-name "$role" 2>/dev/null || true
  state_del iam_role
}

# --- top-level commands ------------------------------------------------------

cmd_up() {
  require_aws
  command -v envsubst >/dev/null || die "gettext (envsubst) not installed"
  local radar_bucket forecast_bucket
  radar_bucket="$(radar_bucket_name)"
  forecast_bucket="$(forecast_bucket_name)"

  create_bucket "$radar_bucket"    radar_bucket
  create_bucket "$forecast_bucket" forecast_bucket

  provision_cdn radar    "$radar_bucket"
  provision_cdn forecast "$forecast_bucket"

  create_iam_role "$radar_bucket" "$forecast_bucket"
  create_security_group
  launch_instance "$radar_bucket" "$forecast_bucket"

  log ""
  log "=== stack up ==="
  log "radar bucket:       $radar_bucket"
  log "forecast bucket:    $forecast_bucket"
  log "radar CDN:          https://$(state_get radar_dist_domain)"
  log "forecast CDN:       https://$(state_get forecast_dist_domain)"
  log ""
  log "CloudFront takes ~10 min to finish deploying. Paste the CDN URLs into"
  log "Raceday-itinerary > Config > Providers:"
  log "  NOAA AWS radar host:    https://$(state_get radar_dist_domain)"
  log "  NOAA AWS forecast host: https://$(state_get forecast_dist_domain)"
}

cmd_down() {
  require_aws
  # Disable both distributions in parallel (slow step), then clean up the rest.
  down_cdn radar    &
  down_cdn forecast &
  wait
  down_instance
  down_sg
  down_iam
  down_oac radar
  down_oac forecast
  down_bucket radar_bucket
  down_bucket forecast_bucket
  log "teardown complete."
}

cmd_status() {
  require_aws
  printf '%-26s %s\n' "radar_bucket"        "$(state_get radar_bucket || echo -)"
  printf '%-26s %s\n' "forecast_bucket"     "$(state_get forecast_bucket || echo -)"
  printf '%-26s %s\n' "radar_dist_id"       "$(state_get radar_dist_id || echo -)"
  printf '%-26s %s\n' "radar_cdn"           "https://$(state_get radar_dist_domain || echo -)"
  printf '%-26s %s\n' "forecast_dist_id"    "$(state_get forecast_dist_id || echo -)"
  printf '%-26s %s\n' "forecast_cdn"        "https://$(state_get forecast_dist_domain || echo -)"
  printf '%-26s %s\n' "instance_id"         "$(state_get instance_id || echo -)"
  printf '%-26s %s\n' "iam_role"            "$(state_get iam_role || echo -)"
  printf '%-26s %s\n' "sg_id"               "$(state_get sg_id || echo -)"

  local id; id="$(state_get instance_id)"
  if [[ -n "$id" ]]; then
    printf '%-26s %s\n' "instance_state" \
      "$(aws_ ec2 describe-instances --instance-ids "$id" \
          --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
  fi
  for prefix in radar forecast; do
    local dist; dist="$(state_get "${prefix}_dist_id")"
    if [[ -n "$dist" ]]; then
      printf '%-26s %s\n' "${prefix}_dist_state" \
        "$(aws_ cloudfront get-distribution --id "$dist" \
            --query 'Distribution.Status' --output text 2>/dev/null || echo unknown)"
    fi
  done
}

cmd_logs() {
  require_aws
  local id; id="$(state_get instance_id)"
  [[ -z "$id" ]] && die "no instance in state"
  local log_file="${1:-mrms}"   # mrms or hrrr
  local lines="${2:-100}"
  log "fetching last $lines lines of /var/log/noaa-${log_file}.log via SSM..."
  local cmd_id
  cmd_id="$(aws_ ssm send-command \
    --instance-ids "$id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"tail -n $lines /var/log/noaa-${log_file}.log\"]" \
    --query 'Command.CommandId' --output text)"
  # Poll until the command finishes (usually <5 s).
  local status="InProgress"
  while [[ "$status" == "InProgress" || "$status" == "Pending" ]]; do
    sleep 2
    status="$(aws_ ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$id" \
      --query 'Status' --output text 2>/dev/null || echo InProgress)"
  done
  aws_ ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$id" \
    --query 'StandardOutputContent' --output text
}

cmd_deploy() {
  require_aws
  local id; id="$(state_get instance_id)"
  [[ -z "$id" ]] && die "no instance in state"
  log "pulling latest code on $id via SSM..."
  aws_ ssm send-command \
    --instance-ids "$id" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cd /home/mrms/noaa-radar-pipeline && git pull origin main && npm install && echo deploy-ok"]' \
    --output text >/dev/null
  log "deploy command sent. Check logs with: ./infra.sh logs"
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  logs)   cmd_logs "${2:-mrms}" ;;
  deploy) cmd_deploy ;;
  *)      echo "usage: $0 {up|down|status|logs [mrms|hrrr]|deploy}" >&2; exit 2 ;;
esac
