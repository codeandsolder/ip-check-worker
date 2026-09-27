#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=${SCCACHE_WORKER_INSTALL_DIR:-/opt/sccache-worker}
SOURCE_REF=${SCCACHE_WORKER_SOURCE_REF:-sccache-dist-worker}
cd "$INSTALL_DIR"

git fetch --quiet origin "$SOURCE_REF"
git reset --hard FETCH_HEAD

# Install the just-fetched updater for the next invocation before touching containers.
install -m 0755 "$INSTALL_DIR/update.sh" /usr/local/sbin/sccache-worker-update

docker compose config --quiet
docker compose pull tailscale
docker compose build --pull worker
docker compose up -d --remove-orphans

echo "sccache-worker: update complete at $(git rev-parse --short HEAD)"
