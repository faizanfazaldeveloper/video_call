#!/usr/bin/env bash
# Deploy the video-call frontend and backend on one Linux server.
#
# Nginx serves both on a single domain (session cookies stay first-party):
#   /api/auth, /rooms, /health, /socket.io  ->  Node signaling (127.0.0.1:4000)
#   everything else                          ->  Next.js        (127.0.0.1:3000)
# PM2 keeps both processes up across reboots.
# mediasoup media uses UDP/TCP 10000-10100 directly; it does not go through Nginx.
#
# Run from anywhere, as root, on the server that already has this repo:
#   sudo ./deploy/deploy.sh
#
# Non-interactive (sudo drops variables unless you pass them with env):
#   sudo env DOMAIN=meet.example.com LETSENCRYPT_EMAIL=you@example.com ./deploy/deploy.sh
#
# Optional: PUBLIC_IP, MONGODB_URI, BETTER_AUTH_SECRET
# A later run reuses /etc/videocall/deploy.env and the existing auth secret.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:${PATH}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
STATE_DIR=/etc/videocall
STATE_FILE="${STATE_DIR}/deploy.env"
NGINX_CONF=""
COMPOSE_FILE="${ROOT}/docker-compose.yml"

info() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo ./deploy/deploy.sh"
  fi
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  mkdir -p "${STATE_DIR}"
  umask 077
  {
    printf 'DOMAIN=%q\n' "${DOMAIN}"
    printf 'LETSENCRYPT_EMAIL=%q\n' "${LETSENCRYPT_EMAIL}"
    printf 'PUBLIC_IP=%q\n' "${PUBLIC_IP}"
    printf 'MONGODB_URI=%q\n' "${MONGODB_URI}"
  } > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

ask() {
  local name="$1" text="$2" default="${3:-}" current
  current="${!name:-}"
  if [[ -n "${current}" ]]; then
    return
  fi
  if [[ ! -t 0 ]]; then
    if [[ -n "${default}" ]]; then
      printf -v "${name}" '%s' "${default}"
      return
    fi
    die "Set ${name} and run again. Example: sudo env ${name}=... ./deploy/deploy.sh"
  fi
  if [[ -n "${default}" ]]; then
    read -r -p "${text} [${default}]: " current
    printf -v "${name}" '%s' "${current:-${default}}"
  else
    read -r -p "${text}: " current
    [[ -n "${current}" ]] || die "${name} is required."
    printf -v "${name}" '%s' "${current}"
  fi
}

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG=apt
  elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  else
    die "This script supports apt (Debian/Ubuntu) and dnf (Fedora/RHEL) only."
  fi
}

pkg_install() {
  if [[ "${PKG}" == apt ]]; then
    apt-get update
    apt-get install -y "$@"
  else
    dnf install -y "$@"
  fi
}

install_base_packages() {
  info "Installing Nginx, Certbot, and build tools"
  if [[ "${PKG}" == apt ]]; then
    pkg_install ca-certificates curl tar xz-utils nginx certbot python3-certbot-nginx \
      build-essential python3 pkg-config openssl
  else
    pkg_install ca-certificates curl tar xz nginx certbot python3-certbot-nginx \
      gcc gcc-c++ make python3 pkgconf-pkg-config openssl
  fi
  systemctl enable nginx
}

node_major() {
  node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0
}

install_node() {
  if command -v node >/dev/null 2>&1 && [[ "$(node_major)" -ge 20 ]]; then
    info "Using Node $(node -v) ($(command -v node))"
    return
  fi
  info "Installing Node.js 22 into /usr/local"
  local arch tarball
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  tarball=$(curl -fsSL "https://nodejs.org/dist/latest-v22.x/" \
    | grep -oE "node-v22\\.[0-9]+\\.[0-9]+-linux-${arch}\\.tar\\.xz" \
    | head -1)
  [[ -n "${tarball}" ]] || die "Could not find a Node 22 build for linux-${arch}."
  curl -fL "https://nodejs.org/dist/latest-v22.x/${tarball}" -o /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
  hash -r
  [[ "$(node_major)" -ge 20 ]] || die "Node install failed."
  info "Installed Node $(node -v)"
}

