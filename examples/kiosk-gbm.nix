# Exemple de kiosque — et de **câblage** faits de carte → options du kiosque.
#
# Ce fichier ne sert pas de profil de production : il montre le contrat en
# entier sur une plateforme imaginaire. En vrai, les faits `nixelec.platform.*`
# sont publiés par la couche carte et le câblage vit dans le profil de flotte
# (ou dans le module de compatibilité de la carte) — jamais dans la couche
# carte elle-même, qui ne doit poser aucune option `nixelec.kiosk.*`.
#
# ⚠️  `pkgs.kodi-gbm` n'est PAS le paquet d'un SBC : il n'embarque pas le
# décodeur DRMPRIME de `nix-v4l2-request`, donc Kodi décode en CPU sans le dire.
# Sur un SoC à VPU stateless, remplacer `kodiPackage` par le kodi du flake
# média (`packages.<system>.kodi-kiosk`).
{ config, pkgs, ... }:

{
  # 1. Les faits, tels que la couche carte les publierait.
  nixelec.platform = {
    cecDriver = "dw-hdmi-cec";
    hdmiConnector = "HDMI-A-1";
    videoMode = "1920x1080@60";
    watchdog = {
      enable = true;
      maxTimeout = 16;
    };
    kodiPackage = pkgs.kodi-gbm; # démo x86/VAAPI — voir l'avertissement plus haut
  };

  # 2. Le câblage : la seule recopie autorisée, et le seul endroit où une
  #    incohérence de contrat se lit.
  nixelec.kiosk = {
    enable = true;
    package = config.nixelec.platform.kodiPackage;

    cec = {
      enable = true;
      driver = config.nixelec.platform.cecDriver;
      connector = "card0-${config.nixelec.platform.hdmiConnector}";
      hotplugRecovery = true;
      reprobeOnBoot = true;
    };

    watchdog.enable = config.nixelec.platform.watchdog.enable;

    extraKernelParams = [
      "video=${config.nixelec.platform.hdmiConnector}:${config.nixelec.platform.videoMode}"
    ];

    # 3. La politique du kiosque, elle, ne dépend d'aucun matériel.
    uiSounds = true;
    homeMenu.hidden = [
      "music"
      "weather"
      "musicvideos"
      "radio"
      "pictures"
      "games"
    ];
  };
}
