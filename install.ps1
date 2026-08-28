#Requires -Version 5.1
<#
.SYNOPSIS
    Installe Framework Charge Tray : télécharge framework_tool.exe si besoin et
    enregistre une tâche planifiée qui lance l'icône de notification, élevée, à
    l'ouverture de session.

.DESCRIPTION
    L'élévation est indispensable : framework_tool.exe parle à l'Embedded
    Controller par port I/O. Passer par une tâche planifiée « exécuter avec les
    autorisations maximales » évite une invite UAC à chaque démarrage.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    # Version de framework_tool à télécharger si bin\framework_tool.exe est absent.
    [string]$ToolVersion = 'v0.6.5',

    # Prend la dernière version publiée plutôt que $ToolVersion.
    [switch]$LatestTool,

    # N'enregistre la tâche que pour plus tard, sans lancer l'app maintenant.
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $PSCommandPath
$TaskName   = 'FrameworkChargeTray'
$TrayScript = Join-Path $Root 'tray.ps1'
$BinDir     = Join-Path $Root 'bin'
$ToolExe    = Join-Path $BinDir 'framework_tool.exe'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Élévation requise, relance en administrateur..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                 '-ToolVersion', $ToolVersion)
    if ($LatestTool) { $argList += '-LatestTool' }
    if ($NoStart)    { $argList += '-NoStart' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

if (-not (Test-Path $TrayScript)) { throw "tray.ps1 est absent de $Root" }

# ------------------------------------------------------------ framework_tool.exe

if (-not (Test-Path $BinDir)) { [void](New-Item -ItemType Directory -Path $BinDir) }

if (Test-Path $ToolExe) {
    Write-Host "framework_tool.exe déjà présent." -ForegroundColor DarkGray
} else {
    if ($LatestTool) {
        $url = 'https://github.com/FrameworkComputer/framework-system/releases/latest/download/framework_tool.exe'
    } else {
        $url = 'https://github.com/FrameworkComputer/framework-system/releases/download/{0}/framework_tool.exe' -f $ToolVersion
    }
    Write-Host "Téléchargement de $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $ToolExe -UseBasicParsing
    Write-Host ("Téléchargé : {0:N0} octets" -f (Get-Item $ToolExe).Length) -ForegroundColor Green
}

Write-Host "`nVérification de l'accès à l'EC :" -ForegroundColor Cyan
# stdin fermée : framework_tool attend « Press ENTER » selon le contexte de lancement.
$null | & $ToolExe --charge-limit
if ($LASTEXITCODE -ne 0) {
    throw "framework_tool.exe a échoué (code $LASTEXITCODE). Machine Framework et session élevée requises."
}

# ------------------------------------------------------------- tâche planifiée

$psExe    = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argument = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $TrayScript

$action    = New-ScheduledTaskAction -Execute $psExe -Argument $argument -WorkingDirectory $Root
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$trigger.Delay = 'PT20S'
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                          -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                          -MultipleInstances IgnoreNew -StartWhenAvailable

[void](Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                             -Principal $principal -Settings $settings -Force `
                             -Description 'Framework Charge Tray — limite de charge batterie depuis la zone de notification')

Write-Host "`nTâche planifiée « $TaskName » enregistrée." -ForegroundColor Green

if (-not $NoStart) {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*tray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-ScheduledTask -TaskName $TaskName
    Write-Host "App lancée : cherche l'icône batterie dans la zone de notification." -ForegroundColor Green
}

Write-Host "`nDésinstallation : .\uninstall.ps1" -ForegroundColor DarkGray
