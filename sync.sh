#!/usr/bin/env bash
set -euo pipefail

# Deploy the current head of main to this host.
#
# The flake ref is a local git checkout rather than `github:s1dny/homelab`,
# because a `github:` ref is answered from nix's flake tarball cache for an
# hour and can rebuild an older revision while reporting success. Fetching and
# hard-resetting first means the checkout is exactly origin/main, so there is
# nothing stale or dirty left for the rebuild to pick up.

REPO_DIR="${HOMELAB_REPO_DIR:-/var/lib/homelab/repo}"
REPO_URL="${HOMELAB_REPO_URL:-https://github.com/s1dny/homelab.git}"
BRANCH="${HOMELAB_BRANCH:-main}"

if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" fetch --prune origin "$BRANCH"
git -C "$REPO_DIR" reset --hard "origin/$BRANCH"

# The cache is also configured declaratively, but that only takes effect once a
# rebuild has already happened. Passing it here means the rebuild that installs
# it is itself a download rather than a twenty minute rustc run.
exec sudo nixos-rebuild switch \
  --flake "$REPO_DIR#$(hostname -s)" \
  --option extra-substituters "https://merlin.cachix.org" \
  --option extra-trusted-public-keys "merlin.cachix.org-1:3a5u//fmqBkd2G4CHlvCJY7FT6DcQf/P7i92b4BWsjA="
