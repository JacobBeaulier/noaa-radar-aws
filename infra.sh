#!/usr/bin/env bash
# NOAA MRMS → AWS tile pipeline: infrastructure lifecycle.
#
# Usage:
#   ./infra.sh up        # provision S3 + CloudFront + EC2 + pipeline cron
#   ./infra.sh down      # tear everything down (idempotent)
#   ./infra.sh status    # show current state of the stack
#   ./infra.sh logs      # tail pipeline log from the EC2 instance
#
# Resources created (all prefixed with $STACK_NAME):
#   - S3 bucket for tiles, with a 4h lifecycle rule
#   - CloudFront distribution fronting the bucket (Origin Access Control)
#   - IAM role + instance profile granting the EC2 instance bucket:PutObject
#   - Security group (SSH-only, optional)
#   - EC2 instance running cron → MRMS fetch → GDAL → S3 upload
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
: "${INSTANCE_TYPE:=t4g.small}"
: "${TILE_ZOOM:=2-7}"
: "${RETENTION_MINUTES:=240}"
: "${CRON_EVERY_MINUTES:=5}"
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

require_aws() {
  command -v aws >/dev/null || die "aws CLI not installed"
  aws_ sts get-caller-identity >/dev/null \
    || die "aws CLI not authenticated for region $AWS_REGION"
}

account_id() { aws_ sts get-caller-identity --query Account --output text; }

# --- resource operations -----------------------------------------------------

# S3 bucket naming rules: lowercase, 3-63 chars, DNS-safe. Account suffix
# guarantees global uniqueness without coordination.
bucket_name() {
  local acct; acct="$(account_id)"
  echo "${STACK_NAME}-tiles-${acct}"
}

create_bucket() {
  local bucket="$1"
  log "creating S3 bucket: $bucket"
  if aws_ s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    log "  bucket already exists, reusing"
  else
    # us-east-1 is the only region that rejects a LocationConstraint
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
  # Lifecycle: delete tile prefixes older than RETENTION_MINUTES.
  # Minimum S3 expiration granularity is 1 day, so we apply 1-day expiry
  # and the pipeline actively prunes anything older than RETENTION_MINUTES
  # on each run. The lifecycle rule is a safety net for orphans.
  local life_days=1
  aws_ s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
    --lifecycle-configuration "$(cat <<JSON
{
  "Rules": [{
    "ID": "expire-old-tiles",
    "Status": "Enabled",
    "Filter": { "Prefix": "" },
    "Expiration": { "Days": $life_days }
  }]
}
JSON
)" >/dev/null
  state_set bucket "$bucket"
}

