{
  description = "DevPush - Self-hosted deployment platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.devpush = import ./nix/module.nix self;
    nixosModules.default = self.nixosModules.devpush;

    # Test VM for development
    nixosConfigurations.test = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.devpush
        ({ pkgs, ... }: {
          # Minimal VM configuration
          system.stateVersion = "24.11";
          boot.loader.grub.device = "nodev";
          fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };

          # DevPush configuration
          services.devpush = {
            enable = true;
            settings = {
              appHostname = "devpush.test.local";
              deployDomain = "deploy.test.local";
              letsEncryptEmail = "test@test.local";
            };
            secretsFile = "/etc/devpush-secrets";
          };
        })
      ];
    };
  };
}
