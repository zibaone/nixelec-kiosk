{
  description = "nixelec-kiosk — couche kiosque NixOS neutre (Kodi GBM, CEC, réglages)";

  # Seul input : nixpkgs. Cette couche ne connaît ni SoC, ni carte, ni flake
  # média. Le paquet Kodi est une option obligatoire, fournie par la carte ou
  # par le profil de flotte — voir modules/kodi-gbm.nix et docs/contrat.md.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      # Le module s'évalue sur les deux architectures ; les vérifications ne
      # sont construites que sur x86_64, faute de builder ARM ici.
      checksSystems = [ "x86_64-linux" ];

      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules = {
        default = self.nixosModules.kodi-gbm;

        # Kiosque complet : options nixelec.kiosk.* et service Kodi GBM.
        kodi-gbm = ./modules/kodi-gbm.nix;

        # Contrat seul : déclare nixelec.platform.* (les faits de la carte),
        # sans service. Une couche carte peut l'importer pour publier ses
        # faits même sur une image sans kiosque.
        platform = ./modules/platform.nix;
      };

      checks = nixpkgs.lib.genAttrs checksSystems (
        system:
        let
          pkgs = pkgsFor system;

          # Une configuration NixOS réelle, montée depuis l'exemple : le
          # forçage du drvPath évalue tout le système (unités CEC et réglages
          # compris) sans rien construire.
          exampleConfig = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.kodi-gbm
              ./examples/kiosk-gbm.nix
              {
                system.stateVersion = "26.05";
                boot.loader.grub.enable = false;
                # Le check n'a pas de disque : NixOS exige une racine déclarée
                # pour évaluer le toplevel.
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };
              }
            ];
          };
        in
        {
          formatting = pkgs.runCommand "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/flake.nix ${self}/modules/*.nix ${self}/examples/*.nix
            touch $out
          '';

          kiosk-eval =
            pkgs.runCommand "check-kiosk-eval"
              {
                drv = builtins.unsafeDiscardStringContext exampleConfig.config.system.build.toplevel.drvPath;
              }
              ''
                test -n "$drv"
                touch $out
              '';

          # CEC : les trois unités existent, et le module noyau chargé est
          # celui que l'exemple publie comme fait — jamais un nom en dur ici.
          cec-wiring =
            let
              cfg = exampleConfig.config;
            in
            pkgs.runCommand "check-cec-wiring"
              {
                reprobe = builtins.toJSON (builtins.hasAttr "hdmi-cec-reprobe" cfg.systemd.services);
                defaults = builtins.toJSON (builtins.hasAttr "kodi-cec-defaults" cfg.systemd.services);
                kodiUnit = builtins.toJSON (builtins.hasAttr "kodi-gbm" cfg.systemd.services);
                expected = cfg.nixelec.platform.cecDriver;
                modules = builtins.toJSON cfg.boot.kernelModules;
              }
              ''
                set -euo pipefail
                test "$reprobe" = "true"
                test "$defaults" = "true"
                test "$kodiUnit" = "true"
                case "$expected" in
                  "") echo "cecDriver vide alors que cec.enable est vrai" >&2; exit 1 ;;
                esac
                echo "$modules" | grep -q "\"$expected\""
                touch $out
              '';

          # `switch` ne doit pas redémarrer Kodi : un restart d'une unité
          # `Restart = always` peut échouer et fait sortir switch en 4.
          restart-policy =
            let
              kodi = exampleConfig.config.systemd.services.kodi-gbm;
            in
            pkgs.runCommand "check-restart-policy"
              {
                restartIfChanged = builtins.toJSON kodi.restartIfChanged;
                restart = builtins.toJSON kodi.serviceConfig.Restart;
              }
              ''
                set -euo pipefail
                test "$restartIfChanged" = "false"
                test "$restart" = '"always"'
                touch $out
              '';
        }
      );

      formatter = nixpkgs.lib.genAttrs checksSystems (system: (pkgsFor system).nixfmt);
    };
}
