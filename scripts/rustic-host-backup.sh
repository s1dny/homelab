#!/usr/bin/env bash
set -euo pipefail

: "${RUSTIC_PASSWORD:?RUSTIC_PASSWORD is required}"
: "${RCLONE_PROTONDRIVE_USERNAME:?RCLONE_PROTONDRIVE_USERNAME is required}"
: "${RCLONE_PROTONDRIVE_PASSWORD:?RCLONE_PROTONDRIVE_PASSWORD is required (rclone-obscured)}"

export RUSTIC_REPOSITORY="${RUSTIC_REPOSITORY:-/srv/rustic/repository}"
PROTON_PATH="${RCLONE_PROTONDRIVE_PATH:-azalab-0/rustic}"

SOURCES=(/etc/nixos /srv/immich /srv/libsql /srv/tuwunel)
if [[ -n "${RUSTIC_HOST_SOURCES:-}" ]]; then
  read -r -a SOURCES <<< "${RUSTIC_HOST_SOURCES}"
fi

# A single lock covers repository mutation and mirroring so Proton never sees a
# partially-pruned repository. libSQL's replication snapshots are disposable
# compaction artifacts, not database backups, and can double database storage.
exec 9>/run/rustic-host-backup.lock
flock 9

rustic backup --init \
  --glob '!/srv/libsql/**/snapshots/**' \
  --glob '!/srv/libsql/**/script_backup/**' \
  "${SOURCES[@]}"

rustic forget --prune \
  --keep-last 10 \
  --keep-daily 10 \
  --keep-weekly 10 \
  --keep-monthly 10

rclone sync \
  "${RUSTIC_REPOSITORY}" \
  ":protondrive:${PROTON_PATH}" \
  --transfers 1 \
  --checkers 2 \
  --retries 8 \
  --low-level-retries 20 \
  --protondrive-replace-existing-draft \
  --protondrive-enable-caching=false

# Proton Drive does not expose useful object hashes, so compare the complete
# repository inventory and object sizes after every mirror.
rclone check \
  "${RUSTIC_REPOSITORY}" \
  ":protondrive:${PROTON_PATH}" \
  --size-only \
  --one-way \
  --checkers 2 \
  --retries 8 \
  --low-level-retries 20 \
  --protondrive-enable-caching=false
