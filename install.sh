#!/usr/bin/env bash
#
# August West — client device install script
# ============================================
# Target: fresh Ubuntu 24.04/26.04 LTS server (amd64), run as root.
# Builds the self-hosted stack that replaces iCloud/Google services:
#   - Immich        (photos)      -> 127.0.0.1:2283
#   - Vaultwarden   (passwords)   -> 127.0.0.1:8443
#   - Nextcloud     (files)       -> 127.0.0.1:8080
#   - Home Assistant(smart home)  -> 127.0.0.1:8123
#
# NETWORK MODEL
#   External HTTPS is provided by a Cloudflare Tunnel (cloudflared), configured
#   MANUALLY after this script runs. Tailscale/Headscale provides LAN-style
#   access. Therefore every service port is published on 127.0.0.1 ONLY.
#   Rationale: Docker's port publishing writes iptables rules that BYPASS UFW,
#   so binding to 0.0.0.0 would expose services to the public internet even with
#   `ufw default deny incoming`. Binding to 127.0.0.1 is safe-by-default and is
#   exactly what cloudflared connects to.
#
#   To later expose a service directly to Tailscale/LAN clients, change its
#   published port from `127.0.0.1:PORT:PORT` to `TAILSCALE_IP:PORT:PORT`
#   (never 0.0.0.0) and redeploy.
#
#   UFW opens ONLY 22 (SSH), 80 + 443 (reserved for cloudflared) to the public.
#
# Generated secrets are written to /root/augustwest-credentials.txt (chmod 600).
#
# This script is idempotent-ish but intended for a fresh host. Read before rerun.
set -euo pipefail

# ---------------------------------------------------------------------------
# Step 0a — interactive prompts for required identity values
#   CUSTOMER / PROVISION_TOKEN are required later (Step 5 trusted-domain,
#   Step 8 registration) and previously failed hard via `:?` if unset. Prompt
#   for them here when attached to a TTY so an operator can run this script by
#   hand; non-interactive/CI runs must still export both or the `:?` guards
#   below fail fast exactly as before.
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
  if [ -z "${CUSTOMER:-}" ]; then
    read -r -p "Enter customer name (e.g. smith, jones): " CUSTOMER
  fi
  if [ -z "${PROVISION_TOKEN:-}" ]; then
    read -r -s -p "Enter August West provisioning token: " PROVISION_TOKEN
    echo
  fi
fi

# ---------------------------------------------------------------------------
# Step 0 — scaffolding
# ---------------------------------------------------------------------------
mkdir -p /opt/augustwest/{immich,vaultwarden,nextcloud,homeassistant}

# ---------------------------------------------------------------------------
# Step 0b — swap (4 GB) : host has ~3.7 GB RAM, stack is memory-hungry
# ---------------------------------------------------------------------------
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

# ---------------------------------------------------------------------------
# Step 1 — Docker Engine + Compose plugin (official convenience script)
#   Skip the install entirely if Docker is already present — the get.docker.com
#   convenience script otherwise prints a warning and sleeps 20s before doing a
#   no-op reinstall.
# ---------------------------------------------------------------------------
if docker --version >/dev/null 2>&1; then
  echo "Docker already installed, skipping"
else
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi
systemctl enable --now docker
docker --version
docker compose version

# ---------------------------------------------------------------------------
# Step 2 — UFW firewall
#   Public exposure: 22 (SSH), 80 + 443 (reserved for cloudflared tunnel).
#   NOTE: original spec also listed 2283/8443, but services bind to 127.0.0.1
#   only and are reached via Cloudflare Tunnel / Tailscale, so those ports are
#   intentionally NOT opened publicly (they'd be dead rules + contradict the
#   "service ports via Tailscale only" model).
# ---------------------------------------------------------------------------
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'cloudflared / ACME'
ufw allow 443/tcp  comment 'cloudflared HTTPS'
ufw --force enable
ufw status verbose

