#!/usr/bin/env bash
# npm-add-redirect.sh — create a redirection host in NPM Plus (create-only, idempotent).
# Talks to the local NPM Plus API (127.0.0.1:81) on the box that hosts it.
#
# Usage:
#   sudo bash /opt/scripts/npm-add-redirect.sh <npm-identity> <npm-secret> <from-domain> <to-domain> [http-code]
#
# Example:
#   sudo bash /opt/scripts/npm-add-redirect.sh admin@example.com 'S3cr3t!' \
#     chamados.nextlevelinfo.com.br tickets.nextlevelinfo.com.br 301
#
# Reuses whichever certificate NPM Plus already has covering the target domain
# suffix (matched by --domain-suffix, default nextlevelinfo.com.br) -- does not
# request a new Let's Encrypt certificate.
set -euo pipefail

DOMAIN_SUFFIX="nextlevelinfo.com.br"
NPM_API="${NPM_API:-http://localhost:81/api}"

die() { echo "ERROR: $*" >&2; exit 1; }

NPM_IDENTITY="${1:?usage: npm-add-redirect.sh <npm-identity> <npm-secret> <from-domain> <to-domain> [http-code]}"
NPM_SECRET="${2:?usage: npm-add-redirect.sh <npm-identity> <npm-secret> <from-domain> <to-domain> [http-code]}"
FROM="${3:?usage: npm-add-redirect.sh <npm-identity> <npm-secret> <from-domain> <to-domain> [http-code]}"
TO="${4:?usage: npm-add-redirect.sh <npm-identity> <npm-secret> <from-domain> <to-domain> [http-code]}"
CODE="${5:-301}"

command -v jq >/dev/null || die "jq required"

COOKIE=$(mktemp)
trap 'rm -f "$COOKIE"' EXIT

npm_curl() { curl -sf -b "$COOKIE" "$@"; }

echo "Logging in to NPM Plus API..."
curl -sf -c "$COOKIE" -X POST "$NPM_API/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"$NPM_IDENTITY\",\"secret\":\"$NPM_SECRET\"}" -o /dev/null \
  || die "login failed -- check identity/secret"

if npm_curl "$NPM_API/nginx/redirection-hosts" \
    | jq -e --arg d "$FROM" 'any(.[]; .domain_names | index($d))' >/dev/null 2>&1; then
  echo "Redirection host for $FROM already exists -- nothing to do (create-only)."
  exit 0
fi

echo "Looking up a certificate covering ${DOMAIN_SUFFIX}..."
CERT_ID=$(npm_curl "$NPM_API/nginx/certificates" \
  | jq -r --arg suf "$DOMAIN_SUFFIX" '[.[] | select(.domain_names[]? | endswith($suf))][0].id // empty')
[ -n "$CERT_ID" ] || die "no certificate found covering ${DOMAIN_SUFFIX} in NPM Plus"

echo "Creating redirection host: $FROM -> $TO (HTTP $CODE, cert id $CERT_ID)"
PAYLOAD=$(jq -n \
  --arg from "$FROM" --arg to "$TO" --argjson code "$CODE" --argjson cert "$CERT_ID" \
  '{domain_names:[$from],forward_scheme:"https",forward_domain_name:$to,forward_http_code:$code,preserve_path:true,certificate_id:$cert,ssl_forced:true,http2_support:true,hsts_enabled:false,block_exploits:true,advanced_config:""}')

RESP=$(npm_curl -X POST "$NPM_API/nginx/redirection-hosts" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "$RESP" | jq -e '.id' >/dev/null 2>&1 || die "NPM Plus rejected the request: $RESP"

echo "Done. $FROM now redirects to $TO."
echo "Verify: curl -I https://$FROM"
