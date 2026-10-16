# ACM DR lab - environment
# Copy to env.sh, fill in, then:  source ./env.sh
# Every lab command uses explicit --context, so you never act on the wrong hub by accident.

# kubeconfig contexts (see 00-prereqs.md "Contexts")
export HUB1=hub1          # primary hub: ACM already running, BackupSchedule will live here
export HUB2=hub2          # new SNO hub: fresh ACM install, restore target
export SPOKE=spoke1       # one managed cluster imported in HUB1 (context used only for checks)
export SPOKE_NAME=spoke1  # ManagedCluster name of that spoke as seen by HUB1

# ACM install (filled from HUB1 in 03-install-new-hub.md, do not guess)
export ACM_CHANNEL=release-2.17
export ACM_CSV=""         # e.g. advanced-cluster-management.v2.17.x

# S3-compatible object storage shared by both hubs (MinIO, ODF MCG, AWS S3...)
export S3_URL=https://s3.example.lab:9000   # https:// required; empty for AWS S3. ODF: see 00-prereqs "ODF bucket"
export S3_REGION=us-east-1                     # MinIO accepts any value, "minio" or "us-east-1"
export S3_BUCKET=acm-dr-lab
export S3_PREFIX=acm                           # both hubs MUST use the same bucket + prefix
export S3_ACCESS_KEY=changeme
export S3_SECRET_KEY=changeme
export S3_INSECURE=true                        # "true" if S3 endpoint uses a self-signed cert

# labs3 = "aws s3" bound to the lab bucket credentials/endpoint. Env credentials take
# precedence over ~/.aws profiles, which are left untouched. Usage: labs3 ls s3://$S3_BUCKET/$S3_PREFIX/   (works in bash and zsh)
# Checksum vars: AWS CLI >= 2.23 sends CRC checksums by default, which some S3-compatible
# stores (older MinIO, Ceph RGW / ODF) reject.
labs3() {
  local opts=()
  [ -n "$S3_URL" ] && opts+=(--endpoint-url "$S3_URL")
  [ "$S3_INSECURE" = true ] && opts+=(--no-verify-ssl)
  AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  AWS_DEFAULT_REGION="$S3_REGION" \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws "${opts[@]}" s3 "$@"
}

# Backup cadence for the lab (hourly, like the doc example)
export BACKUP_CRON="0 */1 * * *"
export BACKUP_TTL=120h

# Fixed names (match the product doc)
export BKP_NS=open-cluster-management-backup
export ACM_NS=open-cluster-management