# ---------------------------------------------------------------------------
# Step 2b — secrets: generate ONCE, then REUSE on every re-run.
#   The database data dirs are bind mounts (Immich Postgres ./postgres,
#   Nextcloud MariaDB ./db) that SURVIVE `docker compose down -v` — that flag
#   removes only *named* volumes, never bind mounts. Postgres/MariaDB apply their
#   password env vars ONLY at first init on an empty data dir; on an already-
#   initialized cluster the env var is ignored. So if a re-run regenerated the
#   passwords (as this script used to), config would desync from the on-disk
#   cluster and the container would crash-loop on "password authentication
#   failed for user postgres". Persisting the secrets in a sourceable store keeps
#   every subsequent run consistent with whatever is already on disk.
# ---------------------------------------------------------------------------
CRED=/root/augustwest-credentials.txt
SECRETS=/etc/augustwest/secrets.env
install -d -m 700 /etc/augustwest
umask 077
# shellcheck disable=SC1090
[ -f "$SECRETS" ] && . "$SECRETS"
# keep $1 if already set & non-empty (from a prior run), else run the generator
gen() { local var=$1; shift; [ -n "${!var:-}" ] || printf -v "$var" '%s' "$("$@")"; }
_hex() { openssl rand -hex 24; }
_pw()  { openssl rand -base64 18 | tr -d '/+=' | head -c 20; }
_tok() { openssl rand -base64 36 | tr -d '/+='; }
gen IMMICH_DB_PASSWORD       _hex
gen NEXTCLOUD_DB_ROOT        _hex
gen NEXTCLOUD_DB_PASSWORD    _hex
gen NEXTCLOUD_ADMIN_PASSWORD _pw
gen VW_ADMIN_TOKEN           _tok
gen RESTIC_PASSWORD          _tok
# authoritative, sourceable store consulted by future re-runs (values are
# [A-Za-z0-9] only, so single-quoting is safe)
cat > "$SECRETS" <<EOF
IMMICH_DB_PASSWORD='${IMMICH_DB_PASSWORD}'
NEXTCLOUD_DB_ROOT='${NEXTCLOUD_DB_ROOT}'
NEXTCLOUD_DB_PASSWORD='${NEXTCLOUD_DB_PASSWORD}'
NEXTCLOUD_ADMIN_PASSWORD='${NEXTCLOUD_ADMIN_PASSWORD}'
VW_ADMIN_TOKEN='${VW_ADMIN_TOKEN}'
RESTIC_PASSWORD='${RESTIC_PASSWORD}'
EOF
chmod 600 "$SECRETS"
cat > "$CRED" <<EOF
# August West credentials (chmod 600) — host: $(hostname)
[Immich]        DB_PASSWORD=$IMMICH_DB_PASSWORD
[Nextcloud]     MYSQL_ROOT_PASSWORD=$NEXTCLOUD_DB_ROOT  MYSQL_PASSWORD=$NEXTCLOUD_DB_PASSWORD  ADMIN_USER=admin  ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD
[Vaultwarden]   ADMIN_TOKEN=$VW_ADMIN_TOKEN
[Restic]        RESTIC_PASSWORD=$RESTIC_PASSWORD  (B2 repo config in /etc/augustwest/backup.env)
EOF
chmod 600 "$CRED"

# ---------------------------------------------------------------------------
# Step 3 — Immich (photos) -> 127.0.0.1:2283
# ---------------------------------------------------------------------------
cd /opt/augustwest/immich
curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
curl -fsSL -o .env         https://github.com/immich-app/immich/releases/latest/download/example.env
sed -i "s|- '2283:2283'|- '127.0.0.1:2283:2283'|" docker-compose.yml   # loopback only
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${IMMICH_DB_PASSWORD}|" .env
grep -q '^TZ=' .env && sed -i "s|^TZ=.*|TZ=$(cat /etc/timezone 2>/dev/null||echo Etc/UTC)|" .env
docker compose pull -q && docker compose up -d