install_pm2_pnpm() {
  info "Installing PM2 and pnpm"
  npm install -g pm2 pnpm@10
  command -v pm2 >/dev/null || die "pm2 was not installed onto PATH."
  command -v pnpm >/dev/null || die "pnpm was not installed onto PATH."
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose "$@"
  else
    die "docker compose is not available."
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && { docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; }; then
    systemctl enable --now docker 2>/dev/null || true
    return
  fi
  info "Installing Docker for local MongoDB"
  if [[ "${PKG}" == apt ]]; then
    pkg_install docker.io
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      pkg_install docker-compose-v2
    else
      pkg_install docker-compose-plugin
    fi
  else
    if ! dnf install -y docker-cli docker-compose-plugin moby-engine; then
      dnf install -y docker docker-compose-plugin
    fi
  fi
  systemctl enable --now docker
}

uses_local_mongo() {
  [[ "${MONGODB_URI}" == mongodb://127.0.0.1:* || "${MONGODB_URI}" == mongodb://localhost:* ]]
}

start_mongo() {
  if ! uses_local_mongo; then
    info "Using external MongoDB"
    return
  fi
  install_docker
  info "Starting MongoDB (docker compose)"
  local ready="" status="" i
  for i in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ -n "${ready}" ]] || die "Docker did not become ready."
  compose -f "${COMPOSE_FILE}" up -d
  for i in $(seq 1 30); do
    status=$(docker inspect --format '{{.State.Health.Status}}' videocall-mongodb 2>/dev/null || echo "missing")
    if [[ "${status}" == healthy ]]; then
      info "MongoDB is healthy"
      return
    fi
    sleep 2
  done
  docker logs --tail 40 videocall-mongodb || true
  die "MongoDB did not become healthy (last status: ${status})."
}

collect_settings() {
  info "Deployment settings"
  local detected_ip=""
  detected_ip=$(curl -4 -fsSL --max-time 8 https://api.ipify.org || true)

  ask DOMAIN "Domain name pointed at this server (example: meet.example.com)"
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"
  [[ "${DOMAIN}" != *" "* && "${DOMAIN}" == *.* ]] || die "DOMAIN must look like meet.example.com (got: ${DOMAIN})."

  ask LETSENCRYPT_EMAIL "Email for Let's Encrypt expiry notices"
  ask PUBLIC_IP "Public IP announced to WebRTC clients" "${detected_ip}"
  [[ -n "${PUBLIC_IP}" ]] || die "PUBLIC_IP is required so mediasoup can advertise a reachable address."
  ask MONGODB_URI "MongoDB connection string" "mongodb://127.0.0.1:27017/videocall-mediasoup"

  if [[ -z "${BETTER_AUTH_SECRET:-}" && -f "${ROOT}/server/.env" ]]; then
    local line
    line=$(grep -E '^BETTER_AUTH_SECRET=' "${ROOT}/server/.env" | head -1 || true)
    BETTER_AUTH_SECRET="${line#BETTER_AUTH_SECRET=}"
  fi
  if [[ -z "${BETTER_AUTH_SECRET:-}" ]]; then
    BETTER_AUTH_SECRET=$(openssl rand -base64 32 | tr -d '\n')
  fi
}

check_dns() {
  local resolved=""
  resolved=$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)
  if [[ -z "${resolved}" ]]; then
    warn "${DOMAIN} does not resolve yet. Let's Encrypt needs an A record pointing at this server."
  elif [[ "${resolved}" != "${PUBLIC_IP}" ]]; then
    warn "${DOMAIN} resolves to ${resolved}, but PUBLIC_IP is ${PUBLIC_IP}."
    warn "Certificate issuance fails unless the A record points at this machine."
    warn "WebRTC still uses PUBLIC_IP for media. If this host is behind NAT, the A record should be the NAT public IP and ports must be forwarded."
  fi
  if [[ -z "${resolved}" || "${resolved}" != "${PUBLIC_IP}" ]]; then
    if [[ -t 0 ]]; then
      local yn=""
      read -r -p "Continue anyway? [y/N] " yn
      [[ "${yn}" == "y" || "${yn}" == "Y" ]] || die "Stopped so you can fix DNS first."
    else
      die "DNS for ${DOMAIN} does not point at ${PUBLIC_IP}. Fix the A record, then re-run."
    fi
  fi
}

