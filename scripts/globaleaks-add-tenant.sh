#!/usr/bin/env bash
# globaleaks-add-tenant.sh — Deploy an isolated GlobaLeaks instance for a tenant.
#
# Usage: sudo bash globaleaks-add-tenant.sh <tenant-slug>
# Example: sudo bash globaleaks-add-tenant.sh acme
#
# What this does:
#   1. Auto-picks the next free /24 in 172.21.0.0/16
#   2. Creates an isolated Docker network: gl-<tenant>-net
#   3. Deploys globaleaks-<tenant> container on that network
#   4. Hot-connects NPM Plus to the network (no npm restart)
#   5. Prints the NPM Plus proxy host config to add manually
#
# Each tenant is fully isolated — no network path to Zammad or other tenants.
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-slug>}"
TENANT="${TENANT,,}"                      # lowercase
TENANT="${TENANT//[^a-z0-9-]/}"          # strip invalid chars

if [[ -z "${TENANT}" ]]; then
  echo "ERROR: tenant slug must contain at least one alphanumeric character" >&2
  exit 1
fi

NET="gl-${TENANT}-net"
CONTAINER="globaleaks-${TENANT}"
VOLUME="gl-${TENANT}-data"
DIR="/opt/globaleaks-${TENANT}"

# ── Idempotency check ────────────────────────────────────────────────────────
if docker network inspect "${NET}" &>/dev/null; then
  echo "Network ${NET} already exists — is this tenant already deployed?"
  echo "To redeploy: docker compose -f ${DIR}/docker-compose.yml up -d"
  exit 0
fi

# ── Auto-allocate next /24 in 172.21.0.0/16 ─────────────────────────────────
# Scans existing gl-* networks, takes the highest third-octet, adds 1.
# Starts at 172.21.1.0/24 (reserve .0 as the block identifier).
next_octet() {
  local max=0
  while IFS= read -r net; do
    local subnet
    subnet=$(docker network inspect "${net}" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    local octet
    octet=$(echo "${subnet}" | grep -oP '172\.21\.\K\d+(?=\.0/)' || true)
    [[ -n "${octet}" && "${octet}" -gt "${max}" ]] && max="${octet}"
  done < <(docker network ls --format '{{.Name}}' | grep '^gl-' || true)
  echo $((max + 1))
}

N=$(next_octet)
SUBNET="172.21.${N}.0/24"

echo "Deploying GlobaLeaks for tenant: ${TENANT}"
echo "  Network:   ${NET} (${SUBNET})"
echo "  Container: ${CONTAINER}"
echo "  Data:      ${VOLUME}"
echo "  Dir:       ${DIR}"
echo ""

# ── Create isolated network ──────────────────────────────────────────────────
docker network create --driver bridge --subnet "${SUBNET}" "${NET}"

# ── Write compose file ───────────────────────────────────────────────────────
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

# ── Deploy container ─────────────────────────────────────────────────────────
docker compose -f "${DIR}/docker-compose.yml" pull
docker compose -f "${DIR}/docker-compose.yml" up -d

# ── Hot-connect NPM Plus (no restart) ───────────────────────────────────────
if docker inspect npm &>/dev/null; then
  docker network connect "${NET}" npm
  echo "NPM Plus connected to ${NET} (no restart needed)."
else
  echo "WARNING: npm container not found. Connect manually after npm is running:"
  echo "  docker network connect ${NET} npm"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Done. Add a proxy host in NPM Plus (http://localhost:81):"
echo "  Domain:   <tenant-domain>"
echo "  Scheme:   http"
echo "  Hostname: ${CONTAINER}"
echo "  Port:     8083"
echo "  SSL:      enable, request Let's Encrypt"
echo ""
echo "To remove this tenant:"
echo "  docker compose -f ${DIR}/docker-compose.yml down"
echo "  docker network disconnect ${NET} npm"
echo "  docker network rm ${NET}"
echo "  rm -rf ${DIR}"
echo "  # Volume ${VOLUME} is kept — remove manually if needed: docker volume rm ${VOLUME}"
