#Requires -Version 5.1
<#
.SYNOPSIS
    Retire la tâche planifiée et arrête l'icône de notification.

.DESCRIPTION
    La limite de charge actuellement dans l'EC n'est pas touchée, sauf avec
    -RestoreDefault. Elle reviendra de toute façon à la valeur du BIOS au
    prochain redémarrage.
#>
[CmdletBinding()]
param(
    # Remet la limite de charge à la valeur par défaut mémorisée avant de partir.
    [switch]$RestoreDefault,

    # Supprime aussi config.json et le journal.
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSCommandPath
$TaskName = 'FrameworkChargeTray'
$ToolExe  = Join-Path $Root 'bin\framework_tool.exe'
$AppDir   = Join-Path $env:LOCALAPPDATA 'FrameworkChargeTray'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Élévation requise, relance en administrateur..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($RestoreDefault) { $argList += '-RestoreDefault' }
    if ($Purge)          { $argList += '-Purge' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*tray.ps1*' } |
    ForEach-Object {
        Write-Host "Arrêt du processus $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Tâche planifiée « $TaskName » supprimée." -ForegroundColor Green
} else {
    Write-Host "Aucune tâche « $TaskName » enregistrée." -ForegroundColor DarkGray
}

if ($RestoreDefault -and (Test-Path $ToolExe)) {
    $target = 80
    $configPath = Join-Path $AppDir 'config.json'
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.defaultLimit -gt 0) { $target = [int]$cfg.defaultLimit }
        } catch { }
    }
    Write-Host "Remise de la limite de charge à $target %..."
    & $ToolExe --charge-limit $target
}

if ($Purge -and (Test-Path $AppDir)) {
    Remove-Item -Path $AppDir -Recurse -Force
    Write-Host "Préférences et journal supprimés." -ForegroundColor Green
}