write_env_files() {
  info "Writing environment files"
  umask 077
  {
    printf 'MONGODB_URI=%s\n' "${MONGODB_URI}"
    printf 'PORT=4000\n'
    printf 'HTTP_LISTEN_IP=127.0.0.1\n'
    printf 'CLIENT_ORIGIN=https://%s\n' "${DOMAIN}"
    printf 'BETTER_AUTH_URL=https://%s\n' "${DOMAIN}"
    printf 'BETTER_AUTH_SECRET=%s\n' "${BETTER_AUTH_SECRET}"
    printf 'MEDIASOUP_ANNOUNCED_IP=%s\n' "${PUBLIC_IP}"
    printf 'NODE_ENV=production\n'
  } > "${ROOT}/server/.env"
  chmod 600 "${ROOT}/server/.env"

  {
    printf 'NEXT_PUBLIC_SERVER_URL=https://%s\n' "${DOMAIN}"
  } > "${ROOT}/client/.env.production"
  chmod 600 "${ROOT}/client/.env.production"
}

install_app_deps() {
  info "Installing backend dependencies (pnpm)"
  (cd "${ROOT}/server" && pnpm install --frozen-lockfile)
  info "Installing frontend dependencies (npm)"
  (cd "${ROOT}/client" && npm ci)
}

build_frontend() {
  info "Building the Next.js frontend"
  (
    cd "${ROOT}/client"
    NEXT_PUBLIC_SERVER_URL="https://${DOMAIN}" ./node_modules/.bin/next build
  )
}

nginx_site_path() {
  if [[ -d /etc/nginx/sites-available ]]; then
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    NGINX_CONF=/etc/nginx/sites-available/videocall
  else
    mkdir -p /etc/nginx/conf.d
    NGINX_CONF=/etc/nginx/conf.d/videocall.conf
  fi
}

enable_nginx_site() {
  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sfn "${NGINX_CONF}" /etc/nginx/sites-enabled/videocall
    rm -f /etc/nginx/sites-enabled/default
  fi
}