# Guard: Postgres bakes its password in at first init only (see Step 2b). On a
# fresh host ./postgres is empty and inits with DB_PASSWORD above. If a leftover
# cluster is present whose password differs (e.g. a stale ./postgres whose secret
# was lost), assert it now with a clear remedy instead of leaving a crash-loop.
if [ -f postgres/PG_VERSION ]; then
  for _ in $(seq 1 30); do docker exec immich_postgres pg_isready -q 2>/dev/null && break; sleep 2; done
  if ! docker exec -e PGPASSWORD="${IMMICH_DB_PASSWORD}" immich_postgres \
         psql -h 127.0.0.1 -U postgres -d immich -tAc 'select 1' >/dev/null 2>&1; then
    cat >&2 <<MSG
FATAL: Immich Postgres rejects the configured DB_PASSWORD.
  The existing cluster in $(pwd)/postgres was initialized with a different password.
  If it holds no data you need:   docker compose down && rm -rf postgres && docker compose up -d
  To keep the data, align the cluster password to the one in .env:
    docker exec -i immich_postgres psql -U postgres \\
      -c "ALTER USER postgres PASSWORD '${IMMICH_DB_PASSWORD}';"
MSG
    exit 1
  fi
fi
# health: curl http://127.0.0.1:2283/api/server/ping  -> {"res":"pong"}
cd /root

# ---------------------------------------------------------------------------
# Step 4 — Vaultwarden (passwords) -> 127.0.0.1:8443
#   Leave DOMAIN UNSET (empty string is rejected); set it to the full https://
#   tunnel URL once known. SIGNUPS_ALLOWED=true for onboarding -> flip to false.
# ---------------------------------------------------------------------------
cat > /opt/augustwest/vaultwarden/docker-compose.yml <<EOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      SIGNUPS_ALLOWED: "true"
      ADMIN_TOKEN: "${VW_ADMIN_TOKEN}"
      ROCKET_PORT: "80"
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:8443:80"
EOF
cd /opt/augustwest/vaultwarden && docker compose pull -q && docker compose up -d
# health: curl http://127.0.0.1:8443/alive  -> ISO timestamp
cd /root

# ---------------------------------------------------------------------------
# Step 5 — Nextcloud (files) -> 127.0.0.1:8080   [Nextcloud + MariaDB + Redis]
# ---------------------------------------------------------------------------
# `|| true`: don't let a missing default route (pipefail) abort the install; an
# empty HOST_IP just drops out of the trusted-domains list below.
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
cat > /opt/augustwest/nextcloud/docker-compose.yml <<EOF
services:
  db:
    image: mariadb:11
    container_name: nextcloud_db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment:
      MARIADB_ROOT_PASSWORD: "${NEXTCLOUD_DB_ROOT}"
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: "${NEXTCLOUD_DB_PASSWORD}"
    volumes: [ "./db:/var/lib/mysql" ]
  redis:
    image: redis:7-alpine
    container_name: nextcloud_redis
    restart: unless-stopped
  app:
    image: nextcloud:apache
    container_name: nextcloud_app
    restart: unless-stopped
    depends_on: [db, redis]
    ports: [ "127.0.0.1:8080:80" ]
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASSWORD}"
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: "${NEXTCLOUD_ADMIN_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "localhost 127.0.0.1 ${HOST_IP}"
      # behind cloudflared later: also set OVERWRITEPROTOCOL=https + TRUSTED_PROXIES
    volumes: [ "./html:/var/www/html" ]
EOF
cd /opt/augustwest/nextcloud && docker compose pull -q && docker compose up -d
# health: curl http://127.0.0.1:8080/status.php  -> {"installed":true,...}

# Trust the customer's public (Cloudflare Tunnel) hostname. Without this,
# Nextcloud rejects requests whose Host is files-<customer>.augustwest.org with
# "Trusted domain error" (HTTP 400) and the files monitor stays DOWN. occ only
# works once first-run install has finished, so wait for status.php to report
# installed:true before setting it (index 2 -> the public host).
: "${CUSTOMER:?set CUSTOMER (August West customer slug)}"
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8080/status.php 2>/dev/null | grep -q '"installed":true' && break
  sleep 5
