# Contrat entre la couche carte et la couche kiosque

Deux arbres d'options, un seul sens de dépendance :

- **`nixelec.platform.*`** — les *faits*. La couche carte les publie. Ce
  fichier les déclare (`modules/platform.nix`) ; il ne les configure pas.
- **`nixelec.kiosk.*`** — les *options*. Le profil de flotte (ou le module de
  compatibilité de la carte) les pose, en recopiant les faits.

```
couche carte ──publie──▶ nixelec.platform.* ──câblage──▶ nixelec.kiosk.* ──▶ service Kodi
```

La couche carte ne pose **jamais** `nixelec.kiosk.*` : elle publierait une
politique de lecteur alors qu'elle ne connaît que du matériel, et devrait
importer la couche kiosque — la dépendance s'inverserait.

## Les faits (`nixelec.platform.*`)

| Option | Type | Défaut | Rôle |
|---|---|---|---|
| `cecDriver` | `nullOr str` | `null` | module noyau CEC (`dw-hdmi-cec`, `cec-meson-ao`…) ; `null` = pas de CEC noyau (adaptateur libCEC USB possible) |
| `hdmiConnector` | `nullOr str` | `null` | nom noyau du connecteur (`HDMI-A-1`), sans préfixe carte |
| `videoMode` | `nullOr str` | `null` | mode préféré (`1920x1080@60`) ; préférence, jamais de suffixe `D` |
| `watchdog.enable` | `bool` | `false` | watchdog matériel **prouvé** sur la carte |
| `watchdog.maxTimeout` | `nullOr int` | `null` | plafond matériel en secondes (`max_timeout`) |
| `kodiPackage` | `nullOr package` | `null` | paquet Kodi qui décode sur cette plateforme |

Tous les défauts sont nuls : la couche neutre ne doit contenir aucun à-priori
sur une famille de SoC.

## Le câblage (une seule fois, là où les deux étages sont visibles)

```nix
nixelec.kiosk = {
  enable = true;
  package = config.nixelec.platform.kodiPackage;          # ou un choix de flotte (x86)

  cec = {
    enable = true;
    driver = config.nixelec.platform.cecDriver;
    connector = "card0-${config.nixelec.platform.hdmiConnector}";
    hotplugRecovery = true;                                # exige driver ET connector
  };

  watchdog.enable = config.nixelec.platform.watchdog.enable;

  extraKernelParams = [
    "video=${config.nixelec.platform.hdmiConnector}:${config.nixelec.platform.videoMode}"
  ];
};
```

`cec.connector` attend le nom **sysfs complet** (`card0-HDMI-A-1`) ; le fait
`hdmiConnector` est le nom noyau (`HDMI-A-1`), d'où la composition. L'index de
carte vaut `0` sur toutes les cibles actuelles (un seul GPU).

## Options du kiosque (`nixelec.kiosk.*`)

| Option | Remarque |
|---|---|
| `enable` | active le service et le reste du bloc |
| `package` | **obligatoire, sans défaut** — voir §Le paquet |
| `user`, `home`, `extraGroups` | utilisateur du kiosque, XDG, groupes DRM/audio/input |
| `addons`, `autoEnableAddons` | `withPackages` et activation JSON-RPC au boot |
| `webServer.*`, `uiSounds`, `homeMenu.hidden` | réglages appliqués avant chaque départ de Kodi |
| `cpuGovernor` | écrit directement dans sysfs (`null` = défaut noyau) |
| `watchdog.*` | `systemd.settings.Manager`, plafonné par `platform.watchdog.maxTimeout` |
| `cec.driver` / `cec.connector` | `nullOr str`, renseignés par le câblage |
| `cec.{reprobeOnBoot,hotplugRecovery,manageAdapterSettings,standbyPcOnTvStandby}` | reprise CEC, réglages d'adaptateur |
| `extraKernelParams` | défini **seulement si non vide** |

## Pièges mesurés

### Le paquet

`nixelec.kiosk.package` n'a pas de défaut, et l'option n'est lue que sous
`lib.mkIf cfg.enable` : un simple import du module n'échoue pas à l'éval, un
kiosque activé sans paquet échoue avec « used but not defined ».

Raison : `CDVDVideoCodecDRMPRIME::Create()` renvoie `nullptr` quand le paquet
n'a pas `v4l2-request` ; Kodi bascule en décodage CPU sans message. Un
`pkgs.kodi-gbm` implicite serait donc un défaut qui marche — et qui brûle le
processeur.

### `boot.kernelParams`

`extraKernelParams` n'est défini que s'il est non vide. Une liste vide à
priorité normale effacerait les paramètres `mkDefault` de la couche carte
(`console=ttyAML0`, `cma=256M`…), sans erreur : les listes ne se concatènent
qu'à priorité égale.

Corollaire pour la carte : poser ses paramètres de base en `mkDefault`, jamais
en `mkForce` — un `mkForce` jette les paramètres du consommateur.

### CEC : trois états, pas deux

- `cec.enable` seul : Kodi peut piloter un adaptateur libCEC USB, aucun
  module noyau n'est chargé ;
- `+ driver` : le module est chargé, mis dans l'allowlist d'un arbre élagué,
  et rechargé au boot (`reprobeOnBoot`) si l'adresse physique est `f.f.f.f` ;
- `+ driver + connector` : reprise après hotplug (udev → redémarrage de Kodi,
  vérifié sur l'adresse logique **et** son propriétaire libCEC).

Les assertions refusent `reprobeOnBoot` sans `driver`, et `hotplugRecovery`
sans `driver` ni `connector`.

### Watchdog

`watchdog.runtimeTime` / `rebootTime` sont des durées systemd. Quand la carte
publie `watchdog.maxTimeout`, une valeur supérieure échoue à l'éval : au-delà
du plafond, le noyau plafonne en silence et le watchdog ne protège plus ce
qu'on croit. Les formes non numériques (`1min`, `500ms`) ne sont pas
comparées.

### Rendu

Rien à choisir ici. Panfrost (GLES 3.1) et lima (GLES 2.0) tournent tous deux
en GBM avec Mesa et en zéro-copie ; Kodi retombe seul sur son rendu GLES 2.
Le seul écart qui compte est le **paquet**, pas le GPU.
