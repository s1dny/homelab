#!/usr/bin/env bash
set -euo pipefail

# Deploy the current head of the homelab repo to this host.
#
# Two ways a rebuild can quietly apply the wrong revision, both guarded here:
#
#   1. `--flake /etc/homelab/source` rebuilds from the *deployed* generation's
#      own source snapshot, so it can never observe a new commit. It reports
#      success while changing nothing.
#   2. `--flake github:s1dny/homelab` is answered from nix's flake tarball
#      cache (`tarball-ttl`, 1 hour by default), so within that window it can
#      rebuild an older revision and still report success.
#
# So resolve the branch head over the network here, pin the rebuild to that
# exact revision, and refuse to report success unless the running system is
# the one we asked for.

REPO_URL="https://github.com/s1dny/homelab.git"
FLAKE_REF="github:s1dny/homelab"
BRANCH="${HOMELAB_BRANCH:-main}"
HOST="$(hostname -s)"

echo "sync: resolving ${BRANCH} on ${REPO_URL}"
REV="$(git ls-remote "$REPO_URL" "refs/heads/${BRANCH}" | cut -f1)"
if [ -z "$REV" ]; then
  echo "sync: could not resolve ${BRANCH}" >&2
  exit 1
fi
echo "sync: target revision ${REV}"

TARGET="$(nix eval --refresh --raw \
  "${FLAKE_REF}/${REV}#nixosConfigurations.${HOST}.config.system.build.toplevel")"
echo "sync: target system   ${TARGET}"

CURRENT="$(readlink -f /run/current-system)"
if [ "$CURRENT" = "$TARGET" ]; then
  echo "sync: already running ${REV}, nothing to do"
  exit 0
fi

sudo nixos-rebuild switch --refresh --flake "${FLAKE_REF}/${REV}#${HOST}"

# The whole point: a switch that silently left us on the old system is a
# failure, not a success.
NEW="$(readlink -f /run/current-system)"
if [ "$NEW" != "$TARGET" ]; then
  echo "sync: FAILED - expected ${TARGET}" >&2
  echo "sync:          running  ${NEW}" >&2
  exit 1
fi

echo "sync: ok, ${HOST} now running ${REV}"