done
docker exec -u www-data nextcloud_app php occ config:system:set \
  trusted_domains 2 --value="files-${CUSTOMER}.augustwest.org"
cd /root

# ---------------------------------------------------------------------------
# Step 6 — Home Assistant (smart home) -> 127.0.0.1:8123
#   Bridge net + loopback bind (localhost-only model). For LAN device
#   auto-discovery switch to network_mode: host later.
# ---------------------------------------------------------------------------
cat > /opt/augustwest/homeassistant/docker-compose.yml <<EOF
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    environment:
      TZ: "$(cat /etc/timezone 2>/dev/null||echo Etc/UTC)"
    volumes:
      - ./config:/config
      - /run/dbus:/run/dbus:ro
    ports: [ "127.0.0.1:8123:8123" ]
EOF
# Home Assistant reads /config/configuration.yaml — that is the bind-mounted
# ./config dir above, i.e. host path /opt/augustwest/homeassistant/config/
# (NOT /opt/augustwest/homeassistant/configuration.yaml). Write it BEFORE the
# first start so HA trusts the cloudflared reverse proxy from the outset;
# otherwise HA answers forwarded requests with "400: Bad Request" (surfacing as
# HTTP 502 at the tunnel) and the smarthome monitor stays DOWN. default_config:
# preserves the normal HA setup (UI, onboarding, integrations).
#
# trusted_proxies must include whatever bridge gateway cloudflared connects
# from. Docker assigns bridge-network gateways non-deterministically (172.17/
# 172.18/172.21/... depending on network creation order), so pinning ONE IP is
# fragile -- a differently-numbered gateway leaves HA rejecting every forwarded
# request. Trust the whole Docker private bridge range (172.16.0.0/12) instead,
# which covers every gateway Docker can hand out.
mkdir -p /opt/augustwest/homeassistant/config
cat > /opt/augustwest/homeassistant/config/configuration.yaml <<'EOF'
default_config:

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
    - 172.16.0.0/12
EOF
cd /opt/augustwest/homeassistant && docker compose pull -q && docker compose up -d
# health: curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/  -> 302
cd /root

# ---------------------------------------------------------------------------
# Step 6a — onboarding wizard (August West setup UI) -> 127.0.0.1:8888
#   Runs as a container built from /opt/augustwest/onboarding (shipped alongside
#   this script). The wizard's first screen is a health gate and its account
#   step calls each service's API, so wait until all four answer their health
#   checks before starting it. Loopback-only, like every other service; the
#   Cloudflare Tunnel's setup-<customer_domain> route (added in Step 6b) is what
#   exposes it. restart: unless-stopped keeps it up across reboots.
# ---------------------------------------------------------------------------
ONBOARD_DIR=/opt/augustwest/onboarding
if [ -f "$ONBOARD_DIR/docker-compose.yml" ]; then
  echo "Waiting for all four services to become healthy before starting the wizard..."
  healthy=0
  for _ in $(seq 1 60); do
    healthy=0
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:2283/api/server/ping; then healthy=$((healthy+1)); fi
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8443/alive;          then healthy=$((healthy+1)); fi
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/status.php;      then healthy=$((healthy+1)); fi
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8123/manifest.json;   then healthy=$((healthy+1)); fi
    [ "$healthy" -eq 4 ] && break
    sleep 5
  done
  if [ "$healthy" -ne 4 ]; then
    echo "WARNING: only ${healthy}/4 services healthy after waiting; starting the wizard anyway (it re-checks health on load)." >&2
  fi
  ( cd "$ONBOARD_DIR" && docker compose up -d --build )
  echo "Onboarding wizard container started (127.0.0.1:8888)."
else
  echo "WARNING: $ONBOARD_DIR/docker-compose.yml not found — onboarding wizard NOT deployed." >&2
  echo "         Ship the onboarding/ directory alongside this script to enable it." >&2
fi

