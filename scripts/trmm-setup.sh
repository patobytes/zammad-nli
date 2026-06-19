#!/usr/bin/env bash
# trmm-setup.sh — Deploy Tactical RMM using the official upstream docker-compose.
# SSL is handled by NPM Plus (wildcard *.nextlevelinfo.com.br from npm-certs share).
# tactical-nginx serves HTTP only on port 8181; NPM proxies and terminates TLS.
# Idempotent: safe to re-run.
#
# Required env vars:
#   APP_HOST      — rmm dashboard   (e.g. rmm.nextlevelinfo.com.br)
#   API_HOST      — api subdomain   (e.g. api-rmm.nextlevelinfo.com.br)
#   MESH_HOST     — mesh subdomain  (e.g. mesh.nextlevelinfo.com.br)
#   TRMM_USER     — TRMM dashboard login username
#   TRMM_PASS     — TRMM dashboard login password
#   MESH_USER     — MeshCentral admin username
#   MESH_PASS     — MeshCentral admin password
#   POSTGRES_PASS — PostgreSQL password
#   MONGODB_PASS  — MongoDB password (for MeshCentral)
#
# Optional:
#   VERSION         (default: latest)
#   POSTGRES_USER   (default: postgres)
#
# After this script runs, in NPM Plus admin (http://localhost:81):
#   Add proxy host for each of the 3 domains → trmm-nginx:8080  (HTTP, no SSL in backend)
#   SSL tab: select the *.nextlevelinfo.com.br wildcard cert (already on npm-certs share)
#   Advanced tab on all 3: paste the WebSocket headers (see README)
#
# NATS (port 4222) is exposed directly on the host — agents connect to API_HOST:4222.
set -euo pipefail

: "${APP_HOST:?must set APP_HOST}"
: "${API_HOST:?must set API_HOST}"
: "${MESH_HOST:?must set MESH_HOST}"
: "${TRMM_USER:?must set TRMM_USER}"
: "${TRMM_PASS:?must set TRMM_PASS}"
: "${MESH_USER:?must set MESH_USER}"
: "${MESH_PASS:?must set MESH_PASS}"
: "${POSTGRES_PASS:?must set POSTGRES_PASS}"
: "${MONGODB_PASS:?must set MONGODB_PASS}"

VERSION="${VERSION:-latest}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
DIR="/opt/trmm"

echo "Deploying Tactical RMM ${VERSION} to ${DIR}..."
mkdir -p "${DIR}"

# ── Write .env ────────────────────────────────────────────────────────────────
cat > "${DIR}/.env" << ENVEOF
IMAGE_REPO=tacticalrmm/
VERSION=${VERSION}

TRMM_USER=${TRMM_USER}
TRMM_PASS=${TRMM_PASS}

# HTTP only — SSL terminated by NPM Plus
TRMM_HTTP_PORT=8181
TRMM_HTTPS_PORT=0

APP_HOST=${APP_HOST}
API_HOST=${API_HOST}
MESH_HOST=${MESH_HOST}

MESH_USER=${MESH_USER}
MESH_PASS=${MESH_PASS}
MONGODB_USER=mongouser
MONGODB_PASSWORD=${MONGODB_PASS}
MESH_PERSISTENT_CONFIG=0

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASS=${POSTGRES_PASS}

TRMM_DISABLE_WEB_TERMINAL=False
TRMM_DISABLE_SERVER_SCRIPTS=False
TRMM_DISABLE_SSO=False
ENVEOF
chmod 600 "${DIR}/.env"

# ── Write docker-compose.yml ──────────────────────────────────────────────────
cat > "${DIR}/docker-compose.yml" << 'COMPOSEEOF'
version: "3.7"

# trmm-net: internal routing between TRMM services (172.20.3.0/24, no overlap with proxy-net)
# proxy-net: external — trmm-nginx joins this so NPM Plus can reach it
networks:
  trmm-net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.23.0.0/24
  proxy-net:
    external: true
  trmm-api-db:
    driver: bridge
  trmm-redis:
    driver: bridge
  trmm-mesh-db:
    driver: bridge