create_oac() {
  log "creating CloudFront Origin Access Control"
  local existing
  existing="$(aws_ cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${STACK_NAME}-oac'].Id | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    log "  OAC exists: $existing"
    state_set oac_id "$existing"
    return
  fi
  local oac_id
  oac_id="$(aws_ cloudfront create-origin-access-control \
    --origin-access-control-config "$(cat <<JSON
{
  "Name": "${STACK_NAME}-oac",
  "Description": "OAC for ${STACK_NAME} tile bucket",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
JSON
)" --query 'OriginAccessControl.Id' --output text)"
  log "  created OAC: $oac_id"
  state_set oac_id "$oac_id"
}

create_distribution() {
  local bucket="$1"
  local oac_id="$2"
  log "creating CloudFront distribution (this takes 5-15 min)"
  local existing
  existing="$(state_get distribution_id)"
  if [[ -n "$existing" ]] \
      && aws_ cloudfront get-distribution --id "$existing" >/dev/null 2>&1; then
    log "  distribution $existing already exists"
    return
  fi
  local config
  config="$(cat <<JSON
{
  "CallerReference": "${STACK_NAME}-$(date +%s)",
  "Comment": "${STACK_NAME} MRMS tile CDN",
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
)"
  local dist_id dist_domain
  local out
  out="$(aws_ cloudfront create-distribution --distribution-config "$config")"
  dist_id="$(echo "$out" | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1)"
  dist_domain="$(echo "$out" | sed -n 's/.*"DomainName": "\([^"]*\.cloudfront\.net\)".*/\1/p' | head -1)"
  [[ -n "$dist_id" ]] || die "failed to parse distribution ID"
  log "  created distribution: $dist_id ($dist_domain)"
  state_set distribution_id "$dist_id"
  state_set distribution_domain "$dist_domain"
}

apply_bucket_policy() {
  local bucket="$1"
  local dist_id="$2"
  local acct; acct="$(account_id)"
  log "granting CloudFront read access to $bucket"
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
  local role="${STACK_NAME}-ec2"
  log "creating IAM role $role"
  if aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "  role already exists"
  else
    aws_ iam create-role --role-name "$role" \
      --assume-role-policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)" >/dev/null
  fi
  # SSM for console access, inline policy for S3 write on our bucket only.
  aws_ iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  local bucket="$1"
  aws_ iam put-role-policy --role-name "$role" --policy-name tile-writer \
    --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${bucket}",
      "arn:aws:s3:::${bucket}/*"
    ]
  }]
}
JSON
)" >/dev/null
  # Instance profile wraps the role for EC2 consumption.
  if ! aws_ iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    aws_ iam create-instance-profile --instance-profile-name "$role" >/dev/null
    aws_ iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role" >/dev/null
    # IAM is eventually consistent; give EC2 a few seconds to see the profile.
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
  local bucket="$1"
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
  # Render user-data with env substituted. The EC2 instance needs to know
  # bucket name, zoom range, cron cadence, retention — write them into
  # /etc/noaa-radar.env and the user-data script reads from there. Restrict
  # envsubst to our named vars so dollar-signs in shell syntax survive.
  local user_data
  user_data="$(BUCKET="$bucket" REGION="$AWS_REGION" \
    TILE_ZOOM="$TILE_ZOOM" RETENTION_MINUTES="$RETENTION_MINUTES" \
    CRON_EVERY_MINUTES="$CRON_EVERY_MINUTES" \
    envsubst '${BUCKET} ${REGION} ${TILE_ZOOM} ${RETENTION_MINUTES} ${CRON_EVERY_MINUTES}' \
    < ec2/user-data.sh)"
  # Bundle pipeline scripts as a tarball so user-data can drop them into /opt.
  tar -C pipeline -czf /tmp/pipeline.tar.gz . 2>/dev/null
  local pipeline_b64; pipeline_b64="$(base64 -w0 /tmp/pipeline.tar.gz)"
  # Prepend the encoded payload so user-data can recover it.
  user_data="$(printf '#!/bin/bash\nexport PIPELINE_B64=%q\n%s\n' "$pipeline_b64" "$user_data")"
  local key_arg=()
  [[ -n "$KEY_NAME" ]] && key_arg=(--key-name "$KEY_NAME")
  local instance_id
  instance_id="$(aws_ ec2 run-instances \
    --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$sg" \
    --iam-instance-profile "Name=$role" \
    "${key_arg[@]}" \
    --user-data "$user_data" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-pipeline},{Key=Stack,Value=${STACK_NAME}}]" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=12,VolumeType=gp3}" \
    --query 'Instances[0].InstanceId' --output text)"
  log "  launched: $instance_id"
  state_set instance_id "$instance_id"
  log "  waiting for instance to enter running state..."
  aws_ ec2 wait instance-running --instance-ids "$instance_id"
  log "  instance running. pipeline bootstrap takes another ~3 min."
}

# --- teardown ----------------------------------------------------------------

down_distribution() {
  local dist_id; dist_id="$(state_get distribution_id)"
  [[ -z "$dist_id" ]] && return
  log "disabling CloudFront distribution $dist_id"
  local etag
  etag="$(aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  [[ -z "$etag" ]] && { state_del distribution_id; return; }
  # Fetch config, flip Enabled -> false, push back.
  aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'DistributionConfig' --output json > /tmp/dist-config.json
  sed -i 's/"Enabled": true/"Enabled": false/' /tmp/dist-config.json
  aws_ cloudfront update-distribution --id "$dist_id" \
    --distribution-config file:///tmp/dist-config.json \
    --if-match "$etag" >/dev/null || warn "update-distribution failed"
  log "  waiting for distribution to deploy disabled state (15+ min)..."
  aws_ cloudfront wait distribution-deployed --id "$dist_id" || warn "wait timed out"
  etag="$(aws_ cloudfront get-distribution-config --id "$dist_id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  aws_ cloudfront delete-distribution --id "$dist_id" --if-match "$etag" \
    || warn "distribution delete failed; try again after it finishes disabling"
  state_del distribution_id
  state_del distribution_domain
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
  aws_ iam detach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws_ iam delete-role --role-name "$role" 2>/dev/null || true
  state_del iam_role
}