# ---------------------------------------------------------------------------
# Step 6b — public access via Cloudflare Tunnel
#   Exposes the local services to the internet over a per-customer named tunnel:
#     photos./vault./files./home./setup.<customer_domain>
#   Ports 2283/8443/8080/8123/8888 respectively (see aw-tunnel-setup.sh).
#
#   Requires CF_API_TOKEN (Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit) and
#   CF_ZONE_ID (the augustwest.org zone). If either is missing we SKIP tunnel
#   setup with a warning — the stack still runs (reachable via loopback/Tailscale)
#   and monitoring falls back to heartbeat-only. Provide both to go public.
# ---------------------------------------------------------------------------
: "${CUSTOMER:?set CUSTOMER (August West customer slug)}"
BASE_DOMAIN="${BASE_DOMAIN:-augustwest.org}"
CUSTOMER_DOMAIN="${CUSTOMER_DOMAIN:-${CUSTOMER}.${BASE_DOMAIN}}"
: "${CF_API_TOKEN:=}"
: "${CF_ZONE_ID:=}"

# Prompt interactively for any missing value, but only if we have a TTY. Both
# are optional -- leaving CF_API_TOKEN blank skips tunnel setup entirely (same
# as the B2 prompts below), and CF_ZONE_ID is only asked for once a token was
# actually given.
if [ -t 0 ]; then
  if [ -z "$CF_API_TOKEN" ]; then
    read -r -s -p 'Cloudflare API token (blank to skip public tunnel setup): ' CF_API_TOKEN
    echo
  fi
  if [ -n "$CF_API_TOKEN" ] && [ -z "$CF_ZONE_ID" ]; then
    read -r -p 'Cloudflare zone ID: ' CF_ZONE_ID
  fi
fi

TUNNEL_CONFIGURED=false
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
  echo "Configuring Cloudflare Tunnel for ${CUSTOMER_DOMAIN} ..."
  curl -fsSL -o /tmp/aw-tunnel-setup.sh https://augustwest.org/aw-tunnel-setup.sh
  CUSTOMER="$CUSTOMER" BASE_DOMAIN="$BASE_DOMAIN" CUSTOMER_DOMAIN="$CUSTOMER_DOMAIN" \
  CF_API_TOKEN="$CF_API_TOKEN" CF_ZONE_ID="$CF_ZONE_ID" \
    bash /tmp/aw-tunnel-setup.sh
  TUNNEL_CONFIGURED=true

  # Ensure the onboarding wizard's edge route exists. Current aw-tunnel-setup.sh
  # already writes setup-<customer_domain> -> 127.0.0.1:8888, but guard against
  # an older tunnel script that predates it: if the route is missing, inject it
  # just before the catch-all 404 rule, then re-validate + reload cloudflared.
  CF_CFG=/etc/cloudflared/config.yml
  if [ -f "$CF_CFG" ] && ! grep -q "setup-${CUSTOMER_DOMAIN}" "$CF_CFG"; then
    echo "Adding setup-${CUSTOMER_DOMAIN} route to $CF_CFG ..."
    tmp_cfg="$(mktemp)"
    awk -v host="setup-${CUSTOMER_DOMAIN}" '
      /- service: http_status:404/ && !done {
        print "  - hostname: " host
        print "    service: http://127.0.0.1:8888"
        done=1
      }
      { print }
    ' "$CF_CFG" > "$tmp_cfg" && mv "$tmp_cfg" "$CF_CFG"
    if command -v cloudflared >/dev/null 2>&1 && cloudflared --config "$CF_CFG" tunnel ingress validate; then
      systemctl restart aw-cloudflared.service 2>/dev/null || systemctl restart cloudflared 2>/dev/null || true
    else
      echo "WARNING: cloudflared rejected the edited ingress config; leaving tunnel as-is." >&2
    fi
  fi
else
  echo "WARNING: CF_API_TOKEN / CF_ZONE_ID not set — Cloudflare Tunnel NOT configured." >&2
  echo "         Services stay reachable only via loopback/Tailscale. Re-run with both" >&2
  echo "         set, or run aw-tunnel-setup.sh manually, to publish the subdomains." >&2
