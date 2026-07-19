# Homelab NixOS Setup

Personal homelab configuration for a Dell Optiplex 7060 (`azalab-0`) running NixOS with k3s.
Defaults are hardcoded to my setup (domain, hostnames, SSH keys, etc.). If you want to change the defaults, fork the repo and edit them there.

## Deployment workflow
Hosts update all flake inputs and rebuild automatically every night. Nixpkgs follows the
version declared by the homelab flake, so operating-system release upgrades are picked up
without maintaining a second version pin in `/etc/nixos`.

To apply changes immediately:

```bash
cd /etc/nixos
sudo nix flake update homelab
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname -s)
```
or
```bash
sync.sh
```

`sync.sh` first rebuilds the current homelab module, synchronizes the small bootstrap flake
when it changed, and then performs a second rebuild only when required. It uses passwordless
sudo for the exact commands involved. After changing those sudoers rules, run the rebuild
once with normal sudo; subsequent `sync.sh` runs should not prompt.

When introducing bootstrap synchronization on a host installed from an older revision of this
repository, run `sync.sh` twice. The first run installs the helper and the second updates the
bootstrap flake to the shared Nixpkgs input.

## Prerequisites
- Domain in Cloudflare: `aza.network`
- Cloudflare Zero Trust account
- Dashboard-managed Cloudflare Tunnel token
- NixOS installer USB
- Console/KVM access for first boot (SSH key auth is enforced)

## Install NixOS
1. Boot NixOS installer. Make sure you have network (Ethernet should auto-connect)

2. Partition using `disko` (this erases the target disk):
   ```bash
   sudo -i
   lsblk -d -o NAME,SIZE,MODEL,SERIAL

   curl -fsSL "https://raw.githubusercontent.com/s1dny/homelab/main/nixos/disko.nix" -o /tmp/disko.nix
   # edit and set disko.devices.disk.main.device to your disk
   vi /tmp/disko.nix

   nix --extra-experimental-features "nix-command flakes" run github:nix-community/disko/latest -- --mode disko /tmp/disko.nix
   nixos-generate-config --root /mnt
   ```

3. Fetch host bootstrap flake and generate lock file:
   ```bash
   mkdir -p /mnt/etc/nixos
   cd /mnt/etc/nixos
   curl -fsSL "https://raw.githubusercontent.com/s1dny/homelab/main/nixos/flake.nix" -o flake.nix
   # if this host is not azalab-0, edit flake.nix and set both:
   # - nixosConfigurations.<cluster>
   # - networking.hostName = "<cluster>";
   vi flake.nix
   nix --extra-experimental-features "nix-command flakes" flake lock
   ```

4. Install and reboot:
   ```bash
   CLUSTER=azalab-0
   # set CLUSTER to this host name, e.g. azalab-1 or azalab-2
   nixos-install --flake /mnt/etc/nixos#${CLUSTER}
   sudo passwd aiden
   reboot
   ```

5. After reboot, find the machine's IP (check your router or run `ip a` on the console). If `sudo` works in your current console session
   ```bash
   ssh aiden@azalab-0
   ```
   Do everything from here on over SSH.
   Server-side commands below use `$(hostname -s)` so you don't need to manually export `CLUSTER`.

6. On the server, rebuild once to let `sops-nix` create the persistent age key automatically:
   ```bash
   sudo nixos-rebuild switch --flake /etc/nixos#$(hostname -s)
   ```

7. From your local machine, install the same key for `sops edit` (one-time):
   ```bash
   mkdir -p ~/.config/sops/age
   ssh aiden@azalab-0 'sudo cat /var/lib/sops-nix/key.txt' > ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   ```

8. Edit encrypted secrets, then commit/push:
   ```bash
   # install once (pick one)
   # macOS: brew install sops age
   # Nix: nix shell nixpkgs#sops nixpkgs#age

   sops edit nixos/secrets/host-secrets.sops.yaml
   sops edit flux/clusters/azalab-0/manifests/apps/secrets.sops.yaml

   git add .sops.yaml nixos/secrets/host-secrets.sops.yaml flux/clusters/azalab-0/manifests/apps/secrets.sops.yaml
   git commit -m "Update homelab secrets"
   git push
   ```

## Cloudflare Tunnel
In Cloudflare Zero Trust dashboard, create a tunnel named the same as your cluster (for example `azalab-0`) with these hostnames:
- `photos.aza.network` -> `http://localhost:80`
- `matrix.aza.network` -> `http://localhost:80`
- `spinyour.life` -> `http://localhost:80`

Set `CLOUDFLARE_TUNNEL_TOKEN` in `nixos/secrets/host-secrets.sops.yaml` (`cloudflare_tunnel_token_env`) and rebuild. `cloudflared` itself is supplied by `pkgs.cloudflared`, so newer packaged releases are picked up automatically by the host upgrade timer.

## Flux Bootstrap
NixOS writes the Flux install manifest through `services.k3s.manifests`. K3s applies it automatically from `/var/lib/rancher/k3s/server/manifests`.

The only runtime bridge is `homelab-ensure-flux-sops-age.service`, which copies `/var/lib/sops-nix/key.txt` into `flux-system/sops-age` and applies `flux-system-sync.yaml` after the Flux CRDs exist.

Check it with:
```bash
systemctl status homelab-ensure-flux-sops-age.service
homelab-check-k8s-health
```

## Cloudflare Access
Put `photos.aza.network` behind Cloudflare Access.

For `spinyour.life`, remove the Cloudflare Worker route/custom domain and point
the hostname at the `azalab-0` tunnel public hostname above. Keep
`db.spinyour.life` routed to `http://localhost:80` if the app should continue
using the public libSQL endpoint outside the cluster.

## Rustic Backups

`rustic-host-backup.timer` creates a nightly encrypted local repository at
`/srv/rustic/repository`, applies retention, then mirrors the repository to
`azalab-0/rustic` in Proton Drive with rclone.

Add `rustic_proton_env` to `nixos/secrets/host-secrets.sops.yaml` with:

```text
RUSTIC_PASSWORD=<the former KOPIA_REPOSITORY_PASSWORD used to initialize Rustic>
RCLONE_PROTONDRIVE_USERNAME=<Proton username>
RCLONE_PROTONDRIVE_PASSWORD=<output of: rclone obscure 'password'>
RCLONE_PROTONDRIVE_OTP_SECRET_KEY=<optional output of: rclone obscure 'OTP secret'>
```

Run and inspect it manually with:

```bash
sudo systemctl start rustic-host-backup.service
sudo systemctl status rustic-host-backup.service
sudo journalctl -u rustic-host-backup.service
```

## Verification
Run the built-in health check first:
```bash
homelab-check-k8s-health
```

Verify Flux and workloads are healthy:
```bash
kubectl -n flux-system get gitrepository flux-system
kubectl -n flux-system get kustomization flux-system infrastructure apps
kubectl -n flux-system get helmreleases -A
kubectl get pods -A
```

## Samba File Share
Samba is enabled by the homelab module with:
- Share `srv` (guest write): `/srv`
- Discovery: `wsdd` is enabled for Windows network discovery

Quick check:
```bash
sudo systemctl --no-pager status samba-smbd samba-nmbd samba-wsdd
```