down_oac() {
  local id; id="$(state_get oac_id)"
  [[ -z "$id" ]] && return
  log "deleting OAC $id"
  local etag
  etag="$(aws_ cloudfront get-origin-access-control --id "$id" \
    --query 'ETag' --output text 2>/dev/null || true)"
  [[ -n "$etag" ]] && aws_ cloudfront delete-origin-access-control \
    --id "$id" --if-match "$etag" 2>/dev/null \
    || warn "OAC delete failed"
  state_del oac_id
}

down_bucket() {
  local bucket; bucket="$(state_get bucket)"
  [[ -z "$bucket" ]] && return
  log "emptying and deleting bucket $bucket"
  aws_ s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  aws_ s3api delete-bucket --bucket "$bucket" 2>/dev/null \
    || warn "bucket delete failed (not empty or has policy)"
  state_del bucket
}

# --- top-level commands ------------------------------------------------------

cmd_up() {
  require_aws
  command -v envsubst >/dev/null || die "gettext (envsubst) not installed"
  local bucket; bucket="$(bucket_name)"
  create_bucket "$bucket"
  create_oac
  create_distribution "$bucket" "$(state_get oac_id)"
  apply_bucket_policy "$bucket" "$(state_get distribution_id)"
  create_iam_role "$bucket"
  create_security_group
  launch_instance "$bucket"
  log ""
  log "=== stack up ==="
  log "bucket:       $bucket"
  log "distribution: $(state_get distribution_id)"
  log "tile host:    https://$(state_get distribution_domain)"
  log ""
  log "Copy the tile host into Raceday-itinerary > Config > Providers > NOAA AWS tile host."
  log "CloudFront takes another ~10 min to finish deploying. Once status=Deployed,"
  log "  curl -I https://$(state_get distribution_domain)/"
  log "should return 403 (access denied is expected for the root, it means routing works)."
}

cmd_down() {
  require_aws
  # CloudFront disable is the slow step; run it first so everything else
  # can tear down while we wait.
  down_distribution
  down_instance
  down_sg
  down_iam
  down_oac
  down_bucket
  log "teardown complete."
}

cmd_status() {
  require_aws
  printf '%-22s %s\n' "bucket"           "$(state_get bucket || echo -)"
  printf '%-22s %s\n' "distribution_id"  "$(state_get distribution_id || echo -)"
  printf '%-22s %s\n' "distribution_url" "https://$(state_get distribution_domain || echo -)"
  printf '%-22s %s\n' "instance_id"      "$(state_get instance_id || echo -)"
  printf '%-22s %s\n' "iam_role"         "$(state_get iam_role || echo -)"
  printf '%-22s %s\n' "sg_id"            "$(state_get sg_id || echo -)"
  printf '%-22s %s\n' "oac_id"           "$(state_get oac_id || echo -)"
  local id; id="$(state_get instance_id)"
  if [[ -n "$id" ]]; then
    printf '%-22s %s\n' "instance_state" \
      "$(aws_ ec2 describe-instances --instance-ids "$id" \
          --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
  fi
  local dist; dist="$(state_get distribution_id)"
  if [[ -n "$dist" ]]; then
    printf '%-22s %s\n' "distribution_state" \
      "$(aws_ cloudfront get-distribution --id "$dist" \
          --query 'Distribution.Status' --output text 2>/dev/null || echo unknown)"
  fi
}

cmd_logs() {
  require_aws
  local id; id="$(state_get instance_id)"
  [[ -z "$id" ]] && die "no instance in state"
  log "streaming /var/log/noaa-pipeline.log via SSM (Ctrl-C to exit)"
  aws_ ssm start-session --target "$id" \
    --document-name AWS-StartInteractiveCommand \
    --parameters "command=['sudo tail -f /var/log/noaa-pipeline.log']"
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  *)      echo "usage: $0 {up|down|status|logs}" >&2; exit 2 ;;
esac