volumes:
  tactical_data: null
  postgres_data: null
  mongo_data: null
  mesh_data: null
  redis_data: null

services:

  tactical-postgres:
    container_name: trmm-postgres
    image: postgres:13-alpine
    restart: always
    environment:
      POSTGRES_DB: tacticalrmm
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASS}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - trmm-api-db

  tactical-redis:
    container_name: trmm-redis
    image: redis:6.0-alpine
    user: 1000:1000
    command: redis-server
    restart: always
    volumes:
      - redis_data:/data
    networks:
      - trmm-redis

  tactical-mongodb:
    container_name: trmm-mongodb
    image: mongo:4.4
    user: 1000:1000
    restart: always
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGODB_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGODB_PASSWORD}
      MONGO_INITDB_DATABASE: meshcentral
    networks:
      - trmm-mesh-db
    volumes:
      - mongo_data:/data/db

  tactical-meshcentral:
    container_name: trmm-meshcentral
    image: ${IMAGE_REPO}tactical-meshcentral:${VERSION}
    user: 1000:1000
    restart: always
    environment:
      MESH_HOST: ${MESH_HOST}
      MESH_USER: ${MESH_USER}
      MESH_PASS: ${MESH_PASS}
      MONGODB_USER: ${MONGODB_USER}
      MONGODB_PASSWORD: ${MONGODB_PASSWORD}
      MESH_PERSISTENT_CONFIG: ${MESH_PERSISTENT_CONFIG}
    networks:
      trmm-net:
        aliases:
          - ${MESH_HOST}
      trmm-mesh-db: null
    volumes:
      - tactical_data:/opt/tactical
      - mesh_data:/home/node/app/meshcentral-data
    depends_on:
      - tactical-mongodb

  tactical-init:
    container_name: trmm-init
    image: ${IMAGE_REPO}tactical:${VERSION}
    restart: on-failure
    command: ["tactical-init"]
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASS: ${POSTGRES_PASS}
      APP_HOST: ${APP_HOST}
      API_HOST: ${API_HOST}
      CSRF_COOKIE_DOMAIN: ""
      SESSION_COOKIE_DOMAIN: ""
      MESH_USER: ${MESH_USER}
      MESH_HOST: ${MESH_HOST}
      TRMM_USER: ${TRMM_USER}
      TRMM_PASS: ${TRMM_PASS}
      TRMM_DISABLE_WEB_TERMINAL: "False"
      TRMM_DISABLE_SERVER_SCRIPTS: "False"
      TRMM_DISABLE_SSO: "False"
    depends_on:
      - tactical-postgres
      - tactical-meshcentral
      - tactical-redis
    networks:
      - trmm-api-db
      - trmm-net
      - trmm-redis
    volumes:
      - tactical_data:/opt/tactical
      - mesh_data:/meshcentral-data
      - mongo_data:/mongo/data/db
      - redis_data:/redis/data

  tactical-nats:
    container_name: trmm-nats
    image: ${IMAGE_REPO}tactical-nats:${VERSION}
    user: 1000:1000
    restart: always
    environment:
      API_HOST: ${API_HOST}
    ports:
      - "4222:4222"
    volumes:
      - tactical_data:/opt/tactical
    networks:
      trmm-api-db: null
      trmm-net:
        aliases:
          - ${API_HOST}

  tactical-frontend:
    container_name: trmm-frontend
    image: ${IMAGE_REPO}tactical-frontend:${VERSION}
    user: 1000:1000
    restart: always
    networks:
      - trmm-net
    volumes:
      - tactical_data:/opt/tactical
    environment:
      API_HOST: ${API_HOST}

  tactical-backend:
    container_name: trmm-backend
    image: ${IMAGE_REPO}tactical:${VERSION}
    user: 1000:1000
    command: ["tactical-backend"]
    restart: always
    networks:
      - trmm-net
      - trmm-api-db
      - trmm-redis
    volumes:
      - tactical_data:/opt/tactical
    depends_on:
      - tactical-postgres

  tactical-websockets:
    container_name: trmm-websockets
    image: ${IMAGE_REPO}tactical:${VERSION}
    user: 1000:1000
    command: ["tactical-websockets"]
    restart: always
    networks:
      - trmm-net
      - trmm-api-db
      - trmm-redis
    volumes:
      - tactical_data:/opt/tactical
    depends_on:
      - tactical-postgres
      - tactical-backend

  tactical-celery:
    container_name: trmm-celery
    image: ${IMAGE_REPO}tactical:${VERSION}
    user: 1000:1000
    command: ["tactical-celery"]
    restart: always
    networks:
      - trmm-redis
      - trmm-net
      - trmm-api-db
    volumes:
      - tactical_data:/opt/tactical
    depends_on:
      - tactical-postgres
      - tactical-redis

  tactical-celerybeat:
    container_name: trmm-celerybeat
    image: ${IMAGE_REPO}tactical:${VERSION}
    user: 1000:1000
    command: ["tactical-celerybeat"]
    restart: always
    networks:
      - trmm-net
      - trmm-redis
      - trmm-api-db
    volumes:
      - tactical_data:/opt/tactical
    depends_on:
      - tactical-postgres
      - tactical-redis

  # HTTP only on 8181 — SSL terminated upstream by NPM Plus
  tactical-nginx:
    container_name: trmm-nginx
    image: ${IMAGE_REPO}tactical-nginx:${VERSION}
    user: 1000:1000
    restart: always
    environment:
      APP_HOST: ${APP_HOST}
      API_HOST: ${API_HOST}
      MESH_HOST: ${MESH_HOST}
      CERT_PUB_KEY: ""
      CERT_PRIV_KEY: ""
    networks:
      trmm-net:
        ipv4_address: 172.23.0.20
      proxy-net: null
    ports:
      - "8181:8080"
    volumes:
      - tactical_data:/opt/tactical
