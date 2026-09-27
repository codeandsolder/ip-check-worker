# syntax=docker/dockerfile:1.7
FROM docker.io/tailscale/tailscale:stable AS tailscale

FROM debian:13-slim
ARG TARGETARCH
ARG SCCACHE_VERSION=0.18.0

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash bubblewrap ca-certificates curl iproute2 tini util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) target=x86_64-unknown-linux-musl ;; \
      arm64) target=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported Docker TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    asset="sccache-dist-v${SCCACHE_VERSION}-${target}.tar.gz"; \
    url="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/${asset}"; \
    curl -fsSLo "/tmp/${asset}" "$url"; \
    curl -fsSLo "/tmp/${asset}.sha256" "${url}.sha256"; \
    expected="$(tr -d '[:space:]' < "/tmp/${asset}.sha256")"; \
    actual="$(sha256sum "/tmp/${asset}" | awk '{print $1}')"; \
    test "$actual" = "$expected"; \
    mkdir -p /tmp/sccache-dist; \
    tar -xzf "/tmp/${asset}" -C /tmp/sccache-dist; \
    install -m 0755 "$(find /tmp/sccache-dist -type f -name sccache-dist -print -quit)" /usr/local/bin/sccache-dist; \
    rm -rf /tmp/sccache-dist "/tmp/${asset}" "/tmp/${asset}.sha256"; \
    sccache-dist --version

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY scripts/worker-entrypoint.sh /usr/local/bin/worker-entrypoint

ENV SCCACHE_NO_DAEMON=1
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/worker-entrypoint"]
