# syntax=docker/dockerfile:1
# mongosync tool image (linux/amd64 + linux/arm64 via buildx)
# MSVER is the only source of truth for the bundled mongosync version.
FROM ubuntu:22.04

ARG MSVER=1.16.0
ARG TARGETARCH

LABEL org.opencontainers.image.title="kb-mongosync tool image" \
      org.opencontainers.image.description="mongosync (MongoDB Cluster-to-Cluster Sync) bundled with the kb-mongosync runner for KubeBlocks MongoDB migrations"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) artbase="ubuntu2204-x86_64" ;; \
      arm64) artbase="ubuntu2204-arm64"  ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mongosync.tgz \
      "https://fastdl.mongodb.org/tools/mongosync/mongosync-${artbase}-${MSVER}.tgz"; \
    tar -xzf /tmp/mongosync.tgz -C /tmp; \
    install -m 0755 "/tmp/mongosync-${artbase}-${MSVER}/bin/mongosync" /usr/local/bin/mongosync; \
    rm -rf /tmp/mongosync.tgz "/tmp/mongosync-${artbase}-${MSVER}"; \
    mongosync --version; \
    useradd --uid 10001 --system --no-create-home mongosync

COPY kb-mongosync.sh /usr/local/bin/kb-mongosync
RUN chmod 0755 /usr/local/bin/kb-mongosync

USER 10001
EXPOSE 27180
ENTRYPOINT ["mongosync"]
