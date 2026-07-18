#!/usr/bin/env bash
#
# August West — customer edge tunnel setup
# =========================================
# Runs on a customer device AFTER the self-hosted stack is up. It exposes the
# local services to the public internet over a per-customer Cloudflare Tunnel.
#
# Hosts are SINGLE-level ("<label>-<customer_domain>") so Cloudflare Universal
# SSL's *.augustwest.org wildcard covers them. A two-level host such as
# photos.<customer>.augustwest.org is NOT covered by Universal SSL and fails the
# edge TLS handshake, so we hyphenate the label into a single DNS label instead:
#
#   photos-<customer_domain>  -> http://127.0.0.1:2283   (Immich)
#   vault-<customer_domain>   -> http://127.0.0.1:8443   (Vaultwarden)
#   files-<customer_domain>   -> http://127.0.0.1:8080   (Nextcloud)
#   home-<customer_domain>    -> http://127.0.0.1:8123   (Home Assistant)
#   setup-<customer_domain>   -> http://127.0.0.1:8888   (onboarding wizard)
#
# e.g. with CUSTOMER_DOMAIN=smith.augustwest.org -> photos-smith.augustwest.org
#
# What it does, headlessly (no interactive `cloudflared tunnel login`):
#   1. Installs cloudflared (official .deb) if not already present.
#   2. Creates a named, locally-managed tunnel via the Cloudflare API and writes
#      its credentials file (we generate the tunnel secret, so no browser cert
#      is needed). A re-run on the SAME server reuses its tunnel; a run on a NEW
#      server that shares the CUSTOMER slug takes over — it deletes the previous
#      tunnel (whose secret it does not hold) and creates its own.
#   3. Writes /etc/cloudflared/config.yml with the five ingress rules.
#   4. Creates/updates proxied CNAMEs for each subdomain -> <id>.cfargotunnel.com
#      via the Cloudflare DNS API.
#   5. Installs + enables the aw-cloudflared systemd service.
#
# REQUIRED environment:
#   CUSTOMER        customer slug (e.g. "smith")
#   CF_API_TOKEN    Cloudflare API token with:
#                     - Zone : DNS : Edit          (for the augustwest.org zone)
#                     - Account : Cloudflare Tunnel : Edit
#   CF_ZONE_ID      Zone ID of the base domain (augustwest.org)
# OPTIONAL environment:
#   BASE_DOMAIN     default: augustwest.org
#   CUSTOMER_DOMAIN default: <CUSTOMER>.<BASE_DOMAIN>
#   TUNNEL_NAME     default: augustwest-<CUSTOMER>
#
# Idempotent: re-running on the same server converges to the same result; running
# on a new server with the same CUSTOMER re-points the tunnel + DNS to that
# server. State lives in /etc/cloudflared; Cloudflare is treated as authoritative.
set -euo pipefail