fi

# ---------------------------------------------------------------------------
# Step 7 — automatic security updates (unattended-upgrades)
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52augustwest-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades
unattended-upgrade --dry-run --debug   # sanity check

# ---------------------------------------------------------------------------
# Step 8 — register with August West monitoring + install heartbeat timer
#   Parameterize these (do NOT commit real tokens):
#     CUSTOMER, DEVICE_NAME, PROVISION_TOKEN
# ---------------------------------------------------------------------------
# Required — no placeholder defaults, so a device can never register under a
# throwaway identity if the operator forgets to set them. DEVICE_NAME defaults
# to the host's own name, which is a sensible, unambiguous fallback.
: "${CUSTOMER:?set CUSTOMER (August West customer slug)}"
: "${DEVICE_NAME:=$(hostname)}"
: "${PROVISION_TOKEN:?set PROVISION_TOKEN}"

# Persist the provisioning token in the sourceable secrets store so re-runs and
# the heartbeat timer can reuse it (values here are single-quoted; provisioning
# tokens are [A-Za-z0-9] only, so that is safe). Replace any prior line first.
sed -i '/^PROVISION_TOKEN=/d' "$SECRETS"
printf "PROVISION_TOKEN='%s'\n" "$PROVISION_TOKEN" >> "$SECRETS"

# When the tunnel is up, tell the provisioning API where the customer's services
# live so it creates the four per-service HTTP monitors (photos/vault/files/home)
# against https://<label>-<customer_domain>. Otherwise omit it -> heartbeat-only.
DOMAIN_FIELD=""
if [ "${TUNNEL_CONFIGURED:-false}" = true ]; then
  DOMAIN_FIELD="\"customer_domain\":\"${CUSTOMER_DOMAIN}\","
fi

RESP=$(curl -sS -X POST https://provision.augustwest.org/provision \
  -H "Authorization: Bearer ${PROVISION_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"customer\":\"${CUSTOMER}\",\"device_name\":\"${DEVICE_NAME}\",${DOMAIN_FIELD}\"hostname\":\"$(hostname)\",\"os\":\"$(. /etc/os-release; echo "$PRETTY_NAME")\",\"arch\":\"$(dpkg --print-architecture)\",\"services\":[\"immich\",\"vaultwarden\",\"nextcloud\",\"homeassistant\"]}")
echo "$RESP"
# `|| true` on each: grep exits 1 when a field is absent, and under
# `set -euo pipefail` that would abort the install *before* the INTERVAL default
# below could apply. Let them yield empty and fall back explicitly.
PUSH_URL=$(echo "$RESP" | grep -o '"push_url":"[^"]*"' | sed 's/"push_url":"//;s/"$//' || true)
INTERVAL=$(echo "$RESP" | grep -o '"interval":[0-9]*' | grep -o '[0-9]*' || true); : "${INTERVAL:=60}"
if [ -z "$PUSH_URL" ]; then
  echo "WARNING: provisioning response contained no push_url — heartbeat will have no target." >&2
  echo "  Response was: $RESP" >&2
fi

install -d -m 700 /etc/augustwest
umask 077
printf 'PUSH_URL="%s"\nINTERVAL="%s"\n' "$PUSH_URL" "$INTERVAL" > /etc/augustwest/heartbeat.env
chmod 600 /etc/augustwest/heartbeat.env

