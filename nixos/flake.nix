{
  description = "Host bootstrap flake for homelab";

  inputs = {
    homelab.url = "github:s1dny/homelab";
    nixpkgs.follows = "homelab/nixpkgs";
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
