#!/usr/bin/env bash
# trmm-setup.sh — Deploy Tactical RMM on an already-bootstrapped VM.
# Idempotent: safe to re-run. Run after vm-setup.sh has completed.
#
# Required env vars:
#   APP_HOST    — rmm subdomain   (e.g. rmm.yourdomain.com)
#   API_HOST    — api subdomain   (e.g. api-rmm.yourdomain.com)
#   MESH_HOST   — mesh subdomain  (e.g. mesh.yourdomain.com)
#   MESH_USER   — MeshCentral admin username
#   MESH_PASS   — MeshCentral admin password
#   POSTGRES_PASS — DB password
#   SECRET_KEY  — Django secret key
#
# Optional:
#   TRMM_VERSION  (default: latest)
#   POSTGRES_USER (default: tactical)
#   POSTGRES_DB   (default: tacticalrmm)
#   TZ            (default: America/Sao_Paulo)
#
# Usage with Key Vault:
#   export APP_HOST=rmm.nextlevelinfo.com.br
#   export API_HOST=api-rmm.nextlevelinfo.com.br
#   export MESH_HOST=mesh.nextlevelinfo.com.br
#   export MESH_USER=meshcentral
#   export MESH_PASS=$(az keyvault secret show --vault-name kv-zmd-brs --name trmm-mesh-pass --query value -o tsv)
#   export POSTGRES_PASS=$(az keyvault secret show --vault-name kv-zmd-brs --name trmm-postgres-pass --query value -o tsv)
#   export SECRET_KEY=$(az keyvault secret show --vault-name kv-zmd-brs --name trmm-secret-key --query value -o tsv)
#   sudo -E bash /opt/scripts/trmm-setup.sh
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
echo "  1. ${APP_HOST}  → http  trmm-nginx  80   (SSL: Let's Encrypt)"
echo "  2. ${API_HOST}  → http  trmm-nginx  80   (SSL: Let's Encrypt)"
echo "  3. ${MESH_HOST} → http  trmm-nginx  80   (SSL: Let's Encrypt)"
echo ""
echo "Paste this in the Advanced tab of all 3 proxy hosts:"
echo "  proxy_http_version 1.1;"
echo "  proxy_set_header Upgrade \$http_upgrade;"
echo "  proxy_set_header Connection \"upgrade\";"
echo "  proxy_set_header Host \$host;"
echo ""
echo "Agents connect to: ${API_HOST}:4222"
