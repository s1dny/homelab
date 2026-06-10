{ config, lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabBootstrapFlakePath = "/etc/nixos";
  homelabRuntimeSecretsDir = "/run/secrets/homelab";
  homelabCloudflaredSecretsFile = "${homelabRuntimeSecretsDir}/cloudflare-tunnel-token.env";
  homelabKopiaR2SecretsFile = "${homelabRuntimeSecretsDir}/kopia-r2.env";
  homelabHostSecretsSopsFile = "${homelabSrc}/nixos/secrets/host-secrets.sops.yaml";
  homelabSopsAgeKeyFile = "/var/lib/sops-nix/key.txt";
  fluxInstallManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.6.4/install.yaml";
    hash = "sha256-fNBDqCNmZye0ud5Ag0YUiyh0G0frCz5CN6tyWdStOrg=";
  };
  defaultHostHostname = "azalab-0";
  defaultHostUsername = "aiden";
  defaultHostAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
  ];
in
{
  networking.hostName = lib.mkDefault defaultHostHostname;
  networking.networkmanager.enable = true;
  time.timeZone = "Australia/Sydney";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 6443 ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  services.journald.extraConfig = ''
    SystemMaxUse=1G
    RuntimeMaxUse=256M
    MaxRetentionSec=14day
  '';

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "${config.networking.hostName} samba";
        "netbios name" = config.networking.hostName;
        "security" = "user";
        "map to guest" = "Bad User";
      };
      srv = {
        "path" = "/srv";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = defaultHostUsername;
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  virtualisation.docker.enable = true;

  programs.fish.enable = true;
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.fish.shellAliases = {
    cd = "z";
    v = "nvim";
    ls = "eza";
  };

  environment.etc."homelab/source".source = homelabSrc;

  environment.systemPackages = with pkgs; [
    age
    bun
    cargo
    cloudflared
    curl
    docker
    docker-compose
    dua
    eza
    gcc
    git
    jq
    k3s
    kopia
    kubectl
    kubernetes-helm
    libclang
    libxml2
    neovim
    nodejs
    pkg-config
    python3
    rustc
    sops
    sqlite
    yq-go
    zstd

    (writeShellScriptBin "homelab-check-k8s-health" ''
      set -euo pipefail
      if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      kubectl wait --for=condition=Ready nodes --all --timeout=2m

      if kubectl get namespace flux-system >/dev/null 2>&1; then
        kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=5m
        kubectl -n flux-system wait --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io --all --timeout=10m
        kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io,kustomizations.kustomize.toolkit.fluxcd.io
      fi

      kubectl get pods -A
      kubectl get ingress -A
      kubectl get pvc -A
    '')

    (writeShellScriptBin "sync.sh" ''
      exec ${pkgs.bash}/bin/bash ${homelabSourcePath}/sync.sh "$@"
    '')
  ];

  environment.variables = {
    PKG_CONFIG_PATH = lib.makeSearchPath "lib/pkgconfig" [ pkgs.libxml2.dev ];
    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
    BINDGEN_EXTRA_CLANG_ARGS =
      builtins.readFile "${pkgs.stdenv.cc}/nix-support/libc-cflags";
  };

  environment.sessionVariables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    CLUSTER = config.networking.hostName;
  };

  sops.age = {
    keyFile = homelabSopsAgeKeyFile;
    generateKey = true;
  };
  sops.secrets."homelab/cloudflare-tunnel-token.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "cloudflare_tunnel_token_env";
    path = homelabCloudflaredSecretsFile;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "cloudflared-dashboard-tunnel.service" ];
  };
  sops.secrets."homelab/kopia-r2.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "kopia_r2_env";
    path = homelabKopiaR2SecretsFile;
    owner = "root";
    group = "root";
    mode = "0400";
  };
  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = toString [
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
    ];
  };
  services.k3s.manifests.flux.source = fluxInstallManifest;

  systemd.services.cloudflared-dashboard-tunnel = {
    description = "Cloudflare Tunnel (dashboard-managed)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.cloudflared pkgs.bash ];
    unitConfig = {
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      EnvironmentFile = homelabCloudflaredSecretsFile;
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      set -euo pipefail
      set +u
      if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
        echo "cloudflared-dashboard-tunnel: CLOUDFLARE_TUNNEL_TOKEN is required"
        exit 1
      fi
      set -u

      exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
    '';
  };

  systemd.services.homelab-auto-upgrade = {
    description = "Update flake inputs and rebuild the host";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.nix pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = homelabBootstrapFlakePath;
    };
    script = ''
      set -euo pipefail

      nix flake update --flake ${homelabBootstrapFlakePath}
      exec /run/current-system/sw/bin/nixos-rebuild switch --flake ${homelabBootstrapFlakePath}#${config.networking.hostName}
    '';
  };

  systemd.timers.homelab-auto-upgrade = {
    description = "Run automatic upgrades for the host";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:00:00";
      Persistent = true;
    };
  };

  systemd.services.homelab-ensure-flux-sops-age = {
    description = "Ensure Flux sync and sops-age secret exist";
    after = [ "k3s.service" "network-online.target" ];
    wants = [ "k3s.service" "network-online.target" ];
    path = [ pkgs.kubectl pkgs.bash pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      if [[ ! -s "${homelabSopsAgeKeyFile}" ]]; then
        echo "homelab-ensure-flux-sops-age: key file ${homelabSopsAgeKeyFile} is missing"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "homelab-ensure-flux-sops-age: kubeconfig is not readable yet"
        exit 0
      fi

      if ! kubectl --request-timeout=5s get namespace flux-system >/dev/null 2>&1; then
        echo "homelab-ensure-flux-sops-age: flux-system namespace not present yet"
        exit 0
      fi

      if ! kubectl --request-timeout=5s get crd \
        gitrepositories.source.toolkit.fluxcd.io \
        kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
        echo "homelab-ensure-flux-sops-age: Flux CRDs are not present yet"
        exit 0
      fi

      kubectl -n flux-system create secret generic sops-age \
        --from-file=age.agekey="${homelabSopsAgeKeyFile}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

      kubectl apply -f "${homelabSourcePath}/flux/clusters/${config.networking.hostName}/flux-system-sync.yaml"
    '';
  };

  systemd.timers.homelab-ensure-flux-sops-age = {
    description = "Reconcile flux-system/sops-age secret";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "1m";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /etc/homelab 0755 root root -"
    "d /var/lib/sops-nix 0700 root root -"
    "d /var/lib/homelab 0755 root root -"
    "d /var/lib/homelab/generated 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s 0750 root wheel -"
    "d /srv 0775 ${defaultHostUsername} users -"
    "d /srv/immich 0775 ${defaultHostUsername} users -"
    "d /srv/immich/library 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/library 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/upload 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/thumbs 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/profile 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/backups 2775 ${defaultHostUsername} users -"
    "d /srv/immich/library/encoded-video 2775 ${defaultHostUsername} users -"
    "f /srv/immich/library/library/.immich 0664 ${defaultHostUsername} users -"
    "f /srv/immich/library/upload/.immich 0664 ${defaultHostUsername} users -"
    "f /srv/immich/library/thumbs/.immich 0664 ${defaultHostUsername} users -"
    "f /srv/immich/library/profile/.immich 0664 ${defaultHostUsername} users -"
    "f /srv/immich/library/backups/.immich 0664 ${defaultHostUsername} users -"
    "f /srv/immich/library/encoded-video/.immich 0664 ${defaultHostUsername} users -"
    "d /srv/immich/postgres 0700 999 999 -"
    "d /srv/immich/redis 0750 999 root -"
    "d /srv/libsql 0755 root root -"
    "d /srv/libsql/backups 0750 root root -"
    "d /srv/libsql/data 0750 root root -"
    "d /srv/kopia/repository 0750 root root -"
    "d /srv/tuwunel/data 0750 root root -"
    "d /var/lib/kopia 0700 root root -"
  ];

  systemd.services.kopia-host-backup = {
    description = "Kopia host snapshots to local repository";
    after = [ "network-online.target" "k3s.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.kopia pkgs.coreutils pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = homelabKopiaR2SecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/kopia-host-backup.sh";
    };
  };

  systemd.timers.kopia-host-backup = {
    description = "Run Kopia host backup every night";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  systemd.services.kopia-r2-sync = {
    description = "Kopia sync local repository to Cloudflare R2";
    after = [ "network-online.target" "kopia-host-backup.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.kopia pkgs.coreutils pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = homelabKopiaR2SecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/kopia-r2-sync.sh";
    };
  };

  systemd.timers.kopia-r2-sync = {
    description = "Run Kopia R2 sync every 6 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:10:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  users.users.${defaultHostUsername} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = defaultHostAuthorizedKeys;
  };

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
}
