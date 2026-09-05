# syntax=docker/dockerfile:1

# ---- rcon-cli ----------------------------------------------------------------
# Built from source rather than taken from the upstream release tarball. That
# tarball was produced in 2023 with a Go toolchain whose standard library now
# carries 41 HIGH/CRITICAL advisories, and they are compiled into the binary, so
# no amount of updating the base image removes them. Compiling the same tagged
# source with a current toolchain does.
#
# The version pin is verified by Go's module checksum database, which is a
# stronger guarantee than the tarball hash it replaces.
FROM golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 AS rcon

ARG RCON_VERSION=v0.10.3
ENV CGO_ENABLED=0

RUN go install "github.com/gorcon/rcon-cli/cmd/gorcon@${RCON_VERSION}" \
  && install -m 0755 /go/bin/gorcon /usr/local/bin/rcon

# ---- runtime -----------------------------------------------------------------
FROM steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182

LABEL org.opencontainers.image.title="Project Zomboid Dedicated Server" \
  org.opencontainers.image.description="Project Zomboid dedicated server, installed from Steam into a volume at runtime" \
  org.opencontainers.image.licenses="GPL-3.0-or-later" \
  org.opencontainers.image.source="https://github.com/SWATPeaceKeeper/pz-docker-server"

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates \
  iproute2 \
  jq \
  procps \
  tzdata \
  && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships an `ubuntu` account that already occupies uid/gid 1000, so
# it has to go before the service account can claim that id. 1000 is used
# because it matches the default uid on the typical Docker host, which keeps
# bind-mount ownership straightforward.
RUN userdel -r ubuntu \
  && groupadd -g 1000 pz \
  && useradd -u 1000 -g 1000 -m -d /home/pz -s /bin/bash pz \
  && mkdir -p /data/server /data/zomboid /opt/pz \
  && chown -R pz:pz /data /opt/pz

COPY --from=rcon --chown=root:root /usr/local/bin/rcon /usr/local/bin/rcon
COPY --chown=pz:pz scripts/ /opt/pz/scripts/

RUN chmod 0755 /opt/pz/scripts/entrypoint.sh /opt/pz/scripts/healthcheck.sh

ENV PZ_SERVER_DIR=/data/server \
  PZ_DATA_DIR=/data/zomboid \
  PZ_BRANCH=public \
  PZ_MAX_RAM=4g \
  UPDATE_ON_START=true \
  SERVER_NAME=servertest \
  HOME=/home/pz

# Numeric, so a host or orchestrator can resolve the id without the image's
# passwd database (Kubernetes runAsNonRoot checks this).
USER 1000:1000
WORKDIR /data/server

EXPOSE 16261/udp 16262/udp

# start_period is generous because a first boot downloads the server and
# generates a world before it can answer anything.
HEALTHCHECK --interval=30s --timeout=10s --start-period=900s --retries=3 \
  CMD ["/opt/pz/scripts/healthcheck.sh"]

ENTRYPOINT ["/opt/pz/scripts/entrypoint.sh"]
