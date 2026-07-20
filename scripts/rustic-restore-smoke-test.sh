#!/usr/bin/env bash
set -euo pipefail

: "${RUSTIC_PASSWORD:?RUSTIC_PASSWORD is required}"
: "${RCLONE_PROTONDRIVE_USERNAME:?RCLONE_PROTONDRIVE_USERNAME is required}"
: "${RCLONE_PROTONDRIVE_PASSWORD:?RCLONE_PROTONDRIVE_PASSWORD is required (rclone-obscured)}"

PROTON_PATH="${RCLONE_PROTONDRIVE_PATH:-azalab-0/rustic}"
REMOTE_REPOSITORY="rclone::protondrive:${PROTON_PATH}"
RESTORE_DIR="$(mktemp -d /var/tmp/rustic-restore-smoke.XXXXXX)"

cleanup() {
  rm -rf "${RESTORE_DIR}"
}
trap cleanup EXIT

# Never inspect a mirror while the local repository is being pruned or synced.
exec 9>/run/rustic-host-backup.lock
flock 9

# Read repository metadata and a rotating sample of pack data from the actual
# offsite mirror, then restore a small known subtree from the newest snapshot.
RUSTIC_REPOSITORY="${REMOTE_REPOSITORY}" \
  rustic check --read-data-subset 1%

RUSTIC_REPOSITORY="${REMOTE_REPOSITORY}" \
  rustic restore latest:/etc/nixos "${RESTORE_DIR}" --no-ownership

test -s "${RESTORE_DIR}/flake.nix"
