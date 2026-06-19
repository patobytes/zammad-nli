#!/usr/bin/env bash
# cpanel-dns-update.sh — Create or update TRMM DNS A records via cPanel UAPI.
# Reads credentials from Azure Key Vault (kv-zmd-brs) using the VM's Managed Identity.
# No az CLI required — uses IMDS token endpoint directly.
# Safe to re-run: updates records if they already exist.
#
# Prerequisites on the VM:
#   - VM must have a system-assigned Managed Identity
#   - Identity must have "Key Vault Secrets User" role on kv-zmd-brs
#   - curl, jq
#
# Usage:
#   sudo bash /opt/scripts/cpanel-dns-update.sh
#
# To override the target IP (default: fetched from IMDS):
#   TARGET_IP=1.2.3.4 sudo bash /opt/scripts/cpanel-dns-update.sh
set -euo pipefail

KV="kv-zmd-brs"
KV_URI="https://${KV}.vault.azure.net"
ZONE="nextlevelinfo.com.br"
SUBDOMAINS=("rmm" "api-rmm" "mesh")
TTL=300

# ── Acquire Managed Identity token for Key Vault ──────────────────────────────
echo "Acquiring Managed Identity token..."
KV_TOKEN=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token')
[[ -z "$KV_TOKEN" || "$KV_TOKEN" == "null" ]] && { echo "ERROR: Could not get Managed Identity token. Is the VM identity enabled?"; exit 1; }

# ── Fetch a secret from Key Vault via REST ────────────────────────────────────
kv_secret() {
  local name="$1"
  curl -sf \
    -H "Authorization: Bearer ${KV_TOKEN}" \
    "${KV_URI}/secrets/${name}?api-version=7.4" \
    | jq -r '.value'
}

echo "Fetching cPanel credentials from Key Vault ${KV}..."
CPANEL_HOST=$(kv_secret "cpanel-host")
CPANEL_USER=$(kv_secret "cpanel-username")
CPANEL_TOKEN=$(kv_secret "cpanel-api-token")

# ── Resolve target IP ─────────────────────────────────────────────────────────
if [[ -z "${TARGET_IP:-}" ]]; then
  echo "Fetching public IP from IMDS..."
  TARGET_IP=$(curl -sf \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text")
fi
echo "Target IP: ${TARGET_IP}"

# ── cPanel UAPI helper ────────────────────────────────────────────────────────
cpanel_api() {
  local func="$1"; shift
  local params=("$@")
  local url="${CPANEL_HOST}/execute/DNS/${func}"
  local query_string=""
  for p in "${params[@]}"; do
    query_string+="&${p}"
  done
  curl -s -k \
    -H "Authorization: cpanel ${CPANEL_USER}:${CPANEL_TOKEN}" \
    "${url}?${query_string:1}"
}

# ── Fetch existing zone records ───────────────────────────────────────────────
echo "Fetching zone records for ${ZONE}..."
zone_data=$(cpanel_api "parse_zone" "zone=${ZONE}")
if ! echo "$zone_data" | jq -e '.status == 1' > /dev/null 2>&1; then
  echo "ERROR: Could not fetch zone data. Check cPanel credentials."
  echo "$zone_data" | jq .
  exit 1
fi

# ── Create or update each subdomain ──────────────────────────────────────────
for sub in "${SUBDOMAINS[@]}"; do
  fqdn="${sub}.${ZONE}."

  # Check if record already exists
  existing_line=$(echo "$zone_data" | jq -r \
    ".data[] | select(.type == \"A\" and .name == \"${fqdn}\") | .line" 2>/dev/null || true)

  if [[ -n "$existing_line" ]]; then
    echo "Updating existing A record: ${fqdn} → ${TARGET_IP} (line ${existing_line})"
    result=$(cpanel_api "edit_zone_record" \
      "zone=${ZONE}" \
      "line=${existing_line}" \
      "name=${fqdn}" \
      "type=A" \
      "ttl=${TTL}" \
      "address=${TARGET_IP}")
  else
    echo "Creating new A record: ${fqdn} → ${TARGET_IP}"
    result=$(cpanel_api "add_zone_record" \
      "zone=${ZONE}" \
      "name=${sub}" \
      "type=A" \
      "ttl=${TTL}" \
      "address=${TARGET_IP}")
  fi

  if echo "$result" | jq -e '.status == 1' > /dev/null 2>&1; then
    echo "  ✓ ${fqdn}"
  else
    echo "  ✗ Failed for ${fqdn}:"
    echo "$result" | jq .
    exit 1
  fi
done

echo ""
echo "DNS updated. Records may take up to ${TTL}s to propagate."
echo "Verify with: dig +short rmm.${ZONE} api-rmm.${ZONE} mesh.${ZONE}"
