# syntax=docker/dockerfile:1
# Test runner image: bats plus the tools the libraries and their assertions use.
#
# The stock bats image is Alpine, so busybox provides find, cp and tar. The
# backup library relies on `find -printf`, `cp -a` and `tar
# --use-compress-program`, which are GNU behaviour, and the JVM library uses jq.
# Installing the GNU versions here keeps the test environment behaving like the
# Debian-based runtime images.
FROM bats/bats:1.14.0

# The bats tag pins the toolchain; pinning apk versions on top of it would break
# the image whenever Alpine rebuilds its index.
# hadolint ignore=DL3018
RUN apk add --no-cache \
  coreutils \
  findutils \
  jq \
  tar \
  zstd
