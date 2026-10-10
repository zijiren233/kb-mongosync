# syntax=docker/dockerfile:1
# mongosync tool image (linux/amd64 + linux/arm64 via buildx).
# MSVER is the only source of truth for the bundled mongosync version.
# Upstream artifact names differ per arch: amd64 uses the ubuntu2204 build,
# arm64 only ships an Amazon Linux 2023 build (glibc 2.34 <= ubuntu 22.04's 2.35).
# The entrypoint waits for /etc/mongosync/conf.json (mounted by the chart from
# a Secret created by kb-mongosync.sh) and then execs mongosync.
FROM ubuntu:22.04

ARG MSVER=1.16.0
ARG TARGETARCH

LABEL org.opencontainers.image.title="kb-mongosync tool image" \
      org.opencontainers.image.description="mongosync (MongoDB Cluster-to-Cluster Sync) bundled with the kb-mongosync runner"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) artifact="mongosync-ubuntu2204-x86_64-${MSVER}.tgz" ;; \
      arm64) artifact="mongosync-amazon2023-arm64-arm64-${MSVER}.tgz" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mongosync.tgz \
      "https://fastdl.mongodb.org/tools/mongosync/${artifact}"; \
    tar -xzf /tmp/mongosync.tgz -C /tmp; \
    bin="$(find /tmp -type f -name mongosync | head -n1)"; \
    [ -n "${bin}" ] || { echo "mongosync binary not found in tarball" >&2; exit 1; }; \
    install -m 0755 "${bin}" /usr/local/bin/mongosync; \
    rm -rf /tmp/mongosync.tgz /tmp/mongosync-*; \
    mongosync --version; \
    useradd --uid 10001 --system --no-create-home mongosync

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY kb-mongosync.sh /usr/local/bin/kb-mongosync
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/kb-mongosync

USER 10001
EXPOSE 27180
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
