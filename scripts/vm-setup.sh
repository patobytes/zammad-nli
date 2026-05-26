#!/usr/bin/env bash
# vm-setup.sh — Manually re-run or repair the full service stack on an existing Ubuntu 22.04 VM.
# The Bicep deployment runs this automatically on first boot via Custom Script Extension.
# Use this for re-runs after failures or to reprovision a replacement VM against
# the same Azure File Shares (data persists in Azure Files across VM recreations).
# Script is idempotent: safe to re-run on a running VM.
#
# Required env vars:
#   STORAGE_ACCOUNT  — Azure Storage Account name
#   STORAGE_KEY      — Storage Account access key (primary)
#   POSTGRES_PASS    — PostgreSQL password for Zammad
#   ZAMMAD_FQDN      — Public FQDN or IP Zammad will be reached at
#   VM_ADMIN         — Linux admin username (defaults to current user)
set -euo pipefail

: "${STORAGE_ACCOUNT:?must set STORAGE_ACCOUNT}"
: "${STORAGE_KEY:?must set STORAGE_KEY}"
: "${POSTGRES_PASS:?must set POSTGRES_PASS}"
: "${ZAMMAD_FQDN:?must set ZAMMAD_FQDN}"
VM_ADMIN="${VM_ADMIN:-${USER}}"

APP_DIR="/opt/zammad"
STORAGE_HOST="${STORAGE_ACCOUNT}.file.core.windows.net"
LOG="/var/log/zammad-setup.log"

exec >> "${LOG}" 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting setup (manual run)"

# ── Docker ──────────────────────────────────────────────────────────────────

DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl gnupg cifs-utils git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "${VM_ADMIN}"
systemctl enable --now docker

# proxy-net  172.20.0.0/24 — shared: NPM Plus, Portainer, Zammad nginx
# globaleaks-net 172.21.0.0/24 — isolated: GlobaLeaks only (NPM Plus attaches when deployed)
docker network create --driver bridge --subnet 172.20.0.0/24 proxy-net 2>/dev/null || true
docker network create --driver bridge --subnet 172.21.0.0/24 globaleaks-net 2>/dev/null || true

# ── Azure File Shares ────────────────────────────────────────────────────────
# SMB 3.0 provides encryption in transit (TLS).
# Credentials are stored in /etc/smbcredentials (root-only, mode 600).

mkdir -p /mnt/zammad-storage /mnt/zammad-backup /mnt/npm-certs /etc/smbcredentials
printf 'username=%s\npassword=%s\n' "${STORAGE_ACCOUNT}" "${STORAGE_KEY}" \
  > /etc/smbcredentials/zammad.cred
chmod 600 /etc/smbcredentials/zammad.cred

grep -q "zammad-storage" /etc/fstab || cat >> /etc/fstab << FSTABEOF
//${STORAGE_HOST}/zammad-storage /mnt/zammad-storage cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
//${STORAGE_HOST}/zammad-backup  /mnt/zammad-backup  cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
//${STORAGE_HOST}/npm-certs      /mnt/npm-certs      cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
FSTABEOF
mount -a

# ── NPM Plus (reverse proxy + SSL) ───────────────────────────────────────────
# Admin UI on localhost:81 — access via: ssh -L 81:localhost:81 zammadadmin@<ip>
# Default login: admin@example.com / changeme  (change immediately after first login)
# Certs stored in Azure Files /mnt/npm-certs — mountable on any service VM

mkdir -p /opt/npm
cat > /opt/npm/docker-compose.yml << 'NPMEOF'
services:
  npm:
    image: ghcr.io/zoeyvid/npmplus:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:81:81"
    volumes:
      - npm-data:/data
      - /mnt/npm-certs:/data/letsencrypt
    environment:
      - TZ=America/Sao_Paulo
    networks:
      - proxy-net

volumes:
  npm-data:

networks:
  proxy-net:
    external: true
NPMEOF
docker compose -f /opt/npm/docker-compose.yml pull
docker compose -f /opt/npm/docker-compose.yml up -d

# ── Portainer CE (Docker management UI) ──────────────────────────────────────
# Access via SSH tunnel: ssh -L 9000:localhost:9000 zammadadmin@<ip>
# Or add a proxy host in NPM Plus pointing to portainer:9000

mkdir -p /opt/portainer
cat > /opt/portainer/docker-compose.yml << 'PORTAINEREOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    networks:
      - proxy-net

volumes:
  portainer-data:

networks:
  proxy-net:
    external: true
PORTAINEREOF
docker compose -f /opt/portainer/docker-compose.yml pull
docker compose -f /opt/portainer/docker-compose.yml up -d

# ── Zammad ────────────────────────────────────────────────────────────────────
# nginx binds localhost:8080 only; NPM Plus reaches it at http://zammad-nginx-1:80

if [ ! -d "${APP_DIR}/.git" ]; then
  git clone https://github.com/zammad/zammad-docker-compose "${APP_DIR}"
fi
cd "${APP_DIR}"

cat > .env << ENVEOF
POSTGRES_PASS=${POSTGRES_PASS}
NGINX_EXPOSE_PORT=127.0.0.1:8080
TZ=America/Sao_Paulo
ZAMMAD_HTTP_TYPE=http
ZAMMAD_FQDN=${ZAMMAD_FQDN}
ENVEOF

# Patch Zammad's nginx config to pass through X-Forwarded-Proto from NPM Plus.
# Without this, $scheme would be 'http' (inner plain-HTTP connection) and Rails
# would never see 'https', breaking CSRF validation on OAuth flows.
[ ! -s nginx-zammad.conf ] && docker compose cp zammad-nginx:/etc/nginx/sites-available/default nginx-zammad.conf 2>/dev/null || true
sed -i 's/proxy_set_header X-Forwarded-Proto \$scheme;/proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;/g' nginx-zammad.conf

cat > docker-compose.override.yml << 'OVERRIDEEOF'
services:
  zammad-nginx:
    networks:
      default: {}
      proxy-net:
        aliases:
          - zammad-nginx-1
    volumes:
      - /opt/zammad/nginx-zammad.conf:/etc/nginx/sites-available/default:ro

volumes:
  zammad-storage:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/zammad-storage
  zammad-backup:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/zammad-backup

networks:
  proxy-net:
    external: true
OVERRIDEEOF

docker compose pull
docker compose up -d
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Setup complete"
