#!/usr/bin/env bash
set -euo pipefail

cd /etc/nixos
sudo -n nix flake update homelab
sudo -n nixos-rebuild switch --flake "/etc/nixos#$(hostname -s)"