# heartbeat script (host-liveness + service summary) — see repo copy at
# /usr/local/bin/augustwest-heartbeat.sh (pushes status=up, msg=<n/4 up | ...>)
cat > /usr/local/bin/augustwest-heartbeat.sh <<'SCRIPT'
#!/usr/bin/env bash
set -u
source /etc/augustwest/heartbeat.env
BASE="${PUSH_URL%%\?*}"
up=0
chk(){ if curl -fsS -o /dev/null --max-time 5 "$2"; then up=$((up+1)); echo -n "$1:ok "; else echo -n "$1:DOWN "; fi; }
SUMMARY="$(chk immich http://127.0.0.1:2283/api/server/ping; chk vault http://127.0.0.1:8443/alive; chk nextcloud http://127.0.0.1:8080/status.php; chk ha http://127.0.0.1:8123/manifest.json)"
curl -fsS -o /dev/null --max-time 10 --get "$BASE" --data-urlencode "status=up" --data-urlencode "msg=${up}/4 up | ${SUMMARY}" --data-urlencode "ping="
SCRIPT
chmod 755 /usr/local/bin/augustwest-heartbeat.sh

cat > /etc/systemd/system/augustwest-heartbeat.service <<'EOF'
[Unit]
Description=August West monitoring heartbeat (push)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/augustwest-heartbeat.sh
EOF
cat > /etc/systemd/system/augustwest-heartbeat.timer <<EOF
[Unit]
Description=Run August West heartbeat every ${INTERVAL}s
[Timer]
OnBootSec=45
OnUnitActiveSec=${INTERVAL}
AccuracySec=5s
Unit=augustwest-heartbeat.service
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now augustwest-heartbeat.timer

# ---------------------------------------------------------------------------
# Step 8b — Restic backups of /opt/augustwest -> Backblaze B2, daily @ 03:00
#   Encryption password: RESTIC_PASSWORD (generated in Step 2b, persisted in
#   $SECRETS). Repository is Backblaze B2; its credentials must be supplied via
#   the environment (B2_ACCOUNT_ID / B2_ACCOUNT_KEY / B2_BUCKET) or entered
#   interactively below. If none are provided, backup config is SKIPPED with a
#   warning — the rest of the install is unaffected.
#
#   Retention (applied after each backup): 7 daily, 4 weekly, 12 monthly.
#   Runtime log: /var/log/augustwest-backup.log
# ---------------------------------------------------------------------------
: "${B2_ACCOUNT_ID:=}"
: "${B2_ACCOUNT_KEY:=}"
: "${B2_BUCKET:=}"

# Prompt interactively for any missing value, but only if we have a TTY.
if [ -t 0 ]; then
  [ -n "$B2_ACCOUNT_ID" ]  || read -r -p 'Backblaze B2 account/key ID (blank to skip backups): ' B2_ACCOUNT_ID
  if [ -n "$B2_ACCOUNT_ID" ]; then
    [ -n "$B2_ACCOUNT_KEY" ] || read -r -s -p 'Backblaze B2 application key: ' B2_ACCOUNT_KEY; echo
    [ -n "$B2_BUCKET" ]      || read -r -p 'Backblaze B2 bucket name: ' B2_BUCKET
  fi
fi

if [ -z "$B2_ACCOUNT_ID" ] || [ -z "$B2_ACCOUNT_KEY" ] || [ -z "$B2_BUCKET" ]; then
  echo "WARNING: B2 credentials not provided — backup is NOT configured." >&2
  echo "         Re-run with B2_ACCOUNT_ID / B2_ACCOUNT_KEY / B2_BUCKET set to enable Restic backups." >&2
else
  # restic from the distro repo (Ubuntu 24.04+ ships a recent enough version)
  if ! command -v restic >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq restic
  fi

  # Backup environment consumed by the systemd unit and manual runs. Contains
  # the B2 credentials + repo pointer + encryption password; keep it 600.
  BACKUP_ENV=/etc/augustwest/backup.env
  cat > "$BACKUP_ENV" <<EOF
RESTIC_REPOSITORY='b2:${B2_BUCKET}:augustwest-$(hostname)'
RESTIC_PASSWORD='${RESTIC_PASSWORD}'
B2_ACCOUNT_ID='${B2_ACCOUNT_ID}'
B2_ACCOUNT_KEY='${B2_ACCOUNT_KEY}'
EOF
  chmod 600 "$BACKUP_ENV"

  # Initialize the repo once (idempotent: ignore "already initialized").
  # shellcheck disable=SC1090
  set -a; . "$BACKUP_ENV"; set +a
  # Hard-fail if init fails when creds WERE provided: a bad credential should
  # stop the install rather than leave a broken backup timer behind (set -e).
  restic snapshots >/dev/null 2>&1 || restic init

  # Backup runner: back up /opt/augustwest, prune to the retention policy, all
  # output appended to the log with timestamps.
  cat > /usr/local/bin/augustwest-backup.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