log() { echo "[aw-tunnel] $*"; }
die() { echo "[aw-tunnel] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# --- inputs -----------------------------------------------------------------
: "${CUSTOMER:?set CUSTOMER (August West customer slug)}"
: "${CF_API_TOKEN:?set CF_API_TOKEN (Cloudflare API token)}"
: "${CF_ZONE_ID:?set CF_ZONE_ID (Cloudflare zone id for the base domain)}"
BASE_DOMAIN="${BASE_DOMAIN:-augustwest.org}"
CUSTOMER_DOMAIN="${CUSTOMER_DOMAIN:-${CUSTOMER}.${BASE_DOMAIN}}"
TUNNEL_NAME="${TUNNEL_NAME:-augustwest-${CUSTOMER}}"

STATE=/etc/cloudflared
CFG="${STATE}/config.yml"
CF_API="https://api.cloudflare.com/client/v4"

# label -> local service port. Order is fixed so config.yml is deterministic.
LABELS=(photos vault files home setup)
declare -A PORTS=( [photos]=2283 [vault]=8443 [files]=8080 [home]=8123 [setup]=8888 )

install -d -m 700 "$STATE"

# --- dependencies -----------------------------------------------------------
need_pkgs=()
command -v jq      >/dev/null 2>&1 || need_pkgs+=(jq)
command -v openssl >/dev/null 2>&1 || need_pkgs+=(openssl)
command -v curl    >/dev/null 2>&1 || need_pkgs+=(curl)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
  log "installing dependencies: ${need_pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${need_pkgs[@]}"
fi

# --- cloudflared ------------------------------------------------------------
if ! command -v cloudflared >/dev/null 2>&1; then
  arch="$(dpkg --print-architecture)"   # amd64 | arm64
  log "installing cloudflared (${arch})"
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
  apt-get install -y -qq "$deb" || dpkg -i "$deb"
  rm -f "$deb"
fi
CLOUDFLARED="$(command -v cloudflared)"
log "cloudflared: $("$CLOUDFLARED" --version 2>&1 | head -1)"

# --- Cloudflare API helper --------------------------------------------------
# cf METHOD PATH [JSON_BODY] -> prints response body, fails (non-zero) if the
# API reports success=false, dumping the errors array to stderr.
cf() {
  local method="$1" path="$2" body="${3:-}" resp
  if [ -n "$body" ]; then
    resp="$(curl -sS -X "$method" "${CF_API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body")"
  else
    resp="$(curl -sS -X "$method" "${CF_API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}")"
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.success' 2>/dev/null)" != "true" ]; then
    echo "[aw-tunnel] Cloudflare API $method $path failed:" >&2
    printf '%s' "$resp" | jq -c '.errors' >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# --- account id (derived from the zone) -------------------------------------
ACCOUNT_ID="$(cf GET "/zones/${CF_ZONE_ID}" | jq -r '.result.account.id')"
[ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != null ] || die "could not resolve account id from zone ${CF_ZONE_ID}"
log "account ${ACCOUNT_ID}, domain ${CUSTOMER_DOMAIN}"

# --- ensure the tunnel exists (multi-server safe) ---------------------------
# Cloudflare is authoritative: enumerate every non-deleted tunnel that carries
# our name. A tunnel is REUSABLE only if THIS server holds its credentials file
# (i.e. this server created it). A same-name tunnel created by a *different*
# server that happens to share the CUSTOMER slug is NOT reusable here: we don't
# have its secret, so our cloudflared could never connect to it, and a DNS
# record pointing at it would serve HTTP 530. So we reuse our own tunnel if we
# find it and delete every other same-name tunnel, otherwise we create a fresh
# one this server owns. Either way exactly one tunnel ends up backing the name.
creds_match() {  # $1 = tunnel id -> true iff a matching local creds file exists
  local id="$1" f="${STATE}/${1}.json"
  [ -f "$f" ] && [ "$(jq -r '.TunnelID // empty' "$f" 2>/dev/null)" = "$id" ]
}
drop_tunnel() { # $1 = tunnel id -> drain connections then delete (best effort)
  local id="$1"
  cf DELETE "/accounts/${ACCOUNT_ID}/cfd_tunnel/${id}/connections" >/dev/null 2>&1 || true
  cf DELETE "/accounts/${ACCOUNT_ID}/cfd_tunnel/${id}"             >/dev/null 2>&1 || true
  rm -f "${STATE}/${id}.json"
}

existing_json="$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")"
mapfile -t EXISTING < <(printf '%s' "$existing_json" | jq -r '.result[].id')

TUNNEL_ID=""
for e in "${EXISTING[@]:-}"; do
  [ -n "$e" ] || continue
  if [ -z "$TUNNEL_ID" ] && creds_match "$e"; then
    TUNNEL_ID="$e"
    log "reusing tunnel ${TUNNEL_ID} (local credentials match)"
  else
    # Foreign (created by another server) or a duplicate — remove it so exactly
    # one tunnel backs this customer name and DNS can't point at a dead one.
    log "deleting stale/foreign same-name tunnel ${e}"
    drop_tunnel "$e"
  fi
done

if [ -z "$TUNNEL_ID" ]; then
  secret="$(openssl rand -base64 32)"
  create_body="$(jq -nc --arg n "$TUNNEL_NAME" --arg s "$secret" \
    '{name:$n, tunnel_secret:$s, config_src:"local"}')"
  TUNNEL_ID="$(cf POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" "$create_body" | jq -r '.result.id')"
  [ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != null ] || die "tunnel creation returned no id"

  # Locally-managed credentials file (equivalent to what `tunnel create` writes).
  jq -nc --arg a "$ACCOUNT_ID" --arg t "$TUNNEL_ID" --arg s "$secret" \
    '{AccountTag:$a, TunnelID:$t, TunnelSecret:$s}' > "${STATE}/${TUNNEL_ID}.json"
  chmod 600 "${STATE}/${TUNNEL_ID}.json"
  log "created tunnel ${TUNNEL_NAME} = ${TUNNEL_ID}"
fi

# Record the winning tunnel id and purge any other local tunnel credential
# files so on-disk state can never trigger a reuse of a superseded tunnel.
printf '%s\n' "$TUNNEL_ID" > "${STATE}/tunnel-id"
for f in "${STATE}"/*.json; do
  [ -e "$f" ] || continue
  [ "$f" = "${STATE}/${TUNNEL_ID}.json" ] && continue
  jq -e '.TunnelID and .TunnelSecret and .AccountTag' "$f" >/dev/null 2>&1 && rm -f "$f"
done

# --- ingress config ---------------------------------------------------------
{
  echo "# August West customer edge tunnel — managed by aw-tunnel-setup.sh"
  echo "tunnel: ${TUNNEL_ID}"
  echo "credentials-file: ${STATE}/${TUNNEL_ID}.json"
  echo "ingress:"
  for l in "${LABELS[@]}"; do
    echo "  - hostname: ${l}-${CUSTOMER_DOMAIN}"
    echo "    service: http://127.0.0.1:${PORTS[$l]}"
  done
  echo "  # catch-all: refuse anything else"
  echo "  - service: http_status:404"
} > "$CFG"
chmod 644 "$CFG"

"$CLOUDFLARED" --config "$CFG" tunnel ingress validate \
  || die "cloudflared rejected the generated ingress config ($CFG)"
log "wrote + validated ${CFG}"

# --- DNS CNAMEs -------------------------------------------------------------
TARGET="${TUNNEL_ID}.cfargotunnel.com"
# Force the name to a SINGLE proxied CNAME -> the current tunnel. We fetch every
# record for the exact name (any type), reuse the first CNAME (update in place)
# and delete all other records for that name. This is what guarantees a stale
# CNAME left pointing at a previous tunnel id — the classic 530 cause — cannot
# survive a re-run, even one performed from a different server.
upsert_cname() {
  local name="$1" recs keep body rid
  recs="$(cf GET "/zones/${CF_ZONE_ID}/dns_records?name=${name}&per_page=100")"
  keep="$(printf '%s' "$recs" | jq -r '[.result[] | select(.type=="CNAME")][0].id // empty')"
  for rid in $(printf '%s' "$recs" | jq -r '.result[].id'); do
    [ "$rid" = "$keep" ] && continue
    cf DELETE "/zones/${CF_ZONE_ID}/dns_records/${rid}" >/dev/null 2>&1 || true
  done
  body="$(jq -nc --arg n "$name" --arg c "$TARGET" \
            '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1}')"
  if [ -n "$keep" ]; then
    cf PUT "/zones/${CF_ZONE_ID}/dns_records/${keep}" "$body" >/dev/null
    log "  CNAME ${name} -> ${TARGET} (updated)"
  else
    cf POST "/zones/${CF_ZONE_ID}/dns_records" "$body" >/dev/null
    log "  CNAME ${name} -> ${TARGET} (created)"
  fi
}
log "configuring DNS records:"
for l in "${LABELS[@]}"; do
  upsert_cname "${l}-${CUSTOMER_DOMAIN}"
done

# --- systemd service --------------------------------------------------------
cat > /etc/systemd/system/aw-cloudflared.service <<EOF
[Unit]
Description=August West Cloudflare Tunnel (customer edge)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED} --no-autoupdate --config ${CFG} tunnel run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now aw-cloudflared.service
# Restart (not just start) so a re-run picks up an edited config.
systemctl restart aw-cloudflared.service

log "done. Tunnel ${TUNNEL_NAME} active. Public endpoints:"
for l in "${LABELS[@]}"; do
  echo "  https://${l}-${CUSTOMER_DOMAIN}  ->  127.0.0.1:${PORTS[$l]}"
done
