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
# trmm-net   172.20.2.0/24 — Tactical RMM internal services (trmm-nginx bridges to proxy-net)
# Tenant networks (172.21.<n>.0/24) are created on demand by scripts/globaleaks-add-tenant.sh
docker network create --driver bridge --subnet 172.20.0.0/24 proxy-net 2>/dev/null || true
docker network create --driver bridge --subnet 172.20.2.0/24 trmm-net  2>/dev/null || true

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

# ── GlobaLeaks per-tenant deploy script ──────────────────────────────────────
mkdir -p /opt/scripts
cat > /opt/scripts/globaleaks-add-tenant.sh << 'GLSCRIPTEOF'
#!/usr/bin/env bash
# Usage: sudo bash /opt/scripts/globaleaks-add-tenant.sh <tenant-slug>
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-slug>}"
TENANT="${TENANT,,}"
TENANT="${TENANT//[^a-z0-9-]/}"
[[ -z "${TENANT}" ]] && { echo "ERROR: invalid slug" >&2; exit 1; }

NET="gl-${TENANT}-net"
CONTAINER="globaleaks-${TENANT}"
VOLUME="gl-${TENANT}-data"
DIR="/opt/globaleaks-${TENANT}"

docker network inspect "${NET}" &>/dev/null && {
  echo "Network ${NET} already exists. To redeploy: docker compose -f ${DIR}/docker-compose.yml up -d"
  exit 0
}

next_octet() {
  local max=0
  while IFS= read -r net; do
    local octet
    octet=$(docker network inspect "${net}" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null \
      | grep -oP '172\.21\.\K\d+(?=\.0/)' || true)
    [[ -n "${octet}" && "${octet}" -gt "${max}" ]] && max="${octet}"
  done < <(docker network ls --format '{{.Name}}' | grep '^gl-' || true)
  echo $((max + 1))
}

N=$(next_octet)
SUBNET="172.21.${N}.0/24"

echo "Deploying GlobaLeaks for tenant: ${TENANT}"
echo "  Network:   ${NET} (${SUBNET})"
echo "  Container: ${CONTAINER}"

docker network create --driver bridge --subnet "${SUBNET}" "${NET}"

mkdir -p "${DIR}"
cat > "${DIR}/docker-compose.yml" << EOF
services:
  ${CONTAINER}:
    image: globaleaks/globaleaks:latest
    container_name: ${CONTAINER}
    restart: unless-stopped
    volumes:
      - ${VOLUME}:/var/globaleaks
    networks:
      - ${NET}

volumes:
  ${VOLUME}:

networks:
  ${NET}:
    external: true
EOF

docker compose -f "${DIR}/docker-compose.yml" pull
docker compose -f "${DIR}/docker-compose.yml" up -d

docker inspect npm &>/dev/null \
  && docker network connect "${NET}" npm \
  && echo "NPM Plus connected to ${NET} (no restart needed)." \
  || echo "WARNING: npm container not found. Run: docker network connect ${NET} npm"

echo ""
echo "Add a proxy host in NPM Plus (http://localhost:81):"
echo "  Scheme: http  Hostname: ${CONTAINER}  Port: 8083"
echo ""
echo "To remove: docker compose -f ${DIR}/docker-compose.yml down && docker network disconnect ${NET} npm && docker network rm ${NET} && rm -rf ${DIR}"
GLSCRIPTEOF
chmod +x /opt/scripts/globaleaks-add-tenant.sh

# ── cPanel DNS update script ─────────────────────────────────────────────────
cat > /opt/scripts/cpanel-dns-update.sh << 'CPANELEOF'
#!/usr/bin/env bash
# cpanel-dns-update.sh — Create/update TRMM DNS A records via cPanel UAPI.
# Reads credentials from Azure Key Vault (kv-zmd-brs).
# Usage: sudo bash /opt/scripts/cpanel-dns-update.sh
# Override IP: TARGET_IP=x.x.x.x sudo bash /opt/scripts/cpanel-dns-update.sh
set -euo pipefail

KV="kv-zmd-brs"
ZONE="nextlevelinfo.com.br"
SUBDOMAINS=("rmm" "api-rmm" "mesh")
TTL=300

echo "Fetching cPanel credentials from Key Vault ${KV}..."
CPANEL_HOST=$(az keyvault secret show --vault-name "$KV" --name cpanel-host      --query value -o tsv)
CPANEL_USER=$(az keyvault secret show --vault-name "$KV" --name cpanel-username  --query value -o tsv)
CPANEL_TOKEN=$(az keyvault secret show --vault-name "$KV" --name cpanel-api-token --query value -o tsv)

