# nixelec-kiosk

Couche kiosque NixOS **neutre** : un lecteur Kodi en DRM direct (GBM), son
utilisateur, ses réglages, son CEC — sans aucun nom de SoC, de pilote ou de
connecteur en dur.

C'est l'étage du milieu d'une appliance en trois couches :

```
profil de flotte      identité, secrets, addons privés, tables IR, déploiement
      │
couche kiosque        ← ce dépôt : service Kodi, réglages, CEC, watchdog
      │
couche carte          noyau, DTB, boot, firmware, GPU, WiFi
                      publie nixelec.platform.*
```

Une couche ne connaît que celle du dessous. La couche carte publie des
**faits** (`nixelec.platform.*`), le kiosque consomme des **options**
(`nixelec.kiosk.*`), et la recopie de l'un vers l'autre — le câblage — vit
dans le profil de flotte, seul fichier qui voit les deux étages. Détail et
pièges : [`docs/contrat.md`](docs/contrat.md).

## Ce que le dépôt fournit

| Sortie | Contenu |
|---|---|
| `nixosModules.kodi-gbm` (= `default`) | options `nixelec.kiosk.*`, service Kodi GBM, CEC, réglages, PipeWire |
| `nixosModules.platform` | déclarations seules de `nixelec.platform.*` (contrat de la couche carte) |

Dépendance : `nixpkgs` uniquement. Pas de flake média, pas de paquet Kodi
implicite.

## Utilisation

```nix
{
  inputs.nixelec-kiosk = {
    url = "github:zibaone/nixelec-kiosk";
    inputs.nixpkgs.follows = "nixpkgs";   # un seul nixpkgs : mêmes chemins de store
  };

  outputs = { nixelec-kiosk, ... }: {
    nixosConfigurations.kiosque = nixpkgs.lib.nixosSystem {
      modules = [
        nixelec-kiosk.nixosModules.kodi-gbm
        {
          nixelec.kiosk = {
            enable = true;
            package = ./…kodi-kiosk;   # OBLIGATOIRE — voir ci-dessous
          };
        }
      ];
    };
  };
}
```

`examples/kiosk-gbm.nix` montre le contrat complet, câblage compris.

## Le paquet Kodi n'a pas de défaut

`nixelec.kiosk.package` est obligatoire. Ce n'est pas une coquetterie : sur un
SBC, `pkgs.kodi-gbm` n'embarque pas le décodeur de `nix-v4l2-request`, donc
`CDVDVideoCodecDRMPRIME::Create()` renvoie `nullptr`, Kodi décode en CPU **et
ne le dit pas**. Un défaut commode donnerait un kiosque qui semble marcher en
brûlant son processeur ; une erreur d'évaluation, non.

- SoC à VPU stateless : `nix-v4l2-request` → `packages.<system>.kodi-kiosk` ;
- x86 : `pkgs.kodi-gbm` (VA-API) ;
- la carte peut publier son choix dans `nixelec.platform.kodiPackage`.

## Vérifications

```bash
nix flake check        # nixfmt + évaluation d'une configuration kiosque réelle
nix eval .#nixosModules.kodi-gbm
```

`nix flake check` **évalue** une configuration NixOS montée depuis
`examples/kiosk-gbm.nix` (unités CEC, réglages Kodi, watchdog compris) sans
rien construire. Aucun test de famille de SoC n'existe ici, volontairement.

## État

Évaluation vérifiée ; **aucune validation matérielle dans ce dépôt**. Les
preuves de décodage, d'audio HDMI et de CEC appartiennent aux couches carte et
aux hôtes qui les consomment.

## Licence

MIT — voir [`LICENSE`](LICENSE).