write_nginx() {
  local with_v6="$1"
  local v6=""
  if [[ "${with_v6}" == "1" ]]; then
    v6=$'    listen [::]:80;\n'
  fi
  mkdir -p /etc/nginx/conf.d
  nginx_site_path
  # The upgrade map lives in its own file. Certbot rewrites the server file and
  # its parser rejects a map directive sitting above the server block.
  cat > /etc/nginx/conf.d/videocall-upgrade-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
${v6}    server_name ${DOMAIN};

    client_max_body_size 10m;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location /api/auth/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    location /rooms {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /health {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
  enable_nginx_site
}

configure_nginx() {
  info "Configuring Nginx"
  mkdir -p /var/www/certbot
  if [[ -f /proc/net/if_inet6 ]]; then
    write_nginx 1
    if ! nginx -t; then
      warn "Nginx rejected IPv6. Retrying with IPv4 only."
      write_nginx 0
      nginx -t
    fi
  else
    write_nginx 0
    nginx -t
  fi
  systemctl enable --now nginx
  systemctl restart nginx
}

issue_certificate() {
  info "Requesting a Let's Encrypt certificate for ${DOMAIN}"
  certbot --nginx \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email "${LETSENCRYPT_EMAIL}" \
    --redirect \
    --keep-until-expiring
  nginx -t
  systemctl reload nginx
  if ! { [[ -d /etc/nginx/sites-enabled ]] && grep -Rqs ssl_certificate /etc/nginx/sites-enabled; } \
    && ! { [[ -d /etc/nginx/conf.d ]] && grep -Rqs ssl_certificate /etc/nginx/conf.d; }; then
    die "Certbot finished, but Nginx has no TLS certificate. Check that port 80 is reachable and ${DOMAIN} points at this server."
  fi
}

open_firewall() {
  info "Opening HTTP, HTTPS, and mediasoup ports if a host firewall is active"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    ufw allow OpenSSH || ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 10000:10100/tcp
    ufw allow 10000:10100/udp
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=10000-10100/tcp
    firewall-cmd --permanent --add-port=10000-10100/udp
    firewall-cmd --reload
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    setsebool -P httpd_can_network_connect 1
  fi
}

write_pm2_ecosystem() {
  local node_bin
  node_bin=$(command -v node)
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/ecosystem.config.cjs" <<EOF
module.exports = {
  apps: [
    {
      name: 'videocall-server',
      cwd: '${ROOT}/server',
      script: 'index.js',
      interpreter: '${node_bin}',
      exec_mode: 'fork',
      instances: 1,
      max_memory_restart: '1500M',
      env: { NODE_ENV: 'production' },
    },
    {
      name: 'videocall-client',
      cwd: '${ROOT}/client',
      script: 'node_modules/.bin/next',
      args: 'start -H 127.0.0.1 -p 3000',
      interpreter: '${node_bin}',
      exec_mode: 'fork',
      instances: 1,
      max_memory_restart: '1G',
      env: { NODE_ENV: 'production' },
    },
  ],
};
EOF
}

start_pm2() {
  info "Starting both apps with PM2"
  write_pm2_ecosystem
  pm2 delete videocall-server >/dev/null 2>&1 || true
  pm2 delete videocall-client >/dev/null 2>&1 || true
  pm2 start "${STATE_DIR}/ecosystem.config.cjs"
  pm2 save
  if command -v systemctl >/dev/null 2>&1; then
    if ! pm2 startup systemd -u root --hp /root; then
      warn "pm2 startup failed. The apps are running, but they may not come back after a reboot."
    fi
    pm2 save
  else
    warn "systemd was not found. PM2 will not restart the apps after a reboot."
  fi
}

http_ok() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" || echo "000")
  [[ "${code}" == 2* || "${code}" == 3* ]]
}

wait_http() {
  local url="$1" name="$2" i
  for i in $(seq 1 40); do
    if http_ok "${url}"; then
      return 0
    fi
    sleep 1
  done
  warn "${name} did not respond at ${url}"
  pm2 logs --lines 50 --nostream || true
  die "${name} failed to start."
}

verify() {
  info "Checking both processes"
  wait_http "http://127.0.0.1:4000/health" "Backend"
  wait_http "http://127.0.0.1:3000/" "Frontend"
  if ! http_ok --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/health"; then
    warn "Nginx HTTPS check failed. Confirm port 443 is open and certbot finished."
    die "https://${DOMAIN}/health is not reachable from this machine."
  fi
}

main() {
  require_root
  [[ -f "${ROOT}/server/index.js" && -f "${ROOT}/client/package.json" ]] || die "Run this script from the video_call repo."
  detect_pkg
  load_state
  install_base_packages
  install_node
  install_pm2_pnpm
  collect_settings
  check_dns
  save_state
  open_firewall
  start_mongo
  install_app_deps
  configure_nginx
  issue_certificate
  write_env_files
  build_frontend
  start_pm2
  verify

  cat <<EOF

Deployment finished.

  Site:    https://${DOMAIN}
  Health:  https://${DOMAIN}/health
  Media:   UDP and TCP ${PUBLIC_IP}:10000-10100

Open those media ports in the cloud security group as well as on this host.
Signaling and the website go through Nginx. Camera and microphone traffic does not.

Logs:    pm2 logs
Status:  pm2 status
Reload after a git pull:  sudo ./deploy/deploy.sh

EOF
}

main "$@"
