#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${SCCACHE_WORKER_REPO_URL:-https://github.com/codeandsolder/ip-check-worker.git}
REPO_REF=${SCCACHE_WORKER_SOURCE_REF:-sccache-dist-worker}
INSTALL_DIR=/opt/sccache-worker
SCHEDULER_URL=http://100.65.0.2:10600
WORKER_PORT=10501
SCCACHE_VERSION=0.18.0
TOOLCHAIN_CACHE_SIZE=21474836480
CORES=
RAM=
WORKER_NAME=
KEY=
KEY_FILE=

usage() {
  cat <<'USAGE'
Usage:
  sudo ./install.sh --cores N --ram SIZE [--tailscale-key KEY | --tailscale-key-file PATH]
                    [--name NAME] [--scheduler-url URL] [--worker-port PORT]
                    [--install-dir PATH]

Examples:
  sudo ./install.sh --cores 12 --ram 24G --tailscale-key-file /root/tskey
  TAILSCALE_AUTH_KEY=tskey-auth-... sudo -E ./install.sh --cores 8 --ram 16G

If no key option/environment variable is supplied and stdin is a TTY, the installer
prompts for the key without echoing it.
USAGE
}

die() {
  echo "sccache-worker installer: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --cores) CORES=${2:?}; shift 2 ;;
    --ram) RAM=${2:?}; shift 2 ;;
    --tailscale-key) KEY=${2:?}; shift 2 ;;
    --tailscale-key-file) KEY_FILE=${2:?}; shift 2 ;;
    --name) WORKER_NAME=${2:?}; shift 2 ;;
    --scheduler-url) SCHEDULER_URL=${2:?}; shift 2 ;;
    --worker-port) WORKER_PORT=${2:?}; shift 2 ;;
    --install-dir) INSTALL_DIR=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "--cores must be a positive integer"
[[ "$RAM" =~ ^[1-9][0-9]*([kKmMgGtTpP][bB]?)?$ ]] || die "--ram must look like 8192M, 16G, 64G, ..."
[[ "$WORKER_PORT" =~ ^[0-9]+$ ]] || die "--worker-port must be numeric"
(( WORKER_PORT >= 1 && WORKER_PORT <= 65535 )) || die "--worker-port is out of range"

command -v git >/dev/null || die "git is required"
command -v docker >/dev/null || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 ('docker compose') is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

if [[ ! -c /dev/net/tun ]] && command -v modprobe >/dev/null; then
  modprobe tun || true
fi
[[ -c /dev/net/tun ]] || die "/dev/net/tun is unavailable; enable the TUN device on this host"

if [[ -n "$KEY_FILE" ]]; then
  [[ -r "$KEY_FILE" ]] || die "cannot read Tailscale key file: $KEY_FILE"
  KEY=$(<"$KEY_FILE")
elif [[ -z "$KEY" && -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
  KEY=$TAILSCALE_AUTH_KEY
elif [[ -z "$KEY" && -t 0 ]]; then
  read -rsp "Tailscale auth key: " KEY
  echo
fi
[[ -n "$KEY" ]] || die "provide a Tailscale auth key"

if [[ -z "$WORKER_NAME" ]]; then
  host=$(hostname -s)
  WORKER_NAME="sccache-$(printf '%s' "$host" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
fi
[[ "$WORKER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "invalid --name for a Tailscale hostname"

if [[ -e "$INSTALL_DIR/.git" ]]; then
  origin=$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)
  [[ "$origin" == "$REPO_URL" || "$origin" == "${REPO_URL%.git}" ]] ||
    die "$INSTALL_DIR exists but is not this worker repository"
  git -C "$INSTALL_DIR" fetch origin "$REPO_REF"
  git -C "$INSTALL_DIR" reset --hard FETCH_HEAD
elif [[ -e "$INSTALL_DIR" ]]; then
  [[ -z "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    die "$INSTALL_DIR exists and is not empty"
  git clone --depth=1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
else
  install -d -m 0755 "$(dirname "$INSTALL_DIR")"
  git clone --depth=1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
fi

install -d -m 0700 "$INSTALL_DIR/secrets"
printf '%s\n' "$KEY" > "$INSTALL_DIR/secrets/tailscale-auth.key"
chmod 0600 "$INSTALL_DIR/secrets/tailscale-auth.key"
unset KEY TAILSCALE_AUTH_KEY

cat > "$INSTALL_DIR/.env" <<EOF_ENV
WORKER_NAME=${WORKER_NAME}
WORKER_CORES=${CORES}
WORKER_RAM=${RAM}
SCHEDULER_URL=${SCHEDULER_URL}
WORKER_PORT=${WORKER_PORT}
SCCACHE_VERSION=${SCCACHE_VERSION}
TOOLCHAIN_CACHE_SIZE=${TOOLCHAIN_CACHE_SIZE}
EOF_ENV
chmod 0600 "$INSTALL_DIR/.env"

install -m 0755 "$INSTALL_DIR/update.sh" /usr/local/sbin/sccache-worker-update

cat > /etc/systemd/system/sccache-worker-update.service <<EOF_UNIT
[Unit]
Description=Update the Dockerized sccache worker
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
Environment=SCCACHE_WORKER_INSTALL_DIR=${INSTALL_DIR}
Environment=SCCACHE_WORKER_SOURCE_REF=${REPO_REF}
ExecStart=/usr/local/sbin/sccache-worker-update
EOF_UNIT

cat > /etc/systemd/system/sccache-worker-update.timer <<'EOF_TIMER'
[Unit]
Description=Periodically update the Dockerized sccache worker

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=20min
Persistent=true
Unit=sccache-worker-update.service

[Install]
WantedBy=timers.target
EOF_TIMER

cd "$INSTALL_DIR"
docker compose config --quiet
docker compose pull tailscale
docker compose build --pull worker
docker compose up -d --remove-orphans

systemctl daemon-reload
systemctl enable --now sccache-worker-update.timer

echo
echo "Installed sccache worker:"
echo "  name:      $WORKER_NAME"
echo "  cores:     $CORES"
echo "  RAM:       $RAM"
echo "  scheduler: $SCHEDULER_URL"
echo "  path:      $INSTALL_DIR"
echo
docker compose ps
echo
printf 'Tailscale IPv4: '
docker compose exec -T tailscale tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4 | head -n1 || true
