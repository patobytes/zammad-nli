#!/usr/bin/env bash
# cpanel-dns-update.sh — Create or update TRMM DNS A records via cPanel UAPI.
# Reads credentials from Azure Key Vault (kv-zmd-brs).
# Safe to re-run: updates records if they already exist.
#
# Prerequisites on the VM:
#   - az CLI authenticated (az login --use-device-code)
#   - curl, jq
#
# Usage:
#   sudo bash /opt/scripts/cpanel-dns-update.sh
#
# To override the target IP (default: fetched from Azure):
#   TARGET_IP=1.2.3.4 sudo bash /opt/scripts/cpanel-dns-update.sh
set -euo pipefail

KV="kv-zmd-brs"
ZONE="nextlevelinfo.com.br"
SUBDOMAINS=("rmm" "api-rmm" "mesh")
TTL=300

# ── Fetch cPanel credentials from Key Vault ────────────────────────────────────
echo "Fetching cPanel credentials from Key Vault ${KV}..."
CPANEL_HOST=$(az keyvault secret show --vault-name "$KV" --name cpanel-host     --query value -o tsv)
CPANEL_USER=$(az keyvault secret show --vault-name "$KV" --name cpanel-username --query value -o tsv)
CPANEL_TOKEN=$(az keyvault secret show --vault-name "$KV" --name cpanel-api-token --query value -o tsv)

# ── Resolve target IP ─────────────────────────────────────────────────────────
if [[ -z "${TARGET_IP:-}" ]]; then
  echo "Fetching VM public IP from Azure..."
  TARGET_IP=$(az vm list-ip-addresses \
    --resource-group rg-zmd-brs \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
    -o tsv)
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
