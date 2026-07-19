{ config, lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabBootstrapFlakePath = "/etc/nixos";
  homelabRuntimeSecretsDir = "/run/secrets/homelab";
  homelabCloudflaredSecretsFile = "${homelabRuntimeSecretsDir}/cloudflare-tunnel-token.env";
  homelabRusticProtonSecretsFile = "${homelabRuntimeSecretsDir}/rustic-proton.env";
  homelabHostSecretsSopsFile = "${homelabSrc}/nixos/secrets/host-secrets.sops.yaml";
  homelabSopsAgeKeyFile = "/var/lib/sops-nix/key.txt";
  fluxTransitionManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.8.8/install.yaml";
    hash = "sha256-zCOEbchr7DfAYNhgwRiER+iWqT+h2eHjrKTiVybBrmE=";
  };
  fluxInstallManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.9.2/install.yaml";
    hash = "sha256-Sl87fH08AlzmMFwvqD46OQacfaq8QEqw5nKW+hcwWxg=";
  };
  defaultHostHostname = "azalab-0";
  defaultHostUsername = "aiden";
  dockerPackage = pkgs.docker_29;
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

  virtualisation.docker = {
    enable = true;
    package = dockerPackage;
  };

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
    docker-compose
    dua
    eza
    gcc
    git
    jq
    k3s
    rclone
    rustic
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
    sqld
    sqlite
    turso-cli
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

    (writeShellScriptBin "homelab-sync-bootstrap" ''
      set -euo pipefail
      ${pkgs.coreutils}/bin/install -m 0644 \
        ${homelabSourcePath}/nixos/flake.nix \
        ${homelabBootstrapFlakePath}/flake.nix
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
  sops.secrets."homelab/rustic-proton.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "rustic_proton_env";
    path = homelabRusticProtonSecretsFile;
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

  systemd.services.homelab-reconcile-flux = {
    description = "Install and reconcile Flux";
    after = [ "docker.service" "k3s.service" "network-online.target" ];
    wants = [ "docker.service" "k3s.service" "network-online.target" ];
    path = [ dockerPackage pkgs.kubectl pkgs.gnugrep pkgs.bash pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      TimeoutStartSec = "30m";
    };
    script = ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      until kubectl --request-timeout=5s get nodes >/dev/null 2>&1; do
        sleep 5
      done

      if kubectl get crd imagepolicies.image.toolkit.fluxcd.io >/dev/null 2>&1 \
        && kubectl get crd imagepolicies.image.toolkit.fluxcd.io \
          -o jsonpath='{.status.storedVersions}' | grep -qw v1beta2; then
        echo "homelab-reconcile-flux: migrating Flux image APIs through v2.8.8"
        kubectl apply --server-side --force-conflicts -f ${fluxTransitionManifest}
        kubectl -n flux-system wait --for=condition=Available deployment \
          -l app.kubernetes.io/part-of=flux --timeout=10m

        ${dockerPackage}/bin/docker run --rm --pull=always --network=host \
          -v /etc/rancher/k3s/k3s.yaml:/kubeconfig:ro \
          ghcr.io/fluxcd/flux-cli:v2.9.2 \
          --kubeconfig=/kubeconfig migrate
      fi

      kubectl apply --server-side --force-conflicts -f ${fluxInstallManifest}
      kubectl -n flux-system wait --for=condition=Available deployment \
        -l app.kubernetes.io/part-of=flux --timeout=10m
    '';
  };

  systemd.timers.homelab-reconcile-flux = {
    description = "Periodically reconcile the Flux installation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };

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
    path = [ pkgs.nix pkgs.bash pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = homelabBootstrapFlakePath;
    };
    script = ''
      set -euo pipefail

      if ! cmp -s \
        ${homelabSourcePath}/nixos/flake.nix \
        ${homelabBootstrapFlakePath}/flake.nix; then
        install -m 0644 \
          ${homelabSourcePath}/nixos/flake.nix \
          ${homelabBootstrapFlakePath}/flake.nix
      fi

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
    after = [ "homelab-reconcile-flux.service" "k3s.service" "network-online.target" ];
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
    "d /srv 0775 root users -"
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
    "d /srv/libsql/plarza 0750 666 666 -"
    "d /srv/libsql/spinyourlife 0750 666 666 -"
    "d /srv/plarza-dashboard-deploy 0750 ${defaultHostUsername} users -"
    "d /srv/rustic/repository 0700 root root -"
    "d /srv/plarza-deploy 0750 ${defaultHostUsername} users -"
    "d /srv/plarza-worker-deploy 0750 ${defaultHostUsername} users -"
    "d /srv/registry 0755 root root -"
    "d /srv/spinyourlife-deploy 0750 ${defaultHostUsername} users -"
    "d /srv/tuwunel/data 0750 root root -"
  ];

  systemd.services.homelab-local-registry = {
    description = "Local Docker registry for k3s workloads";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "docker.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ dockerPackage pkgs.bash ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      ExecStop = "-${dockerPackage}/bin/docker stop homelab-registry";
    };
    preStart = ''
      ${dockerPackage}/bin/docker rm -f homelab-registry registry >/dev/null 2>&1 || true
    '';
    script = ''
      exec ${dockerPackage}/bin/docker run --rm --pull=always --name homelab-registry \
        -p 127.0.0.1:5000:5000 \
        -v /srv/registry:/var/lib/registry \
        registry:latest
    '';
  };

  systemd.services.plarza-auto-deploy = {
    description = "Build and deploy Plarza from GitHub";
    after = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    wants = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    path = [
      pkgs.bash
      pkgs.coreutils
      dockerPackage
      pkgs.git
      pkgs.kubectl
      pkgs.openssh
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      User = defaultHostUsername;
      Group = "users";
      SupplementaryGroups = [ "docker" "wheel" ];
      WorkingDirectory = "/srv/plarza-deploy";
      TimeoutStartSec = "15m";
    };
    script = ''
      set -euo pipefail

      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      repo_url="git@github.com:plarza/app.git"
      branch="main"
      app_dir="/srv/plarza-deploy/repo"
      state_file="/srv/plarza-deploy/deployed-rev"
      lock_file="/srv/plarza-deploy/deploy.lock"
      image="localhost:5000/plarza:latest"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "plarza-auto-deploy: another deploy is already running"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "plarza-auto-deploy: kubeconfig is not readable yet"
        exit 0
      fi

      if [[ ! -d "$app_dir/.git" ]]; then
        rm -rf "$app_dir"
        git clone --branch "$branch" "$repo_url" "$app_dir"
      fi

      cd "$app_dir"
      git fetch --prune origin "$branch"
      target_rev="$(git rev-parse "origin/$branch")"
      deployed_rev="$(cat "$state_file" 2>/dev/null || true)"

      if [[ "$target_rev" == "$deployed_rev" ]]; then
        echo "plarza-auto-deploy: already deployed $target_rev"
        exit 0
      fi

      public_posthog_key="$(
        kubectl -n plarza get secret plarza-app \
          -o go-template='{{index .data "PUBLIC_POSTHOG_KEY" | base64decode}}'
      )"
      if [[ -z "$public_posthog_key" ]]; then
        echo "plarza-auto-deploy: PUBLIC_POSTHOG_KEY is empty"
        exit 1
      fi

      git checkout -B "$branch" "$target_rev"
      docker build --no-cache \
        --build-arg PUBLIC_POSTHOG_KEY="$public_posthog_key" \
        --build-arg SOURCE_REV="$target_rev" \
        -t "$image" .
      docker push "$image"

      kubectl -n plarza rollout restart deployment/plarza
      kubectl -n plarza rollout status deployment/plarza --timeout=5m

      running_rev="$(kubectl -n plarza exec deployment/plarza -c app -- cat /app/.source-rev)"
      if [[ "$running_rev" != "$target_rev" ]]; then
        echo "plarza-auto-deploy: running revision $running_rev does not match target $target_rev"
        exit 1
      fi

      printf '%s\n' "$target_rev" > "$state_file"
      echo "plarza-auto-deploy: deployed $target_rev"
    '';
  };

  systemd.services.plarza-dashboard-auto-deploy = {
    description = "Deploy the Plarza observability dashboard from GitHub";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "docker.service" "network-online.target" ];
    path = [
      pkgs.bash
      pkgs.coreutils
      dockerPackage
      pkgs.git
      pkgs.jq
      pkgs.openssh
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      User = defaultHostUsername;
      Group = "users";
      SupplementaryGroups = [ "docker" ];
      WorkingDirectory = "/srv/plarza-dashboard-deploy";
      TimeoutStartSec = "10m";
    };
    script = ''
      set -euo pipefail

      repo_url="git@github.com:plarza/dashboard.git"
      branch="main"
      app_dir="/srv/plarza-dashboard-deploy/repo"
      state_file="/srv/plarza-dashboard-deploy/deployed-rev"
      lock_file="/srv/plarza-dashboard-deploy/deploy.lock"
      env_file="/home/${defaultHostUsername}/plarza/dashboard/.env"
      project="dashboard"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "plarza-dashboard-auto-deploy: another deploy is already running"
        exit 0
      fi

      if [[ ! -r "$env_file" ]]; then
        echo "plarza-dashboard-auto-deploy: $env_file is not readable"
        exit 1
      fi

      if [[ ! -d "$app_dir/.git" ]]; then
        rm -rf "$app_dir"
        git clone --branch "$branch" "$repo_url" "$app_dir"
      fi

      cd "$app_dir"
      git fetch --prune origin "$branch"
      target_rev="$(git rev-parse "origin/$branch")"
      deployed_rev="$(cat "$state_file" 2>/dev/null || true)"

      if [[ "$target_rev" == "$deployed_rev" ]]; then
        echo "plarza-dashboard-auto-deploy: already deployed $target_rev"
        exit 0
      fi

      git checkout -B "$branch" "$target_rev"
      jq empty grafana/dashboards/*.json
      docker compose --project-name "$project" --env-file "$env_file" config --quiet
      docker compose --project-name "$project" --env-file "$env_file" pull
      docker compose --project-name "$project" --env-file "$env_file" \
        up -d --remove-orphans --wait --wait-timeout 120

      printf '%s\n' "$target_rev" > "$state_file"
      echo "plarza-dashboard-auto-deploy: deployed $target_rev"
    '';
  };

  systemd.timers.plarza-dashboard-auto-deploy = {
    description = "Poll GitHub and deploy Plarza dashboard changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
      Persistent = false;
    };
  };

  systemd.timers.plarza-auto-deploy = {
    description = "Poll GitHub and deploy Plarza changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45s";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
      Persistent = false;
    };
  };

  systemd.services.plarza-worker-auto-deploy = {
    description = "Build and deploy the Plarza worker from GitHub";
    after = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    wants = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    path = [
      pkgs.bash
      pkgs.coreutils
      dockerPackage
      pkgs.git
      pkgs.kubectl
      pkgs.openssh
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      User = defaultHostUsername;
      Group = "users";
      SupplementaryGroups = [ "docker" "wheel" ];
      WorkingDirectory = "/srv/plarza-worker-deploy";
      TimeoutStartSec = "30m";
    };
    script = ''
      set -euo pipefail

      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      repo_url="git@github.com:plarza/worker.git"
      branch="main"
      app_dir="/srv/plarza-worker-deploy/repo"
      state_file="/srv/plarza-worker-deploy/deployed-rev"
      lock_file="/srv/plarza-worker-deploy/deploy.lock"
      image="localhost:5000/plarza-worker:latest"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "plarza-worker-auto-deploy: another deploy is already running"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "plarza-worker-auto-deploy: kubeconfig is not readable yet"
        exit 0
      fi

      if ! kubectl -n plarza get deployment plarza-worker >/dev/null 2>&1; then
        echo "plarza-worker-auto-deploy: deployment is not available yet"
        exit 0
      fi

      if ! kubectl -n plarza get secret plarza-worker >/dev/null 2>&1; then
        echo "plarza-worker-auto-deploy: worker secret is not available yet"
        exit 0
      fi

      if [[ ! -d "$app_dir/.git" ]]; then
        rm -rf "$app_dir"
        git clone --branch "$branch" "$repo_url" "$app_dir"
      fi

      cd "$app_dir"
      git fetch --prune origin "$branch"
      target_rev="$(git rev-parse FETCH_HEAD)"
      deployed_rev="$(cat "$state_file" 2>/dev/null || true)"

      if [[ "$target_rev" == "$deployed_rev" ]]; then
        echo "plarza-worker-auto-deploy: already deployed $target_rev"
        exit 0
      fi

      git checkout -B "$branch" "$target_rev"
      docker build --no-cache \
        --build-arg SOURCE_REV="$target_rev" \
        -t "$image" .
      docker push "$image"

      kubectl -n plarza rollout restart deployment/plarza-worker
      kubectl -n plarza rollout status deployment/plarza-worker --timeout=10m

      running_rev="$(kubectl -n plarza exec deployment/plarza-worker -- cat /app/.source-rev)"
      if [[ "$running_rev" != "$target_rev" ]]; then
        echo "plarza-worker-auto-deploy: running revision $running_rev does not match target $target_rev"
        exit 1
      fi

      # Remove the legacy Compose container only after Kubernetes is serving the
      # verified revision. This is idempotent on subsequent deployments.
      docker rm -f worker >/dev/null 2>&1 || true

      printf '%s\n' "$target_rev" > "$state_file"
      echo "plarza-worker-auto-deploy: deployed $target_rev"
    '';
  };

  systemd.timers.plarza-worker-auto-deploy = {
    description = "Poll GitHub and deploy Plarza worker changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "75s";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
      Persistent = false;
    };
  };

  systemd.services.spinyourlife-auto-deploy = {
    description = "Build and deploy spinyourlife from GitHub";
    after = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    wants = [
      "docker.service"
      "homelab-local-registry.service"
      "k3s.service"
      "network-online.target"
    ];
    path = [
      pkgs.bash
      pkgs.coreutils
      dockerPackage
      pkgs.git
      pkgs.kubectl
      pkgs.openssh
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      User = defaultHostUsername;
      Group = "users";
      SupplementaryGroups = [ "docker" "wheel" ];
      WorkingDirectory = "/srv/spinyourlife-deploy";
      TimeoutStartSec = "15m";
    };
    script = ''
      set -euo pipefail

      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      repo_url="git@github.com:s1dny/spinyourlife.git"
      branch="main"
      app_dir="/srv/spinyourlife-deploy/repo"
      state_file="/srv/spinyourlife-deploy/deployed-rev"
      lock_file="/srv/spinyourlife-deploy/deploy.lock"
      image="localhost:5000/spinyourlife:latest"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "spinyourlife-auto-deploy: another deploy is already running"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "spinyourlife-auto-deploy: kubeconfig is not readable yet"
        exit 0
      fi

      if [[ ! -d "$app_dir/.git" ]]; then
        rm -rf "$app_dir"
        git clone --branch "$branch" "$repo_url" "$app_dir"
      fi

      cd "$app_dir"
      git fetch --prune origin "$branch"
      target_rev="$(git rev-parse "origin/$branch")"
      deployed_rev="$(cat "$state_file" 2>/dev/null || true)"

      if [[ "$target_rev" == "$deployed_rev" ]]; then
        echo "spinyourlife-auto-deploy: already deployed $target_rev"
        exit 0
      fi

      git checkout -B "$branch" "$target_rev"
      docker build --no-cache --build-arg SOURCE_REV="$target_rev" -t "$image" .
      docker push "$image"

      kubectl -n libsql rollout restart deployment/spinyourlife
      kubectl -n libsql rollout status deployment/spinyourlife --timeout=3m

      running_rev="$(kubectl -n libsql exec deployment/spinyourlife -- cat /app/.source-rev)"
      if [[ "$running_rev" != "$target_rev" ]]; then
        echo "spinyourlife-auto-deploy: running revision $running_rev does not match target $target_rev"
        exit 1
      fi

      printf '%s\n' "$target_rev" > "$state_file"
      echo "spinyourlife-auto-deploy: deployed $target_rev"
    '';
  };

  systemd.timers.spinyourlife-auto-deploy = {
    description = "Poll GitHub and deploy spinyourlife changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45s";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
      Persistent = false;
    };
  };

  systemd.services.homelab-refresh-floating-images = {
    description = "Refresh Kubernetes workloads that track public latest images";
    after = [ "k3s.service" "network-online.target" ];
    wants = [ "k3s.service" "network-online.target" ];
    path = [ pkgs.kubectl pkgs.jq pkgs.bash pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      kubectl get deployments.apps -A -o json \
        | jq -r '
            .items[]
            | select(any(
                ((.spec.template.spec.initContainers // []) + .spec.template.spec.containers)[];
                (.image | endswith(":latest")) and (.image | startswith("localhost:5000/") | not)
              ))
            | [.metadata.namespace, .metadata.name]
            | @tsv
          ' \
        | while IFS=$'\t' read -r namespace name; do
            echo "homelab-refresh-floating-images: refreshing $namespace/$name"
            kubectl -n "$namespace" rollout restart "deployment/$name"
            kubectl -n "$namespace" rollout status "deployment/$name" --timeout=10m
          done
    '';
  };

  systemd.timers.homelab-refresh-floating-images = {
    description = "Refresh floating Kubernetes images every night";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  systemd.services.rustic-host-backup = {
    description = "Rustic host backup and Proton Drive mirror";
    after = [ "network-online.target" "k3s.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.rustic pkgs.rclone pkgs.coreutils pkgs.util-linux pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = homelabRusticProtonSecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/rustic-host-backup.sh";
      TimeoutStartSec = "12h";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.rustic-host-backup = {
    description = "Run Rustic backup and Proton Drive mirror every night";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  users.users.${defaultHostUsername} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = defaultHostAuthorizedKeys;
  };

  security.sudo.extraRules = [
    {
      users = [ defaultHostUsername ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nix";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/homelab-sync-bootstrap";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # This records the original install version and must not be changed during upgrades.
  system.stateVersion = "25.11";
}