LOG=/var/log/augustwest-backup.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) augustwest backup start ==="
set -a; . /etc/augustwest/backup.env; set +a
restic backup /opt/augustwest --tag augustwest
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 12
echo "=== $(date -Is) augustwest backup done ==="
SCRIPT
  chmod 755 /usr/local/bin/augustwest-backup.sh
  touch /var/log/augustwest-backup.log
  chmod 600 /var/log/augustwest-backup.log

  cat > /etc/systemd/system/augustwest-backup.service <<'EOF'
[Unit]
Description=August West Restic backup of /opt/augustwest to Backblaze B2
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/augustwest-backup.sh
EOF
  cat > /etc/systemd/system/augustwest-backup.timer <<'EOF'
[Unit]
Description=Run August West Restic backup daily at 03:00
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
AccuracySec=1min
Unit=augustwest-backup.service
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now augustwest-backup.timer
  echo "Restic backups configured: daily @ 03:00 -> b2:${B2_BUCKET}:augustwest-$(hostname) (log: /var/log/augustwest-backup.log)"
fi

# ---------------------------------------------------------------------------
# Step 9 — completion summary + onboarding wizard hand-off
#   Print the setup URL (and a scannable QR) the customer opens to run the
#   wizard. The wizard mints its one-time setup token on first access, so poke a
#   protected endpoint once to force token creation, then read it. The token is
#   passed in the URL as ?t=... (the frontend stores it and strips it from the
#   address bar).
# ---------------------------------------------------------------------------
echo "Install complete. Credentials in /root/augustwest-credentials.txt"

if [ -f "$ONBOARD_DIR/docker-compose.yml" ]; then
  # Force the wizard to create its setup token (any authenticated route triggers
  # it; the 403 we get back is expected and harmless).
  curl -fsS -o /dev/null --max-time 5 -H 'X-Setup-Token: bootstrap' \
    http://127.0.0.1:8888/api/state 2>/dev/null || true
  SETUP_TOKEN="$(cat /etc/augustwest/onboarding_token 2>/dev/null || true)"

  if [ "${TUNNEL_CONFIGURED:-false}" = true ]; then
    SETUP_URL="https://setup-${CUSTOMER_DOMAIN}/?t=${SETUP_TOKEN}"
  else
    # No public tunnel: the wizard binds loopback only, so it's reached over
    # Tailscale or an SSH tunnel (ssh -L 8888:127.0.0.1:8888 root@<host>).
    SETUP_URL="http://127.0.0.1:8888/?t=${SETUP_TOKEN}"
  fi

  echo
  echo "==============================================================="
  echo " August West setup wizard"
  echo "==============================================================="
  echo " Open this on the customer's phone or laptop to finish setup:"
  echo
  echo "   ${SETUP_URL}"
  echo
  if [ "${TUNNEL_CONFIGURED:-false}" != true ]; then
    echo " (loopback-only until the tunnel is set up — reach it via Tailscale"
    echo "  or:  ssh -L 8888:127.0.0.1:8888 root@$(hostname -I 2>/dev/null | awk '{print $1}'))"
    echo
  fi
  # Scannable QR, rendered in-terminal via the wizard image's bundled qrcode
  # library (no extra host package needed).
  docker exec augustwest_onboarding python -c \
    "import qrcode,sys; qr=qrcode.QRCode(border=1); qr.add_data(sys.argv[1]); qr.make(); qr.print_ascii(invert=True)" \
    "$SETUP_URL" 2>/dev/null \
    || echo " (install 'qrencode' or open the URL above to view the QR code)"
  echo "==============================================================="
fi
