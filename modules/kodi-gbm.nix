# =============================================================================
# Kiosque Kodi GBM — couche neutre : aucun nom de SoC, aucun pilote en dur.
#
# Ce module décrit l'appliance, pas la carte :
#   - Kodi en DRM direct (GBM), sans compositeur ni X11 ;
#   - utilisateur, HOME, PipeWire, réglages Kodi appliqués avant chaque départ ;
#   - CEC : unités, re-probe et reprise après hotplug, sur un pilote et un
#     connecteur fournis par la carte (`nixelec.platform`) ;
#   - watchdog matériel, plafonné par ce que la carte publie.
#
# Deux contrats, un seul vocabulaire matériel :
#   nixelec.platform.*  faits publiés par la couche carte (cecDriver,
#                       hdmiConnector, videoMode, watchdog, kodiPackage) ;
#   nixelec.kiosk.*     options consommées par l'hôte et le profil de flotte.
# Le câblage de l'un vers l'autre n'est PAS ici : voir docs/contrat.md.
#
# Le paquet Kodi n'a pas de valeur par défaut, volontairement. Sur un SBC,
# `pkgs.kodi-gbm` n'embarque pas le décodeur de `nix-v4l2-request` :
# `CDVDVideoCodecDRMPRIME::Create()` renvoie nullptr, Kodi décode en CPU et ne
# le dit pas. Une erreur d'évaluation explicite vaut mieux qu'un kiosque qui
# semble marcher en brûlant son CPU.
#
# Le rendu, lui, ne demande aucun réglage : voir docs/contrat.md §Rendu.
# =============================================================================
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.kiosk;
  platform = config.nixelec.platform;

  # Estuary stores these booleans in addon_data/skin.estuary/settings.xml.
  homeMenuSettings = {
    movies = "homemenunomoviebutton";
    tvshows = "homemenunotvshowbutton";
    music = "homemenunomusicbutton";
    musicvideos = "homemenunomusicvideobutton";
    livetv = "homemenunotvbutton";
    radio = "homemenunoradiobutton";
    games = "homemenunogamesbutton";
    programs = "homemenunoprogramsbutton";
    pictures = "homemenunopicturesbutton";
    videos = "homemenunovideosbutton";
    favourites = "homemenunofavbutton";
    weather = "homemenunoweatherbutton";
  };

  # Kodi CEC adapter values: 13011 follows the TV, 36028 keeps the appliance
  # running.
  cecStandbyValues = {
    default = "13011";
    ignore = "36028";
  };
  cecStandbyValue = cecStandbyValues.${cfg.cec.standbyPcOnTvStandby};

  # `addons = null` must leave the package untouched so the default store
  # paths and the published cache stay valid.
  kodiPackage = if cfg.addons == null then cfg.package else cfg.package.withPackages cfg.addons;

  # systemd accepts any time span ("15s", "1min", "500ms"). Only the plain
  # seconds form can be checked against the hardware cap published by the
  # platform; anything else is left unchecked rather than mis-parsed.
  secondsOf =
    value:
    let
      m = builtins.match "([0-9]+)s" value;
    in
    if m == null then null else lib.toInt (lib.head m);

  exceedsWatchdogCap =
    value:
    let
      seconds = secondsOf value;
    in
    platform.watchdog.maxTimeout != null && seconds != null && seconds > platform.watchdog.maxTimeout;
