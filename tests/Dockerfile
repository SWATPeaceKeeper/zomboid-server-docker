# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# Test runner image: bats plus the tools the libraries and their assertions use.
#
# The stock bats image is Alpine, so busybox provides find, cp and tar. The
# backup library relies on `find -printf`, `cp -a` and `tar
# --use-compress-program`, which are GNU behaviour, and the JVM library uses jq.
# Installing the GNU versions here keeps the test environment behaving like the
# Debian-based runtime images.
FROM bats/bats:1.14.0@sha256:5322b877351fda0cc435de8c6116de7d0a2ec79d7c680132a0ef329a633bc66f

# The bats tag pins the toolchain; pinning apk versions on top of it would break
# the image whenever Alpine rebuilds its index.
# hadolint ignore=DL3018
RUN apk add --no-cache \
  coreutils \
  findutils \
  jq \
  tar \
  zstd \
  && adduser -D -u 1000 bats

# The suite reads the bind-mounted repository and writes only into a mktemp
# directory under /tmp, so it has no reason to run as root. This image is never
# published, so the finding this clears (trivy DS-0002) is not a real exposure —
# but it was the only permanently expected failure in `trivy config .`, and a
# scanner with one of those is a scanner people stop reading.
USER 1000:1000
