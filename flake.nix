{
  description = "Homelab NixOS module and deployment assets";

  inputs = {
    sops-nix.url = "github:Mic92/sops-nix";
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