if [[ -z "${TARGET_IP:-}" ]]; then
  echo "Fetching VM public IP from Azure..."
  TARGET_IP=$(az vm list-ip-addresses \
    --resource-group rg-zmd-brs \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
fi
echo "Target IP: ${TARGET_IP}"

cpanel_api() {
  local func="$1"; shift
  local params=("$@")
  local url="${CPANEL_HOST}/execute/DNS/${func}"
  local qs=""
  for p in "${params[@]}"; do qs+="&${p}"; done
  curl -s -k -H "Authorization: cpanel ${CPANEL_USER}:${CPANEL_TOKEN}" "${url}?${qs:1}"
}

echo "Fetching zone records for ${ZONE}..."
zone_data=$(cpanel_api "parse_zone" "zone=${ZONE}")
if ! echo "$zone_data" | jq -e '.status == 1' > /dev/null 2>&1; then
  echo "ERROR: Could not fetch zone. Check cPanel credentials." >&2
  echo "$zone_data" | jq . >&2; exit 1
fi

for sub in "${SUBDOMAINS[@]}"; do
  fqdn="${sub}.${ZONE}."
  existing_line=$(echo "$zone_data" | jq -r \
    ".data[] | select(.type == \"A\" and .name == \"${fqdn}\") | .line" 2>/dev/null || true)
  if [[ -n "$existing_line" ]]; then
    echo "Updating: ${fqdn} → ${TARGET_IP}"
    result=$(cpanel_api "edit_zone_record" "zone=${ZONE}" "line=${existing_line}" \
      "name=${fqdn}" "type=A" "ttl=${TTL}" "address=${TARGET_IP}")
  else
    echo "Creating: ${fqdn} → ${TARGET_IP}"
    result=$(cpanel_api "add_zone_record" "zone=${ZONE}" "name=${sub}" \
      "type=A" "ttl=${TTL}" "address=${TARGET_IP}")
  fi
  if echo "$result" | jq -e '.status == 1' > /dev/null 2>&1; then
    echo "  OK: ${fqdn}"
  else
    echo "  FAIL: ${fqdn}" >&2; echo "$result" | jq . >&2; exit 1
  fi
done

echo ""
echo "DNS updated. Verify: dig +short rmm.${ZONE} api-rmm.${ZONE} mesh.${ZONE}"
CPANELEOF
chmod +x /opt/scripts/cpanel-dns-update.sh

# ── Tactical RMM deploy script ────────────────────────────────────────────────
cat > /opt/scripts/trmm-setup.sh << 'TRMMSCRIPTEOF'
#!/usr/bin/env bash
# trmm-setup.sh — Deploy Tactical RMM on an already-bootstrapped VM.
# Idempotent: safe to re-run. Run after vm-setup.sh has completed.
#
# Required env vars:
#   APP_HOST    — rmm subdomain   (e.g. rmm.yourdomain.com)
#   API_HOST    — api subdomain   (e.g. api.yourdomain.com)
#   MESH_HOST   — mesh subdomain  (e.g. mesh.yourdomain.com)
#   MESH_USER   — MeshCentral admin username
#   MESH_PASS   — MeshCentral admin password
#   POSTGRES_PASS — DB password
#   SECRET_KEY  — Django secret key (generate with: python3 -c "import secrets; print(secrets.token_urlsafe(50))")
#
# Optional:
#   TRMM_VERSION  (default: latest)
#   POSTGRES_USER (default: tactical)
#   POSTGRES_DB   (default: tacticalrmm)
#   TZ            (default: America/Sao_Paulo)
set -euo pipefail

: "${APP_HOST:?must set APP_HOST}"
: "${API_HOST:?must set API_HOST}"
: "${MESH_HOST:?must set MESH_HOST}"
: "${MESH_USER:?must set MESH_USER}"
: "${MESH_PASS:?must set MESH_PASS}"
: "${POSTGRES_PASS:?must set POSTGRES_PASS}"
: "${SECRET_KEY:?must set SECRET_KEY}"

TRMM_VERSION="${TRMM_VERSION:-latest}"
POSTGRES_USER="${POSTGRES_USER:-tactical}"
POSTGRES_DB="${POSTGRES_DB:-tacticalrmm}"
TZ="${TZ:-America/Sao_Paulo}"
DIR="/opt/trmm"

echo "Deploying Tactical RMM to ${DIR}..."

mkdir -p "${DIR}"

# Write .env
cat > "${DIR}/.env" << ENVEOF
TRMM_VERSION=${TRMM_VERSION}
APP_HOST=${APP_HOST}
API_HOST=${API_HOST}
MESH_HOST=${MESH_HOST}
MESH_USER=${MESH_USER}
MESH_PASS=${MESH_PASS}
SECRET_KEY=${SECRET_KEY}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASS=${POSTGRES_PASS}
POSTGRES_DB=${POSTGRES_DB}
REDIS_HOST=tactical-redis
DB_HOST=tactical-postgres
TZ=${TZ}
ENVEOF
chmod 600 "${DIR}/.env"

# Write docker-compose.yml (canonical source: services/trmm/docker-compose.yml in repo)
cat > "${DIR}/docker-compose.yml" << 'COMPOSEEOF'
services:

  tactical-init:
    image: amidaware/tactical:${TRMM_VERSION:-latest}
    container_name: trmm-init
    command: ["/bin/bash", "/home/tactical/docker/init.sh"]
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    depends_on:
      - tactical-postgres
      - tactical-redis
    restart: "no"

  tactical-backend:
    image: amidaware/tactical:${TRMM_VERSION:-latest}
    container_name: trmm-backend
    command: ["/bin/bash", "/home/tactical/docker/entrypoints/backend.sh"]
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-postgres
      - tactical-redis

  tactical-celery:
    image: amidaware/tactical:${TRMM_VERSION:-latest}
    container_name: trmm-celery
    command: ["/bin/bash", "/home/tactical/docker/entrypoints/celery.sh"]
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-postgres
      - tactical-redis

  tactical-celery-beat:
    image: amidaware/tactical:${TRMM_VERSION:-latest}
    container_name: trmm-celery-beat
    command: ["/bin/bash", "/home/tactical/docker/entrypoints/celery-beat.sh"]
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-postgres
      - tactical-redis

  tactical-websockets:
    image: amidaware/tactical:${TRMM_VERSION:-latest}
    container_name: trmm-websockets
    command: ["/bin/bash", "/home/tactical/docker/entrypoints/websockets.sh"]
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-postgres
      - tactical-redis

  tactical-postgres:
    image: postgres:15-alpine
    container_name: trmm-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-tactical}
      POSTGRES_PASSWORD: ${POSTGRES_PASS}
      POSTGRES_DB: ${POSTGRES_DB:-tacticalrmm}
    volumes:
      - trmm-postgres-data:/var/lib/postgresql/data
    networks:
      - trmm-net

  tactical-redis:
    image: redis:7-alpine
    container_name: trmm-redis
    restart: unless-stopped
    networks:
      - trmm-net

  tactical-meshcentral:
    image: amidaware/tactical-meshcentral:${TRMM_VERSION:-latest}
    container_name: trmm-meshcentral
    env_file: .env
    volumes:
      - trmm-data:/home/tactical
      - trmm-mesh-data:/home/meshcentral
    networks:
      - trmm-net
    restart: unless-stopped

  tactical-nats:
    image: nats:2-alpine
    container_name: trmm-nats
    command: ["nats-server", "-c", "/home/tactical/docker/nats/nats.conf"]
    ports:
      - "4222:4222"
    volumes:
      - trmm-data:/home/tactical
    networks:
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-init

  tactical-nginx:
    image: nginx:1.25-alpine
    container_name: trmm-nginx
    volumes:
      - trmm-data:/home/tactical
      - trmm-nginx-conf:/etc/nginx/conf.d:ro
    networks:
      - proxy-net
      - trmm-net
    restart: unless-stopped
    depends_on:
      - tactical-backend
      - tactical-websockets
      - tactical-meshcentral

