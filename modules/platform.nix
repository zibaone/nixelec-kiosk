# =============================================================================
# Contrat `nixelec.platform.*` — les FAITS de la carte.
#
# Ce fichier ne configure rien : il déclare un vocabulaire. La couche carte le
# remplit (`nixelec.platform.cecDriver = "…"`), puis le câblage — profil de
# flotte ou module de compatibilité de la carte — recopie ces faits dans
# `nixelec.kiosk.*`. Le câblage vit là où les deux étages sont visibles ; c'est
# le seul endroit où une incohérence de contrat se lit.
#
# Une couche carte ne pose JAMAIS d'option `nixelec.kiosk.*` : elle publierait
# une politique de lecteur alors qu'elle ne connaît que du matériel, et devrait
# importer la couche kiosque — la dépendance s'inverserait.
#
# Tous les défauts sont nuls : ce fichier ne doit contenir aucun à-priori sur
# une famille de SoC, un nom de pilote ou un nom de connecteur.
# =============================================================================
{ lib, ... }:

{
  options.nixelec.platform = {
    cecDriver = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "cec-driver";
      description = ''
        Kernel module providing HDMI-CEC for this platform, or `null` when the
        board has no kernel CEC controller (Kodi can still drive a USB libCEC
        adapter in that case).

        The kiosk adds it to `boot.kernelModules` — which also puts it back in
        the allowlist of a pruned module tree — and reloads it for the CEC
        re-probe and hotplug recovery.
      '';
    };

    hdmiConnector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = ''
        DRM/kernel name of the HDMI connector, without the card prefix
        (`HDMI-A-1`, not `card0-HDMI-A-1`). Used to compose the `video=` kernel
        parameter and the `/sys/class/drm/card0-''${connector}/status` path the
        CEC hotplug watcher reads.

        `null` means the platform does not publish one: the kiosk then has no
        kernel CEC device name to watch, and hotplug recovery cannot be
        enabled.
      '';
    };

    videoMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "1920x1080@60";
      description = ''
        Preferred HDMI mode for this platform, as accepted by the kernel
        `video=''${connector}:''${mode}` parameter.

        It is a preference, not a force: never append the `D` suffix
        (`DRM_FORCE_ON_DIGITAL`) — the connector would report `connected`
        forever and a cable fault would become invisible.
      '';
    };

    watchdog = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this platform has a hardware watchdog proven on the board.
          A watchdog is only a benefit when it is known to reset the SoC
          instead of hanging the boot: publish `true` after measurement, not
          because a compatible string exists.
        '';
      };

      maxTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        example = 16;
        description = ''
          Hardware maximum watchdog timeout, in seconds, when it is known
          (`/sys/class/watchdog/watchdog0/max_timeout`). The kiosk keeps its
          own 15 s and fails at evaluation if the requested value exceeds this
          cap — a larger value only earns a silent capping warning at runtime.
        '';
      };
    };

    kodiPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The Kodi build that decodes on this platform: the `nix-v4l2-request`
        one on stateless-VPU SoCs, `pkgs.kodi-gbm` on x86 with VA-API.

        `null` means the card does not decide — the host or the fleet profile
        supplies the package. This is a fact, not a default: `nixelec.kiosk.package`
        has no default of its own, so a missing value fails at evaluation
        instead of silently producing a CPU-decoding kiosk.
      '';
    };
  };
}
