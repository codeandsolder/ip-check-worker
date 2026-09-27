# sccache worker Docker package

A small, self-updating `sccache-dist` build worker for machines behind CGNAT.

The stack has two containers:

- **Tailscale** owns the worker's tailnet identity and kernel-mode TUN device.
- **sccache worker** shares the Tailscale network namespace and runs the Linux
  overlay/bubblewrap builder.

The worker defaults match the existing cluster:

- scheduler: `http://100.65.0.2:10600`
- worker port: `10501`
- Tailscale tag: `tag:sccache-worker`
- sccache: `0.18.0`

## Install

Prerequisites are a Linux Docker host with Docker Compose v2, Git, systemd, and
`/dev/net/tun`.

Recommended: put a reusable, pre-authorized Tailscale auth key in a root-readable
file and run:

```bash
curl -fsSL https://raw.githubusercontent.com/codeandsolder/ip-check-worker/sccache-dist-worker/install.sh \
  -o /tmp/sccache-worker-install.sh
sudo bash /tmp/sccache-worker-install.sh \
  --cores 12 \
  --ram 24G \
  --tailscale-key-file /root/sccache-worker.tskey
```

The installer also accepts `--tailscale-key KEY`, `TAILSCALE_AUTH_KEY=...`, or
prompts for the key when run interactively.

Useful optional flags:

```text
--name sccache-foo
--scheduler-url http://100.65.0.2:10600
--worker-port 10501
--install-dir /opt/sccache-worker
```

## What gets installed

The repository is cloned to `/opt/sccache-worker`; machine-specific settings live
in an untracked `.env`, and the Tailscale key is stored in
`secrets/tailscale-auth.key` with mode `0600`.

A systemd timer runs every six hours (with jitter). It fast-forwards the checkout
to `sccache-dist-worker`, pulls the current Tailscale stable image, rebuilds the tiny
worker image, and recreates the Compose stack. Persistent Tailscale identity and
sccache caches live in named Docker volumes.

Check it with:

```bash
cd /opt/sccache-worker
sudo docker compose ps
sudo docker compose logs --tail=100 worker
sudo systemctl status sccache-worker-update.timer
```

To change CPU or RAM allocation, edit `/opt/sccache-worker/.env` and run:

```bash
cd /opt/sccache-worker
sudo docker compose up -d
```

## Resource enforcement

`WORKER_CORES` is applied twice intentionally:

1. Docker applies a CFS CPU quota.
2. The worker pins itself to the first N CPUs in its inherited allowed CPU set.

The affinity makes `sccache-dist` advertise the configured concurrency rather
than the host's full CPU count. `WORKER_RAM` is a Docker memory limit.

## Isolation / privileges

`sccache-dist`'s overlay builder itself performs mount-namespace and overlayfs
operations and then invokes bubblewrap. Consequently the worker container runs
as root and receives `SYS_ADMIN`, plus narrowly scoped Docker security relaxations
needed for nested namespaces. It is **not** run with `privileged: true`.

Tailscale is separate and receives only the TUN device plus `NET_ADMIN`/`NET_RAW`.

Toolchains and build scratch space use named volumes so overlayfs is not nested
inside Docker's writable container layer.
