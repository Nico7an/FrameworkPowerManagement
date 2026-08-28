# Framework Charge Tray

Petite icône de zone de notification pour basculer la limite de charge de la
batterie du Framework Laptop entre **100 %** et la **valeur par défaut du BIOS**
(80 % sur cette machine). C'est tout ce qu'elle fait.

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

## Installation

Télécharge le zip de la
[dernière release](https://github.com/Nico7an/FrameworkPowerManagement/releases/latest),
décompresse, double-clique sur **`Installer.cmd`**. Tout est dedans, y compris
`framework_tool.exe` : rien d'autre à télécharger.

Windows demandera l'élévation une fois — `framework_tool` parle à l'Embedded
Controller par port I/O. Ensuite plus jamais : la tâche planifiée créée par
l'installeur s'en charge à chaque ouverture de session.

<details>
<summary>Depuis les sources</summary>

`bin\framework_tool.exe` n'est pas versionné dans le dépôt ;
`install.ps1` le télécharge s'il est absent.

```powershell
git clone https://github.com/Nico7an/FrameworkPowerManagement.git
cd FrameworkPowerManagement
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

</details>

L'installeur :

1. télécharge `bin\framework_tool.exe` (outil officiel Framework, `v0.6.5`) s'il
   est absent — `-LatestTool` prend la dernière version publiée ;
2. vérifie que l'accès à l'EC répond ;
3. enregistre la tâche planifiée `FrameworkChargeTray` — ouverture de session,
   autorisations maximales, 20 s de délai — puis lance l'app.

L'élévation est obligatoire : `framework_tool` parle à l'EC par port I/O. Passer
par une tâche planifiée évite une invite UAC à chaque démarrage de session.

## Utilisation

Clic gauche ou droit sur l'icône batterie :

```
Limite actuelle : 80 %  ·  batterie 71 %
─────────────────────────────────────────
   Charge maximale 100 %
✓  Par défaut Framework (80 %)
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

| Chemin | Rôle |
| --- | --- |
| `Installer.cmd` | double-clic, présent dans le zip de release |
| `tray.ps1` | l'app (PowerShell + WinForms, lancée par `powershell.exe` 5.1) |
| `install.ps1` / `uninstall.ps1` | tâche planifiée et dépendance |
| `bin\framework_tool.exe` | CLI Framework qui pilote l'EC |
| `%LOCALAPPDATA%\FrameworkChargeTray\config.json` | préférence, valeur par défaut, période de sondage |
| `%LOCALAPPDATA%\FrameworkChargeTray\tray.log` | journal (une erreur silencieuse s'y retrouve) |

`config.json` est éditable : `pollSeconds` pour la période de sondage, `exePath`
si `framework_tool.exe` vit ailleurs.

## Désinstallation

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Options : `-RestoreDefault` remet la limite par défaut dans l'EC avant de partir,
`-Purge` supprime préférences et journal. Sans option, la limite en cours est
laissée telle quelle — elle reviendra à la valeur du BIOS au prochain
redémarrage.

## Limites connues

- Les scripts `.ps1` doivent rester en **UTF-8 avec BOM** : PowerShell 5.1 lit
  sinon les accents en ANSI.
- `framework_tool` attend un `ENTER` quand sa sortie est redirigée ; l'app ferme
  son entrée standard pour cela, avec un délai de garde de 10 s.
- Windows 11 range les nouvelles icônes dans le dépassement (chevron `^`) :
  glisse-la dans la barre si tu la veux visible en permanence.
- Sur certaines versions de BIOS, la communauté Framework signale un plafond
  parfois ignoré par l'EC ; l'app vérifie la valeur relue après écriture et
  signale l'écart par une bulle d'erreur.

## Sources

- [FrameworkComputer/framework-system](https://github.com/FrameworkComputer/framework-system)
- [EXAMPLES.md — commandes batterie](https://github.com/FrameworkComputer/framework-system/blob/main/EXAMPLES.md)
- [Charge limit non conservé après redémarrage (issue #25)](https://github.com/FrameworkComputer/framework-system/issues/25)
- [Battery Charge Limit — Framework 13 AMD Ryzen AI](https://community.frame.work/t/battery-charge-limit-and-low-battery-warning-framework-laptop-13-amd-ryzen-ai/72468)

## Licence

MIT — voir [LICENSE](LICENSE).

`framework_tool.exe` n'est pas redistribué par ce dépôt : il est
téléchargé depuis les releases de
[FrameworkComputer/framework-system](https://github.com/FrameworkComputer/framework-system/releases)
et reste soumis à sa propre licence.
