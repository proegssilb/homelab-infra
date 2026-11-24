#!/bin/bash
# Turn a bootc-base image into a qcow2 disk with bootc-image-builder (needs root).
#
#   sudo images/bootc-base/build-disk.sh [IMAGE] [OUTDIR]
#
# IMAGE defaults to localhost/bootc-base:dev from the *invoking* user's rootless
# storage (copied into root's storage first); OUTDIR defaults to
# images/bootc-base/out (gitignored). The disk lands at OUTDIR/qcow2/disk.qcow2,
# owned by the invoking user so the rootless boot test can read it.
set -euo pipefail

IMAGE=${1:-localhost/bootc-base:dev}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${2:-$HERE/out}
BIB=quay.io/centos-bootc/bootc-image-builder:latest

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
OWNER=${SUDO_USER:-root}

if [[ $IMAGE == localhost/* ]] && [ "$OWNER" != root ]; then
  echo "copying $IMAGE from $OWNER's storage into root's"
  sudo -u "$OWNER" podman save --format oci-archive "$IMAGE" | podman load
fi

mkdir -p "$OUT"
podman run --rm --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$OUT":/output \
  "$BIB" --type qcow2 --rootfs xfs "$IMAGE"

chown -R "$OWNER": "$OUT"
echo "disk: $OUT/qcow2/disk.qcow2"
