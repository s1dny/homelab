{ config, lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabRuntimeSecretsDir = "/run/secrets/homelab";
  homelabCloudflaredSecretsFile = "${homelabRuntimeSecretsDir}/cloudflare-tunnel-token.env";
  homelabRusticProtonSecretsFile = "${homelabRuntimeSecretsDir}/rustic-proton.env";
  homelabFluxAgeKeyFile = "${homelabRuntimeSecretsDir}/flux-age-key.txt";
  homelabFluxGitCredentialsFile = "${homelabRuntimeSecretsDir}/flux-git-credentials.env";
  homelabMerlinSecretsFile = "${homelabRuntimeSecretsDir}/merlin.env";
  homelabHostSecretsSopsFile = ./secrets/host-secrets.sops.yaml;
  # Injected into the agent's system prompt on every start, alongside any other
  # workspace identity files (AGENTS.md, IDENTITY.md, ...).
  homelabSopsAgeKeyFile = "/var/lib/sops-nix/key.txt";
  fluxTransitionManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.8.8/install.yaml";
    hash = "sha256-zCOEbchr7DfAYNhgwRiER+iWqT+h2eHjrKTiVybBrmE=";
  };
  fluxInstallManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.9.2/install.yaml";
    hash = "sha256-Sl87fH08AlzmMFwvqD46OQacfaq8QEqw5nKW+hcwWxg=";
  };
  chromiumSeccompProfile = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/microsoft/playwright/3827650d171cc1b035cbefb7e00bf5948d6809df/utils/docker/seccomp_profile.json";
    hash = "sha256-zD5hyr2mu8HlPlTSe6TVWp076Cm23RpZb0p7MbHMeEk=";
  };
  defaultHostHostname = "azalab-0";
  defaultHostUsername = "aiden";
  dockerPackage = pkgs.docker_29;
  # Named once because the auto-deploy passes them to nixos-rebuild as well, and
  # a substituter the deploy trusts but the host does not would silently rebuild.
  merlinCacheUrl = "https://merlin.cachix.org";
  merlinCacheKey = "merlin.cachix.org-1:3a5u//fmqBkd2G4CHlvCJY7FT6DcQf/P7i92b4BWsjA=";
  defaultHostAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPz2x+U0zKQXfaIVummROlUunU5l0DIJiHdF2KQrqrIY aiden@plarza.com"
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
    cloudflared
    curl
    docker-compose
    dua
    eza
    git
    jq
    k3s
    rclone
    rustic
    kubectl
    kubernetes-helm
    neovim
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

  ];

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
  sops.secrets."homelab/flux-age-key.txt" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "flux_age_key";
    path = homelabFluxAgeKeyFile;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-ensure-flux-bootstrap.service" ];
  };
  sops.secrets."homelab/flux-git-credentials.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "flux_git_credentials_env";
    path = homelabFluxGitCredentialsFile;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-ensure-flux-bootstrap.service" ];
  };
  sops.secrets."homelab/merlin.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "merlin_env";
    path = homelabMerlinSecretsFile;
    owner = "merlin";
    group = "merlin";
    mode = "0400";
    restartUnits = [ "merlin.service" ];
  };

  systemd.services.merlin.environment.RUST_LOG =
    "merlin=debug,warn";

  services.merlin = {
    enable = true;
    environmentFile = homelabMerlinSecretsFile;
    soul = builtins.readFile ./merlin-soul.md;

    settings = {
      homeserver = "https://matrix.aza.network";
      user_id = "@merlin:matrix.aza.network";
      display_name = "merlin";
      timezone = "Australia/Sydney";
      context_window = 64;

      # allowed_rooms and allowed_senders come from the environment
      # (MERLIN_ALLOWED_ROOMS / MERLIN_ALLOWED_SENDERS in the sops secret).
      # This file is rendered into the world-readable Nix store from a public
      # repository, and the room is private.

      model = {
        chat = "meta/muse-spark-1.3-contributor";
        image = "fal-ai/z-image/turbo";
        # Only image generation moves; chat and embeddings stay on OpenRouter.
        # Needs FAL_API_KEY in the sops secret alongside OPENROUTER_API_KEY.
        image_provider = "fal";
        embedding = "google/gemini-embedding-001";
        # Matryoshka truncation from the native 3072, which keeps the vectors
        # for a full archive near a tenth of a gigabyte.
        embedding_dimensions = 768;
        # Capped rather than left to the provider: uncapped, this model spent
        # the large majority of its output tokens thinking, on trivial
        # questions as much as hard ones, and paid it again every tool round.
        # "low" was too far the other way. It could not hold a multi-step plan
        # across tool rounds, and burned whole turns rediscovering things it had
        # already been told, so the saving was spent on wasted rounds anyway.
        reasoning_effort = "medium";
      };

      limits = {
        max_response_bytes = 8388608;
        # An archive-wide question can spend a dozen rounds just shaping the
        # query before it learns anything, and 32 cut those turns off mid-work.
        tool_iterations = 64;
        request_timeout_s = 60;
        # The sandbox is persistent and the agent installs its own tools, so a
        # run can legitimately be an apk or pip install rather than a snippet.
        # A minute killed those halfway.
        exec_timeout_s = 300;
        exec_memory_max = "1G";
      };
    };
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

  systemd.services.homelab-ensure-flux-bootstrap = {
    description = "Ensure Flux bootstrap credentials and sync resources exist";
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

      if [[ ! -s "${homelabFluxAgeKeyFile}" ]]; then
        echo "homelab-ensure-flux-bootstrap: key file ${homelabFluxAgeKeyFile} is missing"
        exit 0
      fi

      if [[ ! -s "${homelabFluxGitCredentialsFile}" ]]; then
        echo "homelab-ensure-flux-bootstrap: credentials file ${homelabFluxGitCredentialsFile} is missing"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "homelab-ensure-flux-bootstrap: kubeconfig is not readable yet"
        exit 0
      fi

      if ! kubectl --request-timeout=5s get namespace flux-system >/dev/null 2>&1; then
        echo "homelab-ensure-flux-bootstrap: flux-system namespace not present yet"
        exit 0
      fi

      if ! kubectl --request-timeout=5s get crd \
        gitrepositories.source.toolkit.fluxcd.io \
        kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
        echo "homelab-ensure-flux-bootstrap: Flux CRDs are not present yet"
        exit 0
      fi

      kubectl -n flux-system create secret generic flux-system-write \
        --from-env-file="${homelabFluxGitCredentialsFile}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

      kubectl -n flux-system create secret generic sops-age \
        --from-file=age.agekey="${homelabFluxAgeKeyFile}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

      kubectl apply -f "${homelabSourcePath}/flux/clusters/${config.networking.hostName}/flux-system-sync.yaml"
    '';
  };

  systemd.timers.homelab-ensure-flux-bootstrap = {
    description = "Reconcile Flux bootstrap credentials and sync resources";
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
    # Checkout sync.sh fetches into; owned by the admin user so the pull needs
    # no privileges of its own.
    "d /var/lib/homelab/repo 0755 ${defaultHostUsername} users -"
    "d /var/lib/homelab/generated 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s 0750 root wheel -"
    "d /var/lib/kubelet/seccomp 0755 root root -"
    "L+ /var/lib/kubelet/seccomp/chromium.json - - - - ${chromiumSeccompProfile}"
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
    # Root-owned, unlike the other deploy checkouts: this one ends in a
    # nixos-rebuild rather than a container restart.
    "d /srv/merlin-deploy 0750 root root -"
    "d /srv/rustic/repository 0700 root root -"
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

  # merlin is a flake input pinned by revision, so deploying it is not a restart
  # but a lock bump: move flake.lock onto merlin's current main, push that, and
  # rebuild. Doing it here rather than in merlin's CI keeps the credential on
  # this host, where one already exists, instead of putting a cross-repo write
  # token into GitHub Actions.
  systemd.services.merlin-auto-deploy = {
    description = "Deploy merlin from GitHub by bumping its flake pin";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
      pkgs.nix
      # Rather than /run/current-system/sw/bin, which is the configuration this
      # unit is in the middle of replacing.
      pkgs.nixos-rebuild
      pkgs.openssh
      pkgs.systemd
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      # Root, because the deploy ends in `nixos-rebuild switch`. The push borrows
      # the admin user's GitHub key explicitly rather than giving root one.
      User = "root";
      WorkingDirectory = "/srv/merlin-deploy";
      # A cache miss is guarded against below, but a substituted rebuild of the
      # whole host is still not a one-minute job.
      TimeoutStartSec = "30m";
    };
    script = ''
      set -euo pipefail

      branch="main"
      work_dir="/srv/merlin-deploy"
      repo_dir="$work_dir/homelab"
      state_file="$work_dir/deployed-rev"
      lock_file="$work_dir/deploy.lock"
      homelab_url="git@github.com:s1dny/homelab.git"
      merlin_url="https://github.com/plarza/merlin.git"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "merlin-auto-deploy: another deploy is already running"
        exit 0
      fi

      # Root has no GitHub identity of its own; this is the key GitHub already
      # knows, and IdentitiesOnly stops ssh offering anything else first.
      # accept-new rather than the default, because root's known_hosts starts
      # empty and a prompt in a oneshot unit is a hang, not a question.
      export GIT_SSH_COMMAND="ssh -i /home/${defaultHostUsername}/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      export GIT_AUTHOR_NAME="merlin-auto-deploy"
      export GIT_AUTHOR_EMAIL="merlin-auto-deploy@azalab-0"
      export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
      export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

      # Cheap check first, so the usual tick costs one network round trip.
      target_rev="$(git ls-remote "$merlin_url" "refs/heads/$branch" | cut -f1)"
      if [[ -z "$target_rev" ]]; then
        echo "merlin-auto-deploy: could not read merlin's $branch"
        exit 1
      fi
      if [[ "$target_rev" == "$(cat "$state_file" 2>/dev/null || true)" ]]; then
        exit 0
      fi

      if [[ ! -d "$repo_dir/.git" ]]; then
        rm -rf "$repo_dir"
        git clone --branch "$branch" "$homelab_url" "$repo_dir"
      fi

      cd "$repo_dir"
      git fetch --prune origin "$branch"
      # Hard reset rather than pull: a run that deferred below leaves an updated
      # flake.lock in the tree, and it must not be carried into a later deploy.
      git checkout -B "$branch" "origin/$branch"

      nix flake update merlin

      # What actually got locked, which is not necessarily target_rev if merlin's
      # main moved between the ls-remote above and here.
      locked_rev="$(nix flake metadata --json | jq -r '.locks.nodes.merlin.locked.rev')"
      if [[ -z "$locked_rev" || "$locked_rev" == "null" ]]; then
        echo "merlin-auto-deploy: flake.lock has no merlin revision"
        exit 1
      fi

      # merlin's CI publishes to the cache only after its tests pass, so an
      # uncached revision means the build is still running or it failed. Either
      # way there is nothing to deploy yet, and rebuilding now would compile the
      # whole dependency graph on this host. Deferring costs one more minute.
      merlin_out=""
      for attr in merlin merlin-sandbox sandbox-rootfs; do
        out="$(nix eval --raw "github:plarza/merlin/$locked_rev#packages.x86_64-linux.$attr.outPath")"
        if ! nix path-info --narinfo-cache-negative-ttl 0 --store "${merlinCacheUrl}" "$out" >/dev/null 2>&1; then
          echo "merlin-auto-deploy: $attr for $locked_rev is not in the cache yet; waiting"
          exit 0
        fi
        if [[ "$attr" == "merlin" ]]; then
          merlin_out="$out"
        fi
      done

      # The rebuild restarts merlin, which would cut off an answer mid-sentence.
      # The worker's deployer defers the same way when a task is running. A start
      # with no matching finish inside the turn timeout means one is in flight;
      # an empty window means the last turn is older than any turn can live, so a
      # wedged one cannot block the deploy forever.
      last_turn="$(journalctl -u merlin --since "-11 min" -o cat 2>/dev/null \
        | grep -oE "turn (started|finished)" | tail -1 || true)"
      if [[ "$last_turn" == "turn started" ]]; then
        echo "merlin-auto-deploy: a turn is in flight; deferring"
        exit 0
      fi

      if git diff --quiet -- flake.lock; then
        echo "merlin-auto-deploy: flake.lock already pins $locked_rev"
      else
        git commit -m "chore(merlin): deploy ''${locked_rev:0:12}" -- flake.lock
        git push origin "$branch"
      fi

      nixos-rebuild switch --flake "$repo_dir#azalab-0" \
        --option extra-substituters "${merlinCacheUrl}" \
        --option extra-trusted-public-keys "${merlinCacheKey}"

      # The pin moving is not proof the process restarted onto it.
      if ! systemctl is-active --quiet merlin.service; then
        echo "merlin-auto-deploy: merlin.service is not running after the rebuild"
        exit 1
      fi
      if [[ "$(systemctl show -p ExecStart --value merlin.service)" != *"$merlin_out"* ]]; then
        echo "merlin-auto-deploy: merlin.service is not running $locked_rev"
        exit 1
      fi

      printf '%s\n' "$locked_rev" > "$state_file"
      echo "merlin-auto-deploy: deployed $locked_rev"
    '';
  };

  systemd.timers.merlin-auto-deploy = {
    description = "Poll GitHub and deploy merlin changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90s";
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

  systemd.services.rustic-restore-smoke-test = {
    description = "Verify and restore from the offsite Rustic repository";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.rustic pkgs.rclone pkgs.coreutils pkgs.util-linux pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = homelabRusticProtonSecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/rustic-restore-smoke-test.sh";
      TimeoutStartSec = "12h";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.rustic-restore-smoke-test = {
    description = "Verify an offsite Rustic restore every week";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  users.users.${defaultHostUsername} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = defaultHostAuthorizedKeys;
  };

  # Passwordless sudo for wheel: any holder of an authorized SSH key gets root
  # with no second factor, for every command. Chosen deliberately for
  # non-interactive administration of this host.
  security.sudo.wheelNeedsPassword = false;

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # merlin is built by GitHub Actions and pushed to this cache, so a deploy here
  # is a download rather than a twenty minute rustc run on a desktop CPU.
  nix.settings.substituters = [
    "https://cache.nixos.org/"
    merlinCacheUrl
  ];
  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    merlinCacheKey
  ];

  # This records the original install version and must not be changed during upgrades.
  system.stateVersion = "25.11";
}
