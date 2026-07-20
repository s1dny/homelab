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
  };

  outputs = { self, deploy-rs, nixpkgs, sops-nix, ... }:
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

      nixosModules.default = { ... }: {
        imports = [
          sops-nix.nixosModules.sops
          ./nixos/homelab-module.nix
        ];
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