volumes:
  trmm-data:
  trmm-postgres-data:
  trmm-mesh-data:
  trmm-nginx-conf:

networks:
  proxy-net:
    external: true
  trmm-net:
    external: true
COMPOSEEOF

# Pull images
docker compose -f "${DIR}/docker-compose.yml" pull

# Run init (generates NATS certs, Django config, nginx config into trmm-data volume)
echo "Running tactical-init (first-run setup)..."
docker compose -f "${DIR}/docker-compose.yml" run --rm tactical-init

# Start the full stack
docker compose -f "${DIR}/docker-compose.yml" up -d

# Hot-connect NPM Plus to trmm-net (no npm restart needed)
docker inspect npm &>/dev/null \
  && docker network connect trmm-net npm 2>/dev/null \
  && echo "NPM Plus connected to trmm-net." \
  || echo "WARNING: npm container not found. Run: docker network connect trmm-net npm"

echo ""
echo "Tactical RMM is up. Configure NPM Plus proxy hosts (http://localhost:81):"
echo ""
echo "  1. ${APP_HOST}  → http  trmm-nginx  80   (SSL: Let's Encrypt, WS: off)"
echo "  2. ${API_HOST}  → http  trmm-nginx  80   (SSL: Let's Encrypt, WS: ON)"
echo "  3. ${MESH_HOST} → http  trmm-nginx  80   (SSL: Let's Encrypt, WS: ON)"
echo ""
echo "Also add NSG inbound rule for TCP 4222 (NATS — agent comms)."
echo "Agents connect to: ${API_HOST}:4222"
echo ""
echo "To remove TRMM:"
echo "  docker compose -f ${DIR}/docker-compose.yml down -v"
echo "  docker network disconnect trmm-net npm"
echo "  rm -rf ${DIR}"
TRMMSCRIPTEOF
chmod +x /opt/scripts/trmm-setup.sh

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Setup complete"
