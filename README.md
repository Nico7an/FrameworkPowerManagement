# Framework Charge Tray

Petite icône de zone de notification pour basculer la limite de charge de la
batterie du Framework Laptop entre **100 %** et la **valeur par défaut du BIOS**
(80 % sur cette machine). C'est tout ce qu'elle fait.

## Installation

Télécharge `FrameworkChargeTray.exe` depuis la
[dernière release](https://github.com/Nico7an/FrameworkPowerManagement/releases/latest)
et lance-le. Un seul fichier, rien à décompresser, rien d'autre à récupérer :
`framework_tool.exe` est embarqué dedans.

Windows demandera l'élévation — `framework_tool` parle à l'Embedded Controller
par port I/O, c'est structurel. Au premier lancement l'app enregistre une tâche
planifiée qui la relancera élevée à chaque ouverture de session : tu ne reverras
plus l'invite.

> [!TIP]
> Un exe téléchargé par navigateur porte un Mark-of-the-Web et SmartScreen
> affichera « Windows a protégé votre PC ». Clic droit → Propriétés →
> **Débloquer**, ou *Informations complémentaires* → *Exécuter quand même*.
> Le binaire n'est pas signé : il n'y a pas de certificat de signature de code
> derrière ce petit outil.

Pour retirer la tâche de démarrage : `FrameworkChargeTray.exe --uninstall`.

## Est-ce que Windows sait déjà le faire ?

Non. Windows 11 n'a aucun réglage de limite de charge dans **Paramètres →
Système → Alimentation et batterie** : on y trouve l'économiseur de batterie,
les recommandations énergétiques et « charge intelligente » sur certains
appareils OEM, mais pas de plafond de charge réglable. Ce plafond vit dans
l'Embedded Controller, et chaque constructeur fournit son propre utilitaire
(Lenovo Vantage, Dell Power Manager…).

Chez Framework, deux voies existent :

| Voie | Redémarrage | Confort |
| --- | --- | --- |
| BIOS → `Advanced` → `Battery charge limit` | oui | faible |
| `framework_tool --charge-limit N` (runtime EC) | non | dépend d'un CLI élevé |

Cette app est un habillage de la seconde : deux clics, aucun redémarrage.

## Utilisation

Clic gauche ou droit sur l'icône batterie :

```
Limite : 80 %  ·  batterie 71 %
─────────────────────────────────────────
✓  Charge maximale 100 %
   Par défaut Framework (80 %)
─────────────────────────────────────────
   Actualiser
   Quitter
```

- L'icône est **verte** en mode limité, **orange** en mode 100 % ; le remplissage
  suit la charge réelle de la batterie.
- Le choix est mémorisé et **réappliqué** au démarrage, à la sortie de veille et
  à chaque sondage (5 min par défaut) : l'EC retombe sur la valeur du BIOS après
  un redémarrage ou une remise à zéro du *battery extender*, l'app rattrape.
- La valeur « par défaut » n'est pas codée en dur : elle est lue dans l'EC au
  premier lancement, donc si le BIOS est réglé sur 75 ou 85 %, c'est celle-là.

## Fichiers

L'app est un exécutable unique. Elle dépose son état sous
`C:\ProgramData\FrameworkChargeTray\` :

| Chemin | Rôle |
| --- | --- |
| `framework_tool.exe` | extrait de la ressource embarquée au premier lancement |
| `config.txt` | préférence, valeur par défaut, période de sondage |
| `tray.log` | journal (une erreur silencieuse s'y retrouve) |

L'état vit sous `ProgramData` et non sous `%LOCALAPPDATA%` **à dessein** : la
limite de charge est un réglage matériel *global à la machine*. Deux sessions
Windows ouvertes en même temps partagent donc la même préférence au lieu de se
la réappliquer mutuellement à chaque sondage.

## Compilation depuis les sources

Aucun SDK requis : le `csc.exe` du .NET Framework 4.x livré avec Windows suffit.

```powershell
git clone https://github.com/Nico7an/FrameworkPowerManagement.git
cd FrameworkPowerManagement
# place framework_tool.exe dans bin\, puis :
powershell -ExecutionPolicy Bypass -File .\src\build.ps1
```

`bin\framework_tool.exe` n'est pas versionné : récupère-le dans les
[releases de framework-system](https://github.com/FrameworkComputer/framework-system/releases).
Le build l'embarque en ressource et produit `dist\FrameworkChargeTray.exe`.

<details>
<summary>Version PowerShell (héritée)</summary>

`tray.ps1`, `install.ps1` et `uninstall.ps1` sont l'implémentation d'origine,
conservée pour référence. Elle fait la même chose mais exige que les `.ps1`
restent en **UTF-8 avec BOM**, sinon PowerShell 5.1 lit les accents en ANSI.
`-StateDir` y déporte l'état pour le partager entre sessions.

</details>

## Limites connues

- `framework_tool` attend un `ENTER` quand sa sortie est redirigée ; l'app ferme
  son entrée standard pour cela, avec un délai de garde de 10 s.
- Windows 11 range les nouvelles icônes dans le dépassement (chevron `^`) :
  glisse-la dans la barre si tu la veux visible en permanence.
- Sur certaines versions de BIOS, la communauté Framework signale un plafond
  parfois ignoré par l'EC ; l'app relit la valeur après écriture et signale
  l'écart par une bulle d'erreur.

## Sources

- [FrameworkComputer/framework-system](https://github.com/FrameworkComputer/framework-system)
- [EXAMPLES.md — commandes batterie](https://github.com/FrameworkComputer/framework-system/blob/main/EXAMPLES.md)
- [Charge limit non conservé après redémarrage (issue #25)](https://github.com/FrameworkComputer/framework-system/issues/25)
- [Battery Charge Limit — Framework 13 AMD Ryzen AI](https://community.frame.work/t/battery-charge-limit-and-low-battery-warning-framework-laptop-13-amd-ryzen-ai/72468)

## Licence

MIT — voir [LICENSE](LICENSE).

`framework_tool.exe`, embarqué dans l'exécutable publié, est redistribué sous
licence BSD 3-Clause (Framework Computer Inc), reproduite intégralement dans
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) conformément à sa clause 2.
