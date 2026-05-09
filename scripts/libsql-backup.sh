set -euo pipefail

SOURCE_DIR="/srv/libsql/data"
BACKUP_DIR="/srv/libsql/backups"
RETENTION_DAYS=30
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
ARCHIVE_NAME="libsql-data-${TIMESTAMP}.tar"
FINAL_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}.zst"
TMP_PATH="${FINAL_PATH}.tmp"

cleanup() {
  rm -f "${TMP_PATH}"
}
trap cleanup EXIT

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "libsql-backup: source directory not found at ${SOURCE_DIR}" >&2
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

tar --ignore-failed-read --warning=no-file-changed -C "$(dirname "${SOURCE_DIR}")" -cf - "$(basename "${SOURCE_DIR}")" \
  | zstd -T0 -19 -o "${TMP_PATH}"
mv "${TMP_PATH}" "${FINAL_PATH}"

find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'libsql-data-*.tar.zst' -mtime +"${RETENTION_DAYS}" -delete
