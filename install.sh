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
# Customer-facing progress display
#   This script is run directly by the customer, so its normal output is a clean,
#   reassuring sequence of progress messages rather than raw Docker/apt logs.
#   `say` prints a friendly step line; `run_quiet` executes a command with its
#   stdout+stderr captured to a log, surfacing the technical output ONLY if the
#   command fails (so a customer never sees noise, but a failure is still
#   debuggable). LOG holds the full technical transcript.
# ---------------------------------------------------------------------------
LOG=/var/log/augustwest-install.log
: > "$LOG" 2>/dev/null || LOG=/tmp/augustwest-install.log
: > "$LOG" 2>/dev/null || true

say()  { printf '\n\033[1;36m➤ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
note() { printf '  \033[0;33m•\033[0m %s\n' "$*"; }

# Run a command quietly: append its output to $LOG, and only echo that output to
# the screen if it fails. Returns the command's exit status.
run_quiet() {
  echo "\$ $*" >> "$LOG"
  if "$@" >> "$LOG" 2>&1; then
    return 0
  else
    local rc=$?
    printf '  \033[1;31m✗ a step reported a problem — recent detail:\033[0m\n' >&2
    tail -n 20 "$LOG" >&2
    return $rc
  fi
}

echo
echo "  Welcome to August West — setting up your private home cloud."
echo "  This takes a few minutes. You can leave it running."
echo "  (Full technical log: $LOG)"

# ---------------------------------------------------------------------------
# Step 0a — the ONE question we ask the customer: their family name.
#   Everything else (operator credentials: PROVISION_TOKEN, CF_API_TOKEN,
#   CF_ZONE_ID, B2_*) comes from the environment only and is NEVER prompted for
#   — those are August West operator secrets a customer must never see or enter.
#   Any operator credential that is absent simply disables its feature (with a
#   warning) rather than prompting or failing.
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
  if [ -z "${CUSTOMER:-}" ]; then
    read -r -p "What's your family name? (e.g. smith, jones): " CUSTOMER
  fi
fi

# ---------------------------------------------------------------------------
# Step 0 — scaffolding
# ---------------------------------------------------------------------------
say "Preparing your device..."
mkdir -p /opt/augustwest/{immich,vaultwarden,nextcloud,homeassistant}

# ---------------------------------------------------------------------------
# Step 0b — swap (4 GB) : host has ~3.7 GB RAM, stack is memory-hungry
# ---------------------------------------------------------------------------
if ! swapon --show | grep -q /swapfile; then
  run_quiet fallocate -l 4G /swapfile
  chmod 600 /swapfile
  run_quiet mkswap /swapfile
  run_quiet swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  run_quiet sysctl -w vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi
ok "Device prepared."

# ---------------------------------------------------------------------------
# Step 1 — Docker Engine + Compose plugin (official convenience script)
#   Skip the install entirely if Docker is already present — the get.docker.com
#   convenience script otherwise prints a warning and sleeps 20s before doing a
#   no-op reinstall.
# ---------------------------------------------------------------------------
say "Installing the engine that runs your apps..."
if docker --version >/dev/null 2>&1; then
  note "Engine already present."
else
  run_quiet curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  run_quiet sh /tmp/get-docker.sh
fi
run_quiet systemctl enable --now docker
run_quiet docker --version
run_quiet docker compose version
ok "Engine ready."

# ---------------------------------------------------------------------------
# Step 2 — UFW firewall
#   Public exposure: 22 (SSH), 80 + 443 (reserved for cloudflared tunnel).
#   NOTE: original spec also listed 2283/8443, but services bind to 127.0.0.1
#   only and are reached via Cloudflare Tunnel / Tailscale, so those ports are
#   intentionally NOT opened publicly (they'd be dead rules + contradict the
#   "service ports via Tailscale only" model).
# ---------------------------------------------------------------------------
say "Securing your device's firewall..."
run_quiet ufw default deny incoming
run_quiet ufw default allow outgoing
run_quiet ufw allow 22/tcp   comment 'SSH'
run_quiet ufw allow 80/tcp   comment 'cloudflared / ACME'
run_quiet ufw allow 443/tcp  comment 'cloudflared HTTPS'
run_quiet ufw --force enable
run_quiet ufw status verbose
ok "Firewall configured."

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
say "Generating your private security keys..."
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
ok "Security keys generated."

# ---------------------------------------------------------------------------
# Step 3 — Immich (photos) -> 127.0.0.1:2283
# ---------------------------------------------------------------------------
say "Setting up your Photo Vault... (this can take a couple of minutes)"
cd /opt/augustwest/immich
run_quiet curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
run_quiet curl -fsSL -o .env         https://github.com/immich-app/immich/releases/latest/download/example.env
sed -i "s|- '2283:2283'|- '127.0.0.1:2283:2283'|" docker-compose.yml   # loopback only
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${IMMICH_DB_PASSWORD}|" .env
grep -q '^TZ=' .env && sed -i "s|^TZ=.*|TZ=$(cat /etc/timezone 2>/dev/null||echo Etc/UTC)|" .env
run_quiet docker compose pull -q
run_quiet docker compose up -d

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
ok "Photo Vault ready."
cd /root

# ---------------------------------------------------------------------------
# Step 4 — Vaultwarden (passwords) -> 127.0.0.1:8443
#   Leave DOMAIN UNSET (empty string is rejected); set it to the full https://
#   tunnel URL once known. SIGNUPS_ALLOWED=true for onboarding -> flip to false.
# ---------------------------------------------------------------------------
say "Setting up your Password Manager..."
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
cd /opt/augustwest/vaultwarden && run_quiet docker compose pull -q && run_quiet docker compose up -d
# health: curl http://127.0.0.1:8443/alive  -> ISO timestamp
ok "Password Manager ready."
cd /root

# ---------------------------------------------------------------------------
# Step 5 — Nextcloud (files) -> 127.0.0.1:8080   [Nextcloud + MariaDB + Redis]
# ---------------------------------------------------------------------------
say "Setting up your File Cloud..."
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
cd /opt/augustwest/nextcloud && run_quiet docker compose pull -q && run_quiet docker compose up -d
# health: curl http://127.0.0.1:8080/status.php  -> {"installed":true,...}
note "Waiting for your File Cloud to finish its first-time setup..."

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
run_quiet docker exec -u www-data nextcloud_app php occ config:system:set \
  trusted_domains 2 --value="files-${CUSTOMER}.augustwest.org"
ok "File Cloud ready."
cd /root

# ---------------------------------------------------------------------------
# Step 6 — Home Assistant (smart home) -> 127.0.0.1:8123
#   Bridge net + loopback bind (localhost-only model). For LAN device
#   auto-discovery switch to network_mode: host later.
# ---------------------------------------------------------------------------
say "Setting up your Smart Home hub..."
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
cd /opt/augustwest/homeassistant && run_quiet docker compose pull -q && run_quiet docker compose up -d
# health: curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/  -> 302
ok "Smart Home hub ready."
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
  say "Getting your setup assistant ready..."
  note "Making sure all four apps are responding..."
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
  ( cd "$ONBOARD_DIR" && run_quiet docker compose up -d --build )
  ok "Setup assistant ready."
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

# CF_API_TOKEN / CF_ZONE_ID are August West OPERATOR credentials. They are read
# ONLY from the environment and are NEVER prompted for — a customer must never be
# asked for them. If either is absent we skip Cloudflare Tunnel setup gracefully
# (the stack still runs over loopback/Tailscale; monitoring falls back to
# heartbeat-only). No interactive prompt, no hard failure.

TUNNEL_CONFIGURED=false
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
  say "Connecting your device to the internet securely..."
  run_quiet curl -fsSL -o /tmp/aw-tunnel-setup.sh https://augustwest.org/aw-tunnel-setup.sh
  # Env-prefixed external command: assignments export straight into the child
  # bash, so invoke it directly (not via run_quiet) and log its output.
  echo "\$ bash /tmp/aw-tunnel-setup.sh (tunnel setup)" >> "$LOG"
  CUSTOMER="$CUSTOMER" BASE_DOMAIN="$BASE_DOMAIN" CUSTOMER_DOMAIN="$CUSTOMER_DOMAIN" \
  CF_API_TOKEN="$CF_API_TOKEN" CF_ZONE_ID="$CF_ZONE_ID" \
    bash /tmp/aw-tunnel-setup.sh >> "$LOG" 2>&1
  TUNNEL_CONFIGURED=true

  # Ensure the onboarding wizard's edge route exists. Current aw-tunnel-setup.sh
  # already writes setup-<customer_domain> -> 127.0.0.1:8888, but guard against
  # an older tunnel script that predates it: if the route is missing, inject it
  # just before the catch-all 404 rule, then re-validate + reload cloudflared.
  CF_CFG=/etc/cloudflared/config.yml
  if [ -f "$CF_CFG" ] && ! grep -q "setup-${CUSTOMER_DOMAIN}" "$CF_CFG"; then
    echo "Adding setup-${CUSTOMER_DOMAIN} route to $CF_CFG ..." >> "$LOG"
    tmp_cfg="$(mktemp)"
    awk -v host="setup-${CUSTOMER_DOMAIN}" '
      /- service: http_status:404/ && !done {
        print "  - hostname: " host
        print "    service: http://127.0.0.1:8888"
        done=1
      }
      { print }
    ' "$CF_CFG" > "$tmp_cfg" && mv "$tmp_cfg" "$CF_CFG"
    if command -v cloudflared >/dev/null 2>&1 && cloudflared --config "$CF_CFG" tunnel ingress validate >> "$LOG" 2>&1; then
      systemctl restart aw-cloudflared.service 2>/dev/null || systemctl restart cloudflared 2>/dev/null || true
    else
      echo "WARNING: cloudflared rejected the edited ingress config; leaving tunnel as-is." >&2
    fi
  fi
  ok "Secure internet access configured."
else
  note "Secure internet access not set up yet — your apps work locally for now."
  # Operator-facing detail (missing CF_API_TOKEN / CF_ZONE_ID env vars):
  echo "WARNING: CF_API_TOKEN / CF_ZONE_ID not set — Cloudflare Tunnel NOT configured." >&2
  echo "         Services stay reachable only via loopback/Tailscale. Re-run with both" >&2
  echo "         set, or run aw-tunnel-setup.sh manually, to publish the subdomains." >&2
fi

# ---------------------------------------------------------------------------
# Step 7 — automatic security updates (unattended-upgrades)
# ---------------------------------------------------------------------------
say "Turning on automatic security updates..."
export DEBIAN_FRONTEND=noninteractive
run_quiet apt-get update -qq
run_quiet apt-get install -y -qq unattended-upgrades apt-listchanges
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
run_quiet systemctl enable --now unattended-upgrades
run_quiet unattended-upgrade --dry-run --debug   # sanity check
ok "Automatic security updates enabled."

# ---------------------------------------------------------------------------
# Step 8 — register with August West monitoring + install heartbeat timer
#   Parameterize these (do NOT commit real tokens):
#     CUSTOMER, DEVICE_NAME, PROVISION_TOKEN
# ---------------------------------------------------------------------------
# CUSTOMER is the customer's own value (prompted at the top). DEVICE_NAME
# defaults to the host's own name. PROVISION_TOKEN is an August West OPERATOR
# credential read ONLY from the environment (never prompted) — if it is absent we
# skip registration + the heartbeat timer entirely, with a warning, rather than
# prompting or failing. The stack itself is fully functional without it.
: "${CUSTOMER:?set CUSTOMER (August West customer slug)}"
: "${DEVICE_NAME:=$(hostname)}"
: "${PROVISION_TOKEN:=}"

if [ -z "$PROVISION_TOKEN" ]; then
  note "Remote monitoring not set up — all your apps are fully working."
  # Operator-facing detail (missing PROVISION_TOKEN env var):
  echo "WARNING: PROVISION_TOKEN not set — device NOT registered with August West" >&2
  echo "         monitoring and no heartbeat timer was installed. Re-run with" >&2
  echo "         PROVISION_TOKEN exported to enable monitoring." >&2
else
say "Registering your device with August West support..."
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
echo "$RESP" >> "$LOG"
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
run_quiet systemctl daemon-reload
run_quiet systemctl enable --now augustwest-heartbeat.timer
ok "Device registered — remote monitoring is on."
fi

# ---------------------------------------------------------------------------
# Step 8b — Restic backups of /opt/augustwest -> Backblaze B2, daily @ 03:00
#   Encryption password: RESTIC_PASSWORD (generated in Step 2b, persisted in
#   $SECRETS). Repository is Backblaze B2; its credentials are August West
#   OPERATOR values supplied ONLY via the environment (B2_ACCOUNT_ID /
#   B2_ACCOUNT_KEY / B2_BUCKET) and are NEVER prompted for. If any is missing,
#   backup config is SKIPPED with a warning — the rest of the install is
#   unaffected.
#
#   Retention (applied after each backup): 7 daily, 4 weekly, 12 monthly.
#   Runtime log: /var/log/augustwest-backup.log
# ---------------------------------------------------------------------------
: "${B2_ACCOUNT_ID:=}"
: "${B2_ACCOUNT_KEY:=}"
: "${B2_BUCKET:=}"

if [ -z "$B2_ACCOUNT_ID" ] || [ -z "$B2_ACCOUNT_KEY" ] || [ -z "$B2_BUCKET" ]; then
  note "Automatic cloud backups not set up yet."
  # Operator-facing detail (missing B2_* env vars):
  echo "WARNING: B2 credentials not provided — backup is NOT configured." >&2
  echo "         Re-run with B2_ACCOUNT_ID / B2_ACCOUNT_KEY / B2_BUCKET set to enable Restic backups." >&2
else
  say "Setting up automatic encrypted cloud backups..."
  # restic from the distro repo (Ubuntu 24.04+ ships a recent enough version)
  if ! command -v restic >/dev/null 2>&1; then
    run_quiet apt-get update -qq
    run_quiet apt-get install -y -qq restic
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
  restic snapshots >/dev/null 2>&1 || run_quiet restic init

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
  run_quiet systemctl daemon-reload
  run_quiet systemctl enable --now augustwest-backup.timer
  echo "Restic backups configured: daily @ 03:00 -> b2:${B2_BUCKET}:augustwest-$(hostname) (log: /var/log/augustwest-backup.log)" >> "$LOG"
  ok "Automatic cloud backups enabled (nightly)."
fi

# ---------------------------------------------------------------------------
# Step 9 — completion summary + onboarding wizard hand-off
#   Print the setup URL (and a scannable QR) the customer opens to run the
#   wizard. The wizard mints its one-time setup token on first access, so poke a
#   protected endpoint once to force token creation, then read it. The token is
#   passed in the URL as ?t=... (the frontend stores it and strips it from the
#   address bar).
# ---------------------------------------------------------------------------
printf '\n\033[1;32m✓ All done! Your private home cloud is ready.\033[0m\n'
echo "  (Technical details saved for support: /root/augustwest-credentials.txt, $LOG)"

if [ -f "$ONBOARD_DIR/docker-compose.yml" ]; then
  # Force the wizard to create its setup token (any authenticated route triggers
  # it; the 403 we get back is expected and harmless), then read it back.
  curl -fsS -o /dev/null --max-time 5 -H 'X-Setup-Token: bootstrap' \
    http://127.0.0.1:8888/api/state 2>/dev/null || true
  SETUP_TOKEN="$(cat /etc/augustwest/onboarding_token 2>/dev/null || true)"

  # The customer-facing setup URL. setup-${CUSTOMER_DOMAIN} is the Cloudflare
  # Tunnel route configured above (= setup-${CUSTOMER}.augustwest.org with the
  # default BASE_DOMAIN); the token is passed as ?t=... and the frontend stores
  # it and strips it from the address bar.
  SETUP_URL="https://setup-${CUSTOMER_DOMAIN}/?t=${SETUP_TOKEN}"

  echo
  echo "==============================================================="
  echo " One last step — finish setup"
  echo "==============================================================="
  echo " Open this on your phone or laptop to finish setting things up:"
  echo
  echo "   ${SETUP_URL}"
  echo
  if [ "${TUNNEL_CONFIGURED:-false}" != true ]; then
    echo " NOTE: the Cloudflare Tunnel is not configured yet, so this public URL"
    echo "       will not resolve until it is. In the meantime reach the wizard"
    echo "       over Tailscale or an SSH tunnel:"
    echo "         ssh -L 8888:127.0.0.1:8888 root@$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "       then open http://127.0.0.1:8888/?t=${SETUP_TOKEN}"
    echo
  fi
  # Scannable QR of the setup URL, rendered in-terminal with qrencode.
  if ! command -v qrencode >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 -m 2 "$SETUP_URL"
  else
    echo " (could not install qrencode — open the URL above to view the QR code)"
  fi
  echo "==============================================================="
fi
