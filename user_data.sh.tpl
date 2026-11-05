#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Wait for any first-boot apt activity (unattended-upgrades) to release the lock ---
# Without this, apt-get below can fail on "Could not get lock" and set -e aborts
# the whole script before the service is ever installed.
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done

# --- OS dependencies ---
# lib32gcc-s1: SteamCMD is a 32-bit binary (amd64 multilib package, no i386
#              architecture needed).
# libatomic1, libpulse0, libpulse-dev: listed by Iron Gate's dedicated server
#              manual as required on Linux for the (64-bit) Valheim server.
# Ubuntu 24.04 already meets the GLIBC >= 2.29 / GLIBCXX >= 3.4.26 requirement.
apt-get update
apt-get install -y curl ufw lib32gcc-s1 libatomic1 libpulse0 libpulse-dev

# --- Dedicated service account ---
id -u valheim &>/dev/null || useradd -m -s /bin/bash valheim

# --- Install SteamCMD directly from Valve (avoids interactive apt EULA prompts) ---
sudo -u valheim mkdir -p /home/valheim/steamcmd
cd /home/valheim/steamcmd
sudo -u valheim curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o steamcmd_linux.tar.gz
sudo -u valheim tar -xzf steamcmd_linux.tar.gz

# --- Update script: stop, snapshot the world, pull latest server build, start ---
# Also used for the initial install below. Run later with: sudo valheim-update
# SteamCMD only touches the game binaries; the world save lives in
# worlds_local/ and is never modified by app_update. The snapshot is there
# in case a patch migrates the save format and you need to roll back.
cat > /usr/local/bin/valheim-update <<'EOF'
#!/bin/bash
set -euo pipefail
WORLDS=/home/valheim/.config/unity3d/IronGate/Valheim/worlds_local
BACKUPS=/home/valheim/backups

# Graceful stop: Valheim saves the world on SIGTERM before exiting.
systemctl stop valheim.service 2>/dev/null || true

# Snapshot worlds_local/ (skipped on first install, when it doesn't exist yet).
if [ -d "$WORLDS" ]; then
  sudo -u valheim mkdir -p "$BACKUPS"
  sudo -u valheim tar -czf "$BACKUPS/worlds_local-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$(dirname "$WORLDS")" worlds_local
  # Keep the five most recent snapshots.
  ls -1t "$BACKUPS"/worlds_local-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
fi

# SteamCMD sometimes fails its first app_update after a self-update with
# "Failed to install app '896660' (Missing configuration)"; a retry succeeds.
for attempt in 1 2 3; do
  if sudo -u valheim /home/valheim/steamcmd/steamcmd.sh \
       +force_install_dir /home/valheim/valheim-server \
       +login anonymous \
       +app_update 896660 validate \
       +quit; then
    break
  fi
  echo "steamcmd app_update failed (attempt $attempt of 3), retrying in 10s..."
  sleep 10
  [ "$attempt" -eq 3 ] && exit 1
done
systemctl start valheim.service
EOF
chmod 755 /usr/local/bin/valheim-update

# --- Start script ---
# Lives in /home/valheim, NOT inside the SteamCMD install dir: `app_update ...
# validate` overwrites anything in /home/valheim/valheim-server with Iron Gate's
# stock files, including their default start_server.sh (name "My server",
# password "secret", crossplay on).
# Written with a quoted heredoc so bash doesn't expand anything at write time;
# the dollar-brace placeholders below are filled in by Terraform's templatefile()
# before this script ever reaches the instance. Only the valheim user can read it,
# since it contains the join password.
sudo -u valheim mkdir -p /home/valheim/valheim-server
cat > /home/valheim/start_valheim.sh <<'EOF'
#!/bin/bash
export templdpath=$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=./linux64:$LD_LIBRARY_PATH
export SteamAppId=892970

cd /home/valheim/valheim-server
./valheim_server.x86_64 \
  -name "${server_name}" \
  -port 2456 \
  -world "${world_name}" \
  -password "${server_password}" \
  -public ${server_public} \
  -saveinterval 1800

export LD_LIBRARY_PATH=$templdpath
EOF
chown valheim:valheim /home/valheim/start_valheim.sh
chmod 700 /home/valheim/start_valheim.sh

# --- systemd unit: auto-start on boot (after the network is actually up), auto-restart on crash ---
cat > /etc/systemd/system/valheim.service <<'EOF'
[Unit]
Description=Valheim Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=valheim
WorkingDirectory=/home/valheim/valheim-server
ExecStart=/home/valheim/start_valheim.sh
Restart=on-failure
RestartSec=15
LimitNOFILE=10000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable valheim.service

# --- S3 world backups (hourly + on every graceful stop) ---
# Same installer you'd run by hand on an existing box; see scripts/install-backup.sh.
cat > /usr/local/bin/install-valheim-backup <<'INSTALL_EOF'
${install_backup_script}
INSTALL_EOF
chmod 755 /usr/local/bin/install-valheim-backup
/usr/local/bin/install-valheim-backup "${backup_bucket}" "${aws_region}"

# --- Firewall: game ports open, SSH already restricted at the security-group level ---
ufw allow 22/tcp
ufw allow 2456:2457/udp
ufw --force enable

# --- Initial download of the Valheim server (3-5 minutes), then start it ---
/usr/local/bin/valheim-update
