{
  description = "Host bootstrap flake for homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    homelab.url = "github:s1dny/homelab";
  };

  outputs = { nixpkgs, homelab, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.azalab-0 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hardware-configuration.nix
          homelab.nixosModules.default
          ({ ... }: {
            networking.hostName = "azalab-0";
          })
        ];
      };
    };
}
