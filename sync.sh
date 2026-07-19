#!/usr/bin/env bash
set -euo pipefail

cd /etc/nixos
sudo -n nix flake update homelab
sudo -n nixos-rebuild switch --flake "/etc/nixos#$(hostname -s)"

if ! cmp -s /etc/homelab/source/nixos/flake.nix /etc/nixos/flake.nix; then
  sudo -n homelab-sync-bootstrap
  sudo -n nix flake update
  sudo -n nixos-rebuild switch --flake "/etc/nixos#$(hostname -s)"
fi
