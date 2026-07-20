#!/usr/bin/env bash
set -euo pipefail

exec sudo nixos-rebuild switch --flake "/etc/homelab/source#$(hostname -s)"
