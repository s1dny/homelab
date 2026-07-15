{
  description = "Homelab NixOS module and deployment assets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { sops-nix, ... }: {
    nixosModules.default = { ... }: {
      imports = [
        sops-nix.nixosModules.sops
        ./nixos/homelab-module.nix
      ];
    };
  };
}
