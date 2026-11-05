#!/bin/bash
# Installs S3 world backups on a Valheim server box. Idempotent.
#   sudo bash install-backup.sh <backup-bucket-name> [region]
# Run automatically by user_data on new instances; run by hand on an instance
# that was created before backups existed. Requires the instance to have the
# valheim-instance IAM profile attached (terraform apply does that).
set -euo pipefail
BUCKET="${1:?usage: install-backup.sh <backup-bucket-name> [region]}"
export DEBIAN_FRONTEND=noninteractive

# Region for the AWS CLI. Passed in by user_data; otherwise read from IMDSv2.
REGION="${2:-}"
if [ -z "$REGION" ]; then
  TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/placement/region")
fi

# --- AWS CLI v2 (for `aws s3 cp`); credentials come from the instance role via IMDS ---
# Ubuntu 24.04 has no awscli apt package (snap only), so use AWS's own installer.
if ! command -v aws >/dev/null 2>&1; then
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 5; done
  apt-get update
  apt-get install -y unzip curl
  curl -sS https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# --- Config the backup script reads ---
install -d -m 755 /etc/valheim
cat > /etc/valheim/backup.env <<CONF
BACKUP_BUCKET=$BUCKET
AWS_DEFAULT_REGION=$REGION
CONF
chmod 644 /etc/valheim/backup.env

# --- The backup script ---
cat > /usr/local/bin/valheim-backup <<'BACKUP_EOF'
#!/bin/bash
# Tars worlds_local/ and uploads a timestamped copy to S3. Keeps the last 5
# tarballs locally too. Skips the upload when nothing has changed since the
# previous backup (the game only rewrites files when someone is playing).
set -euo pipefail
set -a; source /etc/valheim/backup.env; set +a   # export so the aws cli sees AWS_DEFAULT_REGION
WORLDS=/home/valheim/.config/unity3d/IronGate/Valheim/worlds_local
BACKUPS=/home/valheim/backups
MARKER=$BACKUPS/.last-backup
HOST=$(hostname -s)

[ -d "$WORLDS" ] || { echo "no worlds_local yet, nothing to back up"; exit 0; }
mkdir -p "$BACKUPS"

if [ "${1:-}" != "--force" ] && [ -f "$MARKER" ] && [ -z "$(find "$WORLDS" -newer "$MARKER" -type f -print -quit)" ]; then
  echo "$(date -Is) unchanged since last backup, skipping"
  exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
FILE="$BACKUPS/worlds_local-$STAMP.tar.gz"
tar -czf "$FILE" -C "$(dirname "$WORLDS")" worlds_local
aws s3 cp --only-show-errors "$FILE" "s3://$BACKUP_BUCKET/$HOST/worlds_local-$STAMP.tar.gz"
touch "$MARKER"
echo "$(date -Is) uploaded $(basename "$FILE") ($(du -h "$FILE" | cut -f1)) to s3://$BACKUP_BUCKET/$HOST/"

# Prune local copies to the five most recent.
ls -1t "$BACKUPS"/worlds_local-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
BACKUP_EOF
chmod 755 /usr/local/bin/valheim-backup
install -d -o valheim -g valheim -m 750 /home/valheim/backups

# --- Hourly, as the valheim user ---
cat > /etc/cron.d/valheim-backup <<'CRON'
0 * * * * valheim /usr/local/bin/valheim-backup >> /home/valheim/backups/backup.log 2>&1
CRON
chmod 644 /etc/cron.d/valheim-backup

# --- And after every graceful stop (patch, reboot, EC2 stop, /valheim stop) ---
# A systemd drop-in so the main unit file stays untouched.
install -d /etc/systemd/system/valheim.service.d
cat > /etc/systemd/system/valheim.service.d/backup.conf <<'UNIT'
[Service]
ExecStopPost=/usr/local/bin/valheim-backup --force
UNIT
systemctl daemon-reload

echo "backup installed: hourly cron + on-stop hook -> s3://$BUCKET/"