COMPOSEEOF

# ── Pull and start ────────────────────────────────────────────────────────────
echo "Pulling images from Docker Hub..."
docker compose -f "${DIR}/docker-compose.yml" --env-file "${DIR}/.env" pull

echo "Starting dependencies..."
docker compose -f "${DIR}/docker-compose.yml" --env-file "${DIR}/.env" up -d \
  tactical-postgres tactical-redis tactical-mongodb tactical-meshcentral

echo "Waiting 15s for dependencies to be ready..."
sleep 15

echo "Running tactical-init..."
docker compose -f "${DIR}/docker-compose.yml" --env-file "${DIR}/.env" run --rm tactical-init

echo "Starting full stack..."
docker compose -f "${DIR}/docker-compose.yml" --env-file "${DIR}/.env" up -d

echo ""
echo "Done. trmm-nginx is reachable from NPM Plus on proxy-net as trmm-nginx:8080"
echo ""
echo "In NPM Plus (http://localhost:81), add 3 proxy hosts:"
echo "  ${APP_HOST}  → http  trmm-nginx  8080   SSL: *.nextlevelinfo.com.br wildcard"
echo "  ${API_HOST}  → http  trmm-nginx  8080   SSL: *.nextlevelinfo.com.br wildcard"
echo "  ${MESH_HOST} → http  trmm-nginx  8080   SSL: *.nextlevelinfo.com.br wildcard"
echo ""
echo "Advanced tab (all 3) — paste:"
echo '  proxy_http_version 1.1;'
echo '  proxy_set_header Upgrade $http_upgrade;'
echo '  proxy_set_header Connection "upgrade";'
echo '  proxy_set_header Host $host;'
echo '  proxy_set_header X-Real-IP $remote_addr;'
echo '  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
echo '  proxy_set_header X-Forwarded-Proto $scheme;'
echo ""
echo "NATS: agents connect to ${API_HOST}:4222 (direct, already exposed)"
echo "Login: https://${APP_HOST}  user=${TRMM_USER}"