in
{
  imports = [ ./platform.nix ];

  options.nixelec.kiosk = {
    enable = lib.mkEnableOption "Kodi GBM kiosk, without a compositor";

    package = lib.mkOption {
      type = lib.types.package;
      # Deliberately no default: see the header and docs/contrat.md §Le paquet.
      description = ''
        Kodi package to launch. Required as soon as the kiosk is enabled — the
        module refuses to guess, because the wrong package decodes in software
        without any error (no `v4l2-request` → `CDVDVideoCodecDRMPRIME::Create()`
        returns nullptr).

        Supply the `nix-v4l2-request` build on a stateless-VPU SoC
        (`packages.<system>.kodi-kiosk`) and `pkgs.kodi-gbm` on x86 (VA-API).
        A card can publish its own choice as `nixelec.platform.kodiPackage`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kodi";
      description = "User that runs Kodi.";
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kodi";
      description = "Kodi user home directory.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "video"
        "audio"
        "input"
        "render"
        "tty"
      ];
      description = "Additional groups for the Kodi user.";
    };

    extraKernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra kernel parameters for the kiosk. Only defined when non-empty: an
        unconditional empty list at normal priority would drop the `mkDefault`
        parameters of the card layer (`console=`, `cma=`…).
      '';
    };

    addons = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo (lib.types.listOf lib.types.package));
      default = null;
      description = ''
        Function that receives the Kodi package set and returns extra add-ons,
        for example `kodi: with kodi; [ inputstream-adaptive ]`.
        When null, `package` is used unchanged.
      '';
    };

    autoEnableAddons = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Add-on IDs to enable at boot through the local Kodi JSON-RPC socket.
        Kodi leaves add-ons installed by Nix disabled until an install event
        occurs, so the generic workaround is an explicit SetAddonEnabled call.
      '';
    };

    audio = {
      hdmiPcm = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hw:1,0";
        description = ''
          ALSA PCM of the HDMI output, when that card exposes no mixer and ACP
          builds no profile for it.

          Without this, PipeWire publishes no HDMI sink: Kodi enumerates none,
          silently falls back to the analog output, and the television stays
          mute while the whole chain looks healthy. Setting it exposes the raw
          PCM as a PipeWire sink named `alsa_output.hdmi` and points Kodi at it.
        '';
      };
    };

    webServer = {
      enable = lib.mkEnableOption "Kodi web server (HTTP Basic, LAN)";

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Runtime path to a file containing the Kodi web server password.
          Required when the web server is enabled; the file is read by a
          root oneshot and never copied into the Nix store.
        '';
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "kodi";
        description = "Kodi web server username.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Kodi web server TCP port.";
      };
    };

    uiSounds = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable Kodi UI sounds (guisoundmode=0, empty soundskin).";
    };

    cpuGovernor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "schedutil";
      description = ''
        CPU frequency governor applied at boot. A mains-powered appliance does
        not need `ondemand`: schedutil reacts on scheduler load instead of
        polling, so a scene does not start on a late frequency ramp. The value
        is skipped when the platform does not offer it; `null` leaves the
        kernel default alone.
      '';
    };

    watchdog = {
      enable = lib.mkEnableOption "systemd hardware watchdog (hang recovery)";

      runtimeTime = lib.mkOption {
        type = lib.types.str;
        default = "15s";
        description = ''
          Runtime watchdog timeout. Kept below the hardware maximum, which the
          platform publishes as `nixelec.platform.watchdog.maxTimeout` when it
          is known: the evaluation fails instead of letting the kernel cap the
          value with a warning nobody reads.
        '';
      };

      rebootTime = lib.mkOption {
        type = lib.types.str;
        default = "15s";
        description = "Watchdog timeout for the reboot and shutdown sequence.";
      };
    };

    homeMenu.hidden = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames homeMenuSettings));
      default = [ ];
      description = "Estuary home menu items to hide.";
    };

    cec = {
      enable = lib.mkEnableOption "HDMI-CEC support for the Kodi appliance";

      driver = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "cec-driver";
        description = ''
          Kernel CEC module to load for this platform, usually copied from
          `nixelec.platform.cecDriver`. `null` keeps the CEC units that need a
          kernel device disabled; `cec.enable` alone still works when Kodi
          drives a USB libCEC adapter.
        '';
      };

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/cec0";
        description = "CEC device used by the helper services.";
      };

      connector = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "card0-HDMI-A-1";
        description = ''
          DRM connector checked before restarting Kodi after a hotplug, as it
          appears under `/sys/class/drm/` (with the card prefix). Composed by
          the wiring from `nixelec.platform.hdmiConnector`.

          `null` means "no connector to watch": hotplug recovery cannot be
          enabled without it, and the evaluation says so.
        '';
      };

      standbyPcOnTvStandby = lib.mkOption {
        type = lib.types.enum [
          "default"
          "ignore"
        ];
        default = "ignore";
        description = ''
          Kodi CEC policy when the TV goes to standby. `ignore` keeps the
          appliance running; `default` leaves Kodi's default behaviour.
        '';
      };

      manageAdapterSettings = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create or update the Kodi CEC adapter settings before Kodi starts.";
      };

      reprobeOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Reload the CEC module at boot when the CEC physical address is invalid.";
      };

      hotplugRecovery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Restart Kodi after an HDMI hotplug when the CEC physical address is
          invalid. This is a workaround for a kernel-level CEC issue; enable it
          only when the TV actually loses CEC after standby, and only on a
          platform that publishes both a CEC driver and a connector.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.webServer.enable || (cfg.webServer.passwordFile != null && cfg.webServer.passwordFile != "");
        message = "nixelec.kiosk.webServer.passwordFile must be set when the web server is enabled.";
      }
      {
        assertion = !cfg.cec.enable || !cfg.cec.reprobeOnBoot || cfg.cec.driver != null;
        message = ''
          nixelec.kiosk.cec.reprobeOnBoot needs a kernel CEC driver: set
          nixelec.kiosk.cec.driver (usually from nixelec.platform.cecDriver), or
          disable reprobeOnBoot.
        '';
      }
      {
        assertion =
          !cfg.cec.enable
          || !cfg.cec.hotplugRecovery
          || (cfg.cec.driver != null && cfg.cec.connector != null);
        message = ''
          nixelec.kiosk.cec.hotplugRecovery needs both a kernel CEC driver and
          the DRM connector to watch: set nixelec.kiosk.cec.driver and
          nixelec.kiosk.cec.connector (from nixelec.platform.cecDriver and
          nixelec.platform.hdmiConnector), or disable hotplugRecovery.
        '';
      }
      {
        assertion =
          !cfg.watchdog.enable
          || !(exceedsWatchdogCap cfg.watchdog.runtimeTime || exceedsWatchdogCap cfg.watchdog.rebootTime);
        message = ''
          nixelec.kiosk.watchdog: timeout above the hardware cap published by
          the platform (nixelec.platform.watchdog.maxTimeout = ${toString platform.watchdog.maxTimeout} s).
          Lower runtimeTime/rebootTime, or fix the cap if the platform value is
          wrong.
        '';
      }
    ];

    # Hardware watchdog: PID 1 pings it, so a hard hang restarts the appliance
    # instead of leaving it frozen until a power cycle. Only enabled where the
    # platform publishes a proven watchdog — see nixelec.platform.watchdog.
    systemd.settings.Manager = lib.mkIf cfg.watchdog.enable {
      RuntimeWatchdogSec = cfg.watchdog.runtimeTime;
      RebootWatchdogSec = cfg.watchdog.rebootTime;
    };

    # The governor is written directly instead of going through
    # `powerManagement.cpuFreqGovernor`: that option also loads
    # `cpufreq_<governor>` as a module, and schedutil can be built into the
    # kernel — `modprobe cpufreq_schedutil` then fails, which would leave
    # `systemd-modules-load` failed. The guard makes the unit a no-op on a
    # platform that does not offer the requested governor.
    systemd.services.cpu-governor = lib.mkIf (cfg.cpuGovernor != null) {
      description = "Set the CPU frequency governor to ${cfg.cpuGovernor}";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        applied=0
        for policy in /sys/devices/system/cpu/cpufreq/policy*; do
          [ -r "$policy/scaling_available_governors" ] || continue
          read -r available < "$policy/scaling_available_governors" || continue
          case " $available " in
            *" ${cfg.cpuGovernor} "*) ;;
            *) continue ;;
          esac
          echo "${cfg.cpuGovernor}" > "$policy/scaling_governor" || continue
          applied=$((applied + 1))
        done
        echo "cpu-governor: ${cfg.cpuGovernor} applied to $applied policy(ies)"
      '';
    };

    systemd.services.kodi-gbm = {
      description = "Kodi (direct GBM, no compositor)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-user-sessions.service"
        "sound.target"
      ];
      conflicts = [ "getty@tty1.service" ];
      # Restarting a `Restart = "always"` service during `switch` can fail and
      # makes `nixos-rebuild switch` return 4. A changed Kodi unit takes
      # effect on the next boot instead.
      restartIfChanged = false;
      serviceConfig = {
        User = cfg.user;
        Group = "users";
        PAMName = "login";
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
        StandardInput = "tty";
        # The VT stays allocated (StandardInput=tty + TTYPath), but Kodi's own
        # output no longer paints the TV: with `journal+console` and the kernel
        # default `loglevel=7`, every restart showed a screenful of logs in the
        # ~40 s before Kodi takes DRM master.
        StandardOutput = "journal";
        StandardError = "journal";
        ExecStart = "${kodiPackage}/bin/kodi --standalone --windowing=gbm";
        Restart = "always";
        # SIGTERM (128+15) is how hdmi-cec-hotplug stops Kodi on purpose.
        # Without this, systemd logs "Failed with result 'exit-code'" on
        # every restart.
        SuccessExitStatus = [ 143 ];
      };
    };

    # Kodi rewrites guisettings.xml on shutdown, so the managed settings
    # must be applied before every start, not shipped as a static file.
    systemd.services.kodi-settings =
      lib.mkIf (cfg.webServer.enable || cfg.uiSounds || cfg.homeMenu.hidden != [ ])
        {
          description = "Apply Kodi settings before Kodi starts";
          after = [ "local-fs.target" ];
          before = [ "kodi-gbm.service" ];
          requiredBy = [ "kodi-gbm.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail

            settings="${cfg.home}/.kodi/userdata/guisettings.xml"
            skin_settings="${cfg.home}/.kodi/userdata/addon_data/skin.estuary/settings.xml"
            ${lib.optionalString cfg.webServer.enable ''
              password_file="${cfg.webServer.passwordFile}"
              # Le secret peut manquer au premier boot : carte fraîche, clé
              # d'hôte régénérée donc agenix indéchiffrable, ou fichier pas
              # encore provisionné. Un kiosque sans serveur web reste un
              # kiosque ; un kiosque qui ne démarre pas est une télévision
              # noire — et `kodi-gbm` est en `Requires=` sur cette unité.
              # On dégrade, on le dit, Kodi démarre.
              if [ -s "$password_file" ]; then
                password="$(${pkgs.coreutils}/bin/cat "$password_file")"
              fi
              if [ -n "''${password:-}" ]; then
                webserver=1
              else
                webserver=0
                echo "kodi-settings: $password_file absent ou vide — serveur web désactivé" >&2
              fi
            ''}

            ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0700 "${cfg.home}/.kodi/userdata"
            # `install -d` n'applique -o/-g qu'au dernier répertoire : sans la
            # ligne sur `addon_data` seul, il est créé root:root et Kodi (uid
            # kodi) ne peut plus écrire dans addon_data/<addon> — les greffons
            # échouent en « Permission denied » au premier accès.
            ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0755 "${cfg.home}/.kodi/userdata/addon_data"
            ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0755 "${cfg.home}/.kodi/userdata/addon_data/skin.estuary"
            if [ ! -e "$settings" ]; then
              ${pkgs.coreutils}/bin/printf '%s\n' \
                '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
                '<settings version="2">' \
                '    <setting id="services.webserver" default="true">false</setting>' \
                '    <setting id="services.esallinterfaces" default="true">false</setting>' \
                '    <setting id="services.webserverauthentication" default="true">true</setting>' \
                '    <setting id="services.webserverusername" default="true">kodi</setting>' \
                '    <setting id="services.webserverpassword" default="true" />' \
                '    <setting id="services.webserverport" default="true">8080</setting>' \
                '    <setting id="services.webserverssl" default="true">false</setting>' \
                '    <setting id="services.zeroconf" default="true">true</setting>' \
                '    <setting id="audiooutput.guisoundmode" default="true">1</setting>' \
                '    <setting id="lookandfeel.soundskin" default="true">resource.uisounds.kodi</setting>' \
                '</settings>' > "$settings"
            fi

            # Kodi marks default values with default="true" and ignores the text
            # in that case; non-default values must drop the attribute.
            #
            # UI sounds: guisoundmode=0 disables them; soundskin must be empty,
            # not "OFF" (Kodi logs "Unknown sounds addon 'OFF'").
            args=(
              ${lib.optionalString cfg.uiSounds ''
                -u "//setting[@id='audiooutput.guisoundmode']" -v 0
                -u "//setting[@id='lookandfeel.soundskin']" -v ""
                -d "//setting[@id='audiooutput.guisoundmode']/@default"
                -d "//setting[@id='lookandfeel.soundskin']/@default"
              ''}
            )
            ${lib.optionalString (cfg.audio.hdmiPcm != null) ''
              # Sink brut exposé par le kiosque : on le nomme explicitement, sinon
              # Kodi choisit « Default » et suit le sink par défaut de PipeWire.
              args+=(
                -u "//setting[@id='audiooutput.audiodevice']" -v "PIPEWIRE:alsa_output.hdmi"
                -d "//setting[@id='audiooutput.audiodevice']/@default"
              )
            ''}
            ${lib.optionalString cfg.webServer.enable ''
              if [ "''${webserver:-0}" = 1 ]; then
                args+=(
                  -u "//setting[@id='services.webserver']" -v true
                  -u "//setting[@id='services.esallinterfaces']" -v true
                  -u "//setting[@id='services.webserverauthentication']" -v true
                  -u "//setting[@id='services.webserverusername']" -v "${cfg.webServer.username}"
                  -u "//setting[@id='services.webserverpassword']" -v "$password"
                  -u "//setting[@id='services.webserverport']" -v "${toString cfg.webServer.port}"
                  -u "//setting[@id='services.webserverssl']" -v false
                  -u "//setting[@id='services.zeroconf']" -v true
                  -d "//setting[@id='services.webserver']/@default"
                  -d "//setting[@id='services.esallinterfaces']/@default"
                  -d "//setting[@id='services.webserverpassword']/@default"
                )
              else
                args+=(
                  -u "//setting[@id='services.webserver']" -v false
                  -d "//setting[@id='services.webserver']/@default"
                )
              fi
            ''}
            if [ "''${#args[@]}" -gt 0 ]; then
              ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L "''${args[@]}" "$settings"
            fi

            ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$settings"
            ${pkgs.coreutils}/bin/chmod 0600 "$settings"

            ${lib.optionalString (cfg.homeMenu.hidden != [ ]) ''
              if [ ! -e "$skin_settings" ]; then
                ${pkgs.coreutils}/bin/printf '%s\n' \
                  '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
                  '<settings>' \
                  '</settings>' > "$skin_settings"
              fi
              ${lib.concatStrings (
                map (item: ''
                  id="${homeMenuSettings.${item}}"
                  xpath="//setting[@id=\"''${id}\"]"
                  if [ "$(${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -v "count(''${xpath})" "$skin_settings")" = "0" ]; then
                    ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
                      -s /settings -t elem -n setting -v true \
                      -i "/settings/setting[last()]" -t attr -n id -v "$id" \
                      -i "/settings/setting[last()]" -t attr -n type -v bool \
                      "$skin_settings"
                  else
                    ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L -u "''${xpath}" -v true "$skin_settings"
                  fi
                '') cfg.homeMenu.hidden
              )}
              ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$skin_settings"
              ${pkgs.coreutils}/bin/chmod 0644 "$skin_settings"
            ''}
          '';
        };

    # Kodi leaves add-ons installed by Nix disabled: there was no install
    # event, so an explicit SetAddonEnabled call is needed. Keep the unit
    # independent from the Kodi restart cycle (no `PartOf=`): on a switch the
    # restart would kill the activation and the switch can return 4.
    systemd.services.kodi-addons = lib.mkIf (cfg.autoEnableAddons != [ ]) {
      description = "Enable Kodi add-ons installed by Nix";
      wantedBy = [ "multi-user.target" ];
      after = [ "kodi-gbm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 240;
      };
      script = ''
        set -u

        # Kodi does not terminate its JSON-RPC responses with a newline, so
        # `read -t` always times out and leaves the bytes in the variable.
        # Accumulate short reads until the response id appears.
        rpc() {
          (
            resp=""
            chunk=""
            exec {fd}<>/dev/tcp/127.0.0.1/9090 || exit 1
            printf '%s' "$1" >&"$fd"
            for _ in $(${pkgs.coreutils}/bin/seq 1 25); do
              IFS= read -r -t 0.4 chunk <&"$fd" || true
              resp="$resp''${chunk:-}"
              chunk=""
              case "$resp" in
                *"\"id\":$2,"*) break ;;
              esac
            done
            exec {fd}<&-
            printf '%s' "$resp"
          ) 2>/dev/null
        }

        ready=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 90); do
          if rpc '{"jsonrpc":"2.0","id":0,"method":"JSONRPC.Ping"}' 0 | ${pkgs.gnugrep}/bin/grep -q pong; then
            ready=1
            break
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        if [ "$ready" != 1 ]; then
          echo "JSON-RPC unavailable after 180 s" >&2
          exit 1
        fi

        id=1
        for a in ${lib.escapeShellArgs cfg.autoEnableAddons}; do
          id=$((id + 1))
          out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"Addons.SetAddonEnabled\",\"params\":{\"addonid\":\"$a\",\"enabled\":true}}" "$id")
          case "$out" in
            *'"result":"OK"'*) echo "enabled: $a" ;;
            *) echo "failed: $a -> $out" >&2 ;;
          esac
        done
      '';
    };

    users.users.${cfg.user} = {
      isNormalUser = true;
      home = cfg.home;
      createHome = true;
      extraGroups = cfg.extraGroups;
    };

    hardware.graphics.enable = lib.mkDefault true;

    security.rtkit.enable = true;
    # `LimitRTPRIO = 95` alone is not enough when the kernel is built with
    # CONFIG_RT_GROUP_SCHED=y and keeps the default RT throttling: rtkit sets
    # RLIMIT_RTPRIO=0 and relies on CAP_SYS_NICE, and sched_setscheduler then
    # returns EPERM even for root. Disabling the throttle lets rtkit grant
    # RT, so PipeWire's data-loop becomes SCHED_RR/20.
    boot.kernel.sysctl."kernel.sched_rt_runtime_us" = -1;
    systemd.services.rtkit-daemon.serviceConfig.LimitRTPRIO = 95;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # WirePlumber 0.5 creates every sink at `device.routes.default-sink-volume`
    # = 0.064 linear, i.e. 40 % as `wpctl get-volume` prints it (cubic) —
    # 0.064 = 0.40³ ≈ −24 dB. Kodi never touches that: its own "100 %" is the
    # volume of its *stream*, not of the sink, so the kiosk played 24 dB below
    # the source with the on-screen volume bar at full. When the HDMI codec
    # exposes no mixer (`route.hw-volume=false`, the sink carries
    # `softVolumes`), this software volume is the one and only attenuation in
    # the chain.
    services.pipewire.wireplumber.extraConfig."51-default-sink-volume" = {
      "wireplumber.settings"."device.routes.default-sink-volume" = 1.0;
    };

    # Carte HDMI sans aucun contrôle de mixer : ACP ne peut pas construire de
    # profil, donc PipeWire ne publie **aucun** sink pour elle. Kodi n'énumère
    # alors rien et retombe sur l'analogique — la TV reste muette alors que le
    # PCM HDMI fonctionne (vérifié avec `ffmpeg -f alsa hw:1,0`, stéréo 48 kHz).
    # On expose le PCM brut comme sink et on le passe par défaut.
    environment.etc."pipewire/pipewire.conf.d/50-hdmi-pcm.conf" = lib.mkIf (cfg.audio.hdmiPcm != null) {
      text = ''
        context.objects = [
          { factory = adapter
            args = {
              factory.name     = api.alsa.pcm.sink
              node.name        = "alsa_output.hdmi"
              node.description = "HDMI"
              media.class      = "Audio/Sink"
              api.alsa.path    = "${cfg.audio.hdmiPcm}"
              audio.channels   = 2
              audio.rate       = 48000
            }
          }
        ]
      '';
    };

    services.pipewire.wireplumber.extraConfig."52-hdmi-default" = lib.mkIf (cfg.audio.hdmiPcm != null) {
      "wireplumber.settings"."default.configured.audio.sink" = {
        name = "alsa_output.hdmi";
      };
    };

    services.xserver.enable = lib.mkDefault false;
    documentation.enable = lib.mkDefault false;
    nix.registry = lib.mkForce { };

    # Only defined when the host asks for extras: an empty definition at
    # normal priority would erase the card layer's `mkDefault` parameters.
    boot.kernelParams = lib.mkIf (cfg.extraKernelParams != [ ]) cfg.extraKernelParams;

    # The appliance's only display is the TV, and the VT behind Kodi is what
    # shows during a kiosk restart. A card layer may keep 7 for UART bring-up,
    # so the kiosk overrides it at priority 50: it beats that `mkDefault`
    # without blocking a consumer's own plain definition.
    boot.consoleLogLevel = lib.mkOverride 50 3;

    # `boot.kernelModules` both loads the module at boot and, on a pruned
    # module tree, puts it back in the allowlist. No driver name is written
    # here: the platform publishes it.
    boot.kernelModules = lib.optional (cfg.cec.enable && cfg.cec.driver != null) cfg.cec.driver;

    # At cold boot, some CEC controllers keep an invalid
    # physical address (f.f.f.f) when the first EDID read fails. Reloading the
    # module after the device appears makes it pick up the connector address.
    systemd.services.hdmi-cec-reprobe =
      lib.mkIf (cfg.cec.enable && cfg.cec.reprobeOnBoot && cfg.cec.driver != null)
        {
          description = "Re-probe ${cfg.cec.driver} to pick up the HDMI physical address";
          wantedBy = [ "multi-user.target" ];
          after = [ "kodi-settings.service" ];
          before = [ "kodi-gbm.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.kmod}/bin/modprobe ${cfg.cec.driver} 2>/dev/null || true
            for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -e ${cfg.cec.device} ] && break
              ${pkgs.coreutils}/bin/sleep 0.2
            done
            if [ ! -e ${cfg.cec.device} ]; then
              echo "CEC device ${cfg.cec.device} absent, nothing to re-probe"
              exit 0
            fi
            phys=$(${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
              | ${pkgs.gnused}/bin/sed "s/.*: *//")
            echo "CEC physical address before: $phys"
            if [ "$phys" = "f.f.f.f" ]; then
              ${pkgs.kmod}/bin/modprobe -r ${cfg.cec.driver} 2>/dev/null || true
              ${pkgs.kmod}/bin/modprobe ${cfg.cec.driver} 2>/dev/null || true
              ${pkgs.coreutils}/bin/sleep 1
              phys=$(${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null \
                | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
                | ${pkgs.gnused}/bin/sed "s/.*: *//")
              echo "CEC physical address after: $phys"
            fi
          '';
        };

    # A CEC controller invalidates its address on HPD loss. A
    # Kodi modeset re-reads the EDID and re-arms the notifier, so restart Kodi
    # only when no logical address is claimed and the sink is connected. A real
    # hotplug burst can also leave the controller unable to claim a logical
    # address: the physical address comes back, but `polling for LA` keeps
    # failing (tx_status 0x0030 = CEC_TX_STATUS_ERROR|MAX_RETRIES), so CEC stays
    # dead until the module is reloaded. Hence the restart is verified against
    # the logical address mask, with one module reload as a fallback.
    systemd.services.hdmi-cec-hotplug = lib.mkIf (cfg.cec.enable && cfg.cec.hotplugRecovery) {
      description = "Restore the CEC physical address after an HDMI hotplug";
      unitConfig = {
        # This unit is triggered by udev on every DRM `change` event, and a
        # single HDMI hotplug burst emits several in a row (5 events in 1.2 s
        # measured on one board). With 3 starts / 300 s the service hit
        # start-limit-hit exactly when it was needed (29 occurrences in an
        # audit). The script is idempotent and already rate-limits its own
        # Kodi restart with /run/hdmi-cec-hotplug.stamp, so the systemd limit
        # only has to stop a runaway trigger loop.
        StartLimitIntervalSec = 60;
        StartLimitBurst = 10;
      };
      serviceConfig = {
        Type = "oneshot";
        # Worst case: 3 s settle + 80 s Kodi window + 8 s re-probe settle
        # + 80 s second Kodi window + module reload + 80 s window + 8 s
        # settle. Retrying through a Kodi restart (instead of a cec-ctl
        # claim) added a full 80 s window, so the cap moved from 300 s to
        # 420 s: a cap that expires mid-recovery leaves CEC dead silently.
        TimeoutStartSec = 420;
      };
      script = ''
        stamp=/run/hdmi-cec-hotplug.stamp

        cec_ctl() {
          ${pkgs.v4l-utils}/bin/cec-ctl -d ${cfg.cec.device} -S 2>/dev/null
        }

        cec_la_mask() {
          cec_ctl \
            | ${pkgs.gnugrep}/bin/grep -i -m1 "Logical Address Mask" \
            | ${pkgs.gnugrep}/bin/grep -o -m1 "0x[0-9a-fA-F]*" || true
        }

        # The "Reply Vendor ID" capability line has no value, hence the colon.
        cec_vendor() {
          cec_ctl \
            | ${pkgs.gnugrep}/bin/grep -i -m1 "Vendor ID *:" \
            | ${pkgs.gnugrep}/bin/grep -o -m1 "0x[0-9a-fA-F]*" || true
        }

        # A logical address is not the goal: the TV remote only comes back
        # when *libCEC* owns it. libCEC (Kodi) declares the Pulse-Eight vendor
        # ID on the adapter, while `cec-ctl --playback` declares 0x000c03
        # (HDMI). Measured once: mask 0x0010 owned by cec-ctl, cec-ctl -S
        # showing PA + LA + TV, recovery reporting success — and the remote
        # dead until Kodi was restarted. Hence the mask is always read
        # together with its owner.
        cec_owned_by_libcec() {
          [ "$(cec_vendor)" = "0x001582" ]
        }

        # 0x0000 means the adapter claimed no logical address at all, and
        # 0x8000 is LA 15 ("unregistered"): broadcast-only, not addressable,
        # and most TVs ignore it. Neither counts as a usable claim — accepting
        # 0x8000 was a false positive at cold boot.
        cec_has_la() {
          mask=$(cec_la_mask)
          [ -n "$mask" ] || return 1
          [ $(( mask & 0x7fff )) -ne 0 ]
        }

        # Give Kodi modeset up to 80 s to claim a logical address. Kodi only
        # configures CEC ~30 s after it starts, and the first poll can fail
        # (tx_status 0x0030) while the controller is still settling: the window
        # must cover that attempt, otherwise the check runs too early.
        wait_la() {
          for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
            ${pkgs.coreutils}/bin/sleep 2
            if cec_has_la; then
              return 0
            fi
          done
          return 1
        }

        claim_via_kodi() {
          echo "restarting Kodi so libCEC claims the logical address itself"
          ${config.systemd.package}/bin/systemctl --no-block restart kodi-gbm.service
          wait_la && cec_owned_by_libcec
        }

        # A kernel that re-probes the EDID after a failed read resets the CEC
        # controller on each attempt: a logical address read inside that
        # window is a false positive, the last re-probe erases it right after
        # the service reported success. Wait out the window, then verify, and
        # restart Kodi once more if the address is gone.
        #
        # The retry must be a Kodi restart, never `cec-ctl --playback`:
        # cec-ctl puts an address on the wire but leaves libCEC without one,
        # and libCEC does not retry on its own — CEC then looks healthy while
        # the TV remote does nothing.
        settle_and_verify() {
          ${pkgs.coreutils}/bin/sleep 8
          if cec_has_la && cec_owned_by_libcec; then
            return 0
          fi
          echo "CEC logical address lost during the kernel EDID re-probe window (mask $(cec_la_mask), vendor $(cec_vendor))"
          claim_via_kodi
        }

        ${pkgs.coreutils}/bin/sleep 3
        ${config.systemd.package}/bin/systemctl is-active --quiet kodi-gbm.service || exit 0
        [ -e ${cfg.cec.device} ] || exit 0
        [ "$(${pkgs.coreutils}/bin/cat /sys/class/drm/${cfg.cec.connector}/status)" = "connected" ] || exit 0

        if cec_has_la && settle_and_verify; then
          echo "CEC logical address present, nothing to recover"
          ${pkgs.coreutils}/bin/rm -f "$stamp"
          exit 0
        fi

        phys=$(cec_ctl \
          | ${pkgs.gnugrep}/bin/grep -m1 "Physical Address" \
          | ${pkgs.gnused}/bin/sed "s/.*: *//")
        echo "CEC after hotplug: physical address $phys, logical address mask $(cec_la_mask)"

        if [ "$phys" = "f.f.f.f" ]; then
          if [ -e "$stamp" ] && [ $(( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$stamp") )) -lt 300 ]; then
            echo "CEC recovery already attempted recently, skip"
            exit 0
          fi
          ${pkgs.coreutils}/bin/touch "$stamp"
          echo "CEC physical address invalid after hotplug, restarting Kodi"
          ${config.systemd.package}/bin/systemctl --no-block restart kodi-gbm.service
          if wait_la && settle_and_verify; then
            echo "CEC logical address claimed by libCEC after the Kodi restart (mask $(cec_la_mask))"
            ${pkgs.coreutils}/bin/rm -f "$stamp"
            exit 0
          fi
          echo "CEC logical address still missing after the Kodi restart (mask $(cec_la_mask), vendor $(cec_vendor))"
        fi

        # The rung that used to claim the address with `cec-ctl --playback` is
        # gone: it put a mask on the wire but left libCEC without an address,
        # so the service reported success while the TV remote stayed dead. A
        # libCEC-owned address only comes back from a Kodi restart, which
        # `settle_and_verify` already performs; when that fails the module
        # reload below is the remaining rung.

        # After an HDMI HPD burst the controller can stay in
        # CEC_STAT_ERROR_INIT, so restarting Kodi is not enough. Reloading the
        # module re-initialises the block and lets Kodi claim the address again.
        #
        # KNOWN HAZARD: this unloads the module while Kodi still holds the CEC
        # device, which is a use-after-free in cec_devnode_release and costs a
        # power cycle. Reordering it (stop the kiosk, wait for kodi.bin to
        # exit, reload, start) has to be replayed on the board first.
        echo "Reloading ${cfg.cec.driver} to re-initialise the CEC controller"
        ${pkgs.kmod}/bin/modprobe -r ${cfg.cec.driver} 2>/dev/null || true
        ${pkgs.kmod}/bin/modprobe ${cfg.cec.driver} 2>/dev/null || true
        for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
          if [ -e ${cfg.cec.device} ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 0.2
        done
        ${config.systemd.package}/bin/systemctl --no-block restart kodi-gbm.service
        if wait_la && settle_and_verify; then
          echo "CEC logical address claimed after the module reload"
          ${pkgs.coreutils}/bin/rm -f "$stamp"
        else
          echo "CEC recovery failed: physical address $phys, logical address mask $(cec_la_mask)" >&2
          exit 1
        fi
      '';
    };

    services.udev.extraRules = lib.mkIf (cfg.cec.enable && cfg.cec.hotplugRecovery) ''
      ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hdmi-cec-hotplug.service"
    '';

    # Kodi defaults to following the TV into standby. An always-on appliance
    # must ignore that command; the adapter file is created or updated before
    # every Kodi start.
    systemd.services.kodi-cec-defaults = lib.mkIf (cfg.cec.enable && cfg.cec.manageAdapterSettings) {
      description = "Set the Kodi CEC adapter defaults";
      wantedBy = [ "multi-user.target" ];
      after = [ "kodi-settings.service" ];
      before = [ "kodi-gbm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        dir="${cfg.home}/.kodi/userdata/peripheral_data"
        file="$dir/cec_CEC_Adapter.xml"
        ${pkgs.coreutils}/bin/install -d -o ${cfg.user} -g users -m 0755 "$dir"
        # `-s` et non `-f` : Kodi crée parfois le fichier vide quand il n'arrive
        # pas à lire les réglages de l'adaptateur. Avec `-f`, le gabarit n'était
        # jamais réinstallé et le CEC restait muet alors que l'unité réussissait.
        if [ ! -s "$file" ]; then
          ${pkgs.coreutils}/bin/install -o ${cfg.user} -g users -m 0644 \
            ${./kodi-cec-adapter.xml} "$file"
        fi
        ${pkgs.gnused}/bin/sed -i \
          's|\(id="standby_pc_on_tv_standby" value="\)[0-9]*"|\1${cecStandbyValue}"|' "$file"
        ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$file"
        ${pkgs.coreutils}/bin/chmod 0644 "$file"
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0700 ${cfg.user} users -"
      "d ${cfg.home}/.kodi 0755 ${cfg.user} users -"
      "d /var/lib/pipewire 0700 ${cfg.user} users -"
    ];

    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    systemd.network.wait-online = {
      # Either the wired or the wireless link is enough: the appliance may
      # boot with only one of them connected.
      anyInterface = true;
      timeout = 60;
    };
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
    };
    systemd.network.networks."10-wlan" = {
      matchConfig.Name = "wl*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "routable";
    };

    services.avahi = {
      enable = lib.mkDefault true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    # Avahi owns mDNS here; resolved's mDNS stack only triggers the
    # "Detected another mDNS stack" warning and is redundant.
    services.resolved.settings.Resolve.MulticastDNS = lib.mkDefault false;

    environment.defaultPackages = lib.mkForce (
      with pkgs;
      [
        bashInteractive
        coreutils
        iproute2
        kmod
        less
        nano
        procps
        util-linux
      ]
    );
  };
}
