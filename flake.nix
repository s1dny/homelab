{
  description = "Homelab NixOS module and deployment assets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ZeroClaw builds with fenix's stable Rust. Its own flake.lock pins fenix
    # seven months behind its source, yielding rustc 1.93.1 while the crate
    # requires 1.96.0, so pin fenix here and make ZeroClaw follow it. nixpkgs
    # rustc (1.95.0) is also too old.
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zeroclaw = {
      url = "github:zeroclaw-labs/zeroclaw";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
  };

  outputs = { self, deploy-rs, nixpkgs, sops-nix, zeroclaw, ... }:
    let
      system = "x86_64-linux";
    in {
      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (devSystem:
          let devPkgs = nixpkgs.legacyPackages.${devSystem};
          in {
            default = devPkgs.mkShell {
              packages = with devPkgs; [
                actionlint
                kubeconform
                kustomize
                shellcheck
                sops
              ];
            };
          });

      nixosModules.default = { pkgs, ... }: {
        imports = [
          sops-nix.nixosModules.sops
          zeroclaw.nixosModules.default
          ./nixos/homelab-module.nix
        ];

        services.zeroclaw.instances.kestral.package =
          zeroclaw.packages.${pkgs.stdenv.hostPlatform.system}.zeroclaw.overrideAttrs (old: {
            # Upstream sets no meta.mainProgram, so the module's `lib.getExe`
            # falls back to guessing the binary name and warns.
            meta = (old.meta or { }) // { mainProgram = "zeroclaw"; };

            # Upstream's nix/hashes.json is stale at this pin: it still lists
            # git-dependency hashes (wacore-0.6.0 and friends) while Cargo.lock
            # now resolves every crate from crates.io. buildRustPackage's own
            # cargoLock therefore aborts with "A hash was specified for
            # wacore-0.6.0, but there is no corresponding git dependency", so
            # upstream's package does not evaluate as published. Cargo.lock has
            # zero git deps, so re-import it without outputHashes.
            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = "${zeroclaw}/Cargo.lock";
            };
            # Only Matrix is used here; skip Discord/WhatsApp/Telegram/etc.
            cargoBuildFlags = [
              "-p"
              "zeroclaw"
              "--no-default-features"
              "--features"
              "agent-runtime,channel-matrix"
            ];
          });
      };

      nixosConfigurations.azalab-0 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos/hardware-configuration.nix
          self.nixosModules.default
          ({ ... }: {
            networking.hostName = "azalab-0";
          })
        ];
      };

      deploy.nodes.azalab-0 = {
        hostname = "azalab-0";
        sshUser = "aiden";
        interactiveSudo = true;
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.azalab-0;
          autoRollback = true;
          magicRollback = true;
        };
      };

      checks = builtins.mapAttrs
        (_: deployLib: deployLib.deployChecks self.deploy)
        deploy-rs.lib;
    };
}
