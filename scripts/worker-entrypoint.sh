#!/usr/bin/env bash
set -euo pipefail

: "${SCHEDULER_URL:=http://100.65.0.2:10600}"
: "${WORKER_PORT:=10501}"
: "${WORKER_CORES:=1}"
: "${TOOLCHAIN_CACHE_SIZE:=21474836480}"
: "${TAILSCALE_SOCKET:=/var/run/tailscale/tailscaled.sock}"

die() {
  echo "sccache-worker: $*" >&2
  exit 1
}

[[ "$WORKER_CORES" =~ ^[1-9][0-9]*$ ]] || die "WORKER_CORES must be a positive integer"
[[ "$WORKER_PORT" =~ ^[0-9]+$ ]] || die "WORKER_PORT must be numeric"

expand_cpu_list() {
  local spec=$1 part lo hi i
  local IFS=,
  read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      lo=${part%-*}
      hi=${part#*-}
      for ((i=lo; i<=hi; i++)); do printf '%s\n' "$i"; done
    else
      printf '%s\n' "$part"
    fi
  done
}

limit_cpu_affinity() {
  local allowed n subset
  allowed=$(awk -F: '/^Cpus_allowed_list:/ {gsub(/[[:space:]]/,"",$2); print $2}' /proc/self/status)
  [[ -n "$allowed" ]] || die "could not read Cpus_allowed_list"
  mapfile -t cpus < <(expand_cpu_list "$allowed")
  n=${#cpus[@]}
  (( WORKER_CORES <= n )) || die "requested ${WORKER_CORES} cores but container is allowed only ${n} CPUs (${allowed})"
  subset=$(IFS=,; echo "${cpus[*]:0:WORKER_CORES}")
  taskset -pc "$subset" $$ >/dev/null
  echo "sccache-worker: CPU affinity ${subset}; Docker quota ${WORKER_CORES} CPU(s)"
}

tailscale_ipv4() {
  if [[ -n "${TAILSCALE_IP_OVERRIDE:-}" ]]; then
    printf '%s\n' "$TAILSCALE_IP_OVERRIDE"
    return
  fi

  local i ip
  for i in $(seq 1 90); do
    if [[ -S "$TAILSCALE_SOCKET" ]]; then
      ip=$(tailscale --socket="$TAILSCALE_SOCKET" ip -4 2>/dev/null | head -n1 || true)
      if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return
      fi
    fi
    sleep 1
  done
  die "Tailscale did not become ready"
}

limit_cpu_affinity
TS_IP=$(tailscale_ipv4)
PUBLIC_ADDR="${TS_IP}:${WORKER_PORT}"

install -d -m 0755 /run/sccache-dist /var/cache/sccache-dist/toolchains /var/cache/sccache-dist/build

cat > /run/sccache-dist/server.conf <<EOF_CONF
cache_dir = "/var/cache/sccache-dist/toolchains"
toolchain_cache_size = ${TOOLCHAIN_CACHE_SIZE}
public_addr = "${PUBLIC_ADDR}"
bind_address = "${PUBLIC_ADDR}"
scheduler_url = "${SCHEDULER_URL}"

[builder]
type = "overlay"
build_dir = "/var/cache/sccache-dist/build"
bwrap_path = "/usr/bin/bwrap"

[scheduler_auth]
type = "DANGEROUSLY_INSECURE"
EOF_CONF

echo "sccache-worker: ${PUBLIC_ADDR} -> ${SCHEDULER_URL}"
if [[ "${SCCACHE_WORKER_DRY_RUN:-0}" == 1 ]]; then
  cat /run/sccache-dist/server.conf
  exit 0
fi

exec sccache-dist server --config /run/sccache-dist/server.conf
