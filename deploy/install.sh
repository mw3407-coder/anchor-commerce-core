#!/usr/bin/env bash
# Install and run a single-server MercurJS/Medusa deployment on Ubuntu 22.04.
# This script is intended to be run on the target VM, not from the repository host.
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail 'Run this script with sudo or as root.'

source /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || fail 'This installer supports Ubuntu only.'
[[ "${VERSION_ID:-}" == '22.04' ]] || fail "This installer targets Ubuntu 22.04; detected ${VERSION_ID:-unknown}."

APP_USER="${APP_USER:-${SUDO_USER:-ubuntu}}"
[[ "$APP_USER" != 'root' ]] || APP_USER='ubuntu'
id "$APP_USER" >/dev/null 2>&1 || fail "User $APP_USER does not exist. Set APP_USER to an existing non-root user."
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
APP_DIR="${APP_DIR:-$APP_HOME/anchor-commerce-core}"
APP_REPO_URL="${APP_REPO_URL:-https://github.com/mw3407-coder/anchor-commerce-core.git}"
APP_BRANCH="${APP_BRANCH:-main}"
API_DIR="$APP_DIR/apps/api"
ENV_FILE="$API_DIR/.env"
PROD_DIR="$API_DIR/.medusa/server"
BUN_BIN="$APP_HOME/.bun/bin/bun"

random_hex() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }

run_as_app() {
  sudo -u "$APP_USER" -H env PATH="$APP_HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

log 'Installing base packages'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git build-essential unzip openssl \
  postgresql-14 postgresql-client-14 redis-server

log 'Installing Node.js 20'
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

log 'Installing Bun for the application user'
if [[ ! -x "$BUN_BIN" ]]; then
  run_as_app bash -lc 'curl -fsSL https://bun.sh/install | bash'
fi
[[ -x "$BUN_BIN" ]] || fail "Bun was not installed at $BUN_BIN"

log 'Installing Caddy from the official repository'
apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https
install -d -m 0755 /usr/share/keyrings
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt-get update
apt-get install -y caddy

log 'Installing PM2'
npm install --global pm2

log 'Enabling PostgreSQL and Redis'
systemctl enable --now postgresql
systemctl enable --now redis-server

DB_NAME="${DB_NAME:-medusa}"
DB_USER="${DB_USER:-medusa}"
DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"

log "Provisioning PostgreSQL role and database ($DB_NAME)"
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD';"
else
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
else
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\";"
fi

log 'Checking out MercurJS'
install -d -o "$APP_USER" -g "$APP_USER" "$(dirname "$APP_DIR")"
if [[ -d "$APP_DIR/.git" ]]; then
  run_as_app git -C "$APP_DIR" fetch --prune origin "$APP_BRANCH"
  run_as_app git -C "$APP_DIR" checkout "$APP_BRANCH"
  run_as_app git -C "$APP_DIR" reset --hard "origin/$APP_BRANCH"
else
  [[ ! -e "$APP_DIR" ]] || fail "$APP_DIR exists but is not a Git repository. Set APP_DIR to an empty path."
  run_as_app git clone --branch "$APP_BRANCH" --single-branch "$APP_REPO_URL" "$APP_DIR"
fi

[[ -f "$APP_DIR/.env.example" ]] || fail "Missing $APP_DIR/.env.example"
install -d -o "$APP_USER" -g "$APP_USER" "$API_DIR"

PUBLIC_ORIGIN="${PUBLIC_ORIGIN:-http://$(hostname -I | awk '{print $1}')}"
STORE_CORS="${STORE_CORS:-$PUBLIC_ORIGIN}"
ADMIN_CORS="${ADMIN_CORS:-$PUBLIC_ORIGIN}"
VENDOR_CORS="${VENDOR_CORS:-$PUBLIC_ORIGIN}"
AUTH_CORS="${AUTH_CORS:-$PUBLIC_ORIGIN}"
FILE_BACKEND_URL="${FILE_BACKEND_URL:-$PUBLIC_ORIGIN/static}"
JWT_SECRET="${JWT_SECRET:-$(random_hex)}"
COOKIE_SECRET="${COOKIE_SECRET:-$(random_hex)}"

log 'Writing a local API environment file (never committed)'
cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=9000
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}
REDIS_URL=redis://localhost:6379
JWT_SECRET=${JWT_SECRET}
COOKIE_SECRET=${COOKIE_SECRET}
STORE_CORS=${STORE_CORS}
ADMIN_CORS=${ADMIN_CORS}
VENDOR_CORS=${VENDOR_CORS}
AUTH_CORS=${AUTH_CORS}
FILE_BACKEND_URL=${FILE_BACKEND_URL}
MEDUSA_WORKER_MODE=shared
DISABLE_MEDUSA_ADMIN=false
EOF
chown "$APP_USER:$APP_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

log 'Installing workspace dependencies'
run_as_app bash -lc "cd '$APP_DIR' && '$BUN_BIN' install --frozen-lockfile"

log 'Building the API with the Mercur/Medusa CLI'
run_as_app bash -lc "cd '$API_DIR' && NODE_ENV=production '$BUN_BIN' x medusa build"
[[ -d "$PROD_DIR" ]] || fail "Expected production output at $PROD_DIR"

log 'Preparing the compiled server environment'
install -m 600 -o "$APP_USER" -g "$APP_USER" "$ENV_FILE" "$PROD_DIR/.env"
install -m 600 -o "$APP_USER" -g "$APP_USER" "$ENV_FILE" "$PROD_DIR/.env.production"

log 'Running database migrations'
run_as_app bash -lc "cd '$PROD_DIR' && NODE_ENV=production '$BUN_BIN' x medusa db:migrate"

log 'Installing the HTTP reverse proxy configuration'
install -d -m 0755 /var/log/caddy
install -m 0644 "$APP_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy
systemctl restart caddy

log 'Starting MercurJS with PM2'
PM2_BIN="$(command -v pm2)"
run_as_app "$PM2_BIN" delete anchor-backend >/dev/null 2>&1 || true
run_as_app "$PM2_BIN" start "$BUN_BIN" --name anchor-backend --cwd "$PROD_DIR" -- run start
run_as_app "$PM2_BIN" save
pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME"
systemctl daemon-reload
systemctl enable --now "pm2-$APP_USER"

log 'Waiting for the API health endpoint'
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error http://127.0.0.1:9000/health >/dev/null; then
    log 'MercurJS is healthy'
    break
  fi
  sleep 2
done
curl --fail --silent --show-error http://127.0.0.1:9000/health >/dev/null \
  || fail 'MercurJS did not become healthy. Check: sudo -u "$APP_USER" pm2 logs anchor-backend'

log 'Installation complete'
printf 'Public origin: %s\n' "$PUBLIC_ORIGIN"
printf 'API health: %s/health\n' "$PUBLIC_ORIGIN"
printf 'Admin panel: %s/dashboard\n' "$PUBLIC_ORIGIN"
printf 'Vendor panel: %s/seller\n' "$PUBLIC_ORIGIN"
