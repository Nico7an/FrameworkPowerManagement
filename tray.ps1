#Requires -Version 5.1
<#
.SYNOPSIS
    Framework Charge Tray — bascule la limite de charge de la batterie entre la
    valeur par défaut du BIOS et 100 %, depuis la zone de notification Windows.

.DESCRIPTION
    Pilote l'Embedded Controller via framework_tool.exe, ce qui exige les droits
    administrateur. install.ps1 enregistre une tâche planifiée qui lance ce
    script élevé à l'ouverture de session, sans invite UAC.

    La limite choisie est mémorisée puis réappliquée au démarrage, à la sortie de
    veille et à chaque sondage : l'EC revient à la valeur du BIOS après un
    redémarrage ou une remise à zéro du battery extender.
#>
[CmdletBinding()]
param(
    # Garde la console visible (débogage).
    [switch]$ShowConsole,

    # Dossier d'état (config.json, tray.log). Par défaut %LOCALAPPDATA%.
    # À partager entre sessions Windows : la limite vit dans l'Embedded
    # Controller, elle est donc globale à la machine — deux instances doivent
    # lire la même préférence, sinon chacune réapplique la sienne au sondage.
    [string]$StateDir
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace FwTray -Name NativeMethods -MemberDefinition @'
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
'@

if (-not $ShowConsole) {
    $consoleHandle = [FwTray.NativeMethods]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][FwTray.NativeMethods]::ShowWindow($consoleHandle, 0)   # SW_HIDE
    }
}

# ---------------------------------------------------------------- chemins / log

$Root       = Split-Path -Parent $PSCommandPath
$AppDir     = if ($StateDir) { $StateDir } else { Join-Path $env:LOCALAPPDATA 'FrameworkChargeTray' }
$ConfigPath = Join-Path $AppDir 'config.json'
$LogPath    = Join-Path $AppDir 'tray.log'

if (-not (Test-Path $AppDir)) { [void](New-Item -ItemType Directory -Path $AppDir -Force) }

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 200KB)) { Clear-Content $LogPath }
        Add-Content -Path $LogPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch { }
}

# ----------------------------------------------------------------- préférences

$script:Cfg = [ordered]@{
    exePath      = Join-Path $Root 'bin\framework_tool.exe'
    defaultLimit = 0     # valeur BIOS, découverte au premier lancement
    desiredLimit = 0     # 0 = ne rien imposer
    pollSeconds  = 300
}

function Import-Config {
    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $json = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Cfg.Keys)) {
            $prop = $json.PSObject.Properties[$key]
            if ($prop -and $null -ne $prop.Value -and '' -ne $prop.Value) { $script:Cfg[$key] = $prop.Value }
        }
    } catch {
        Write-Log ('config.json illisible, valeurs par défaut : {0}' -f $_.Exception.Message)
    }
}

function Export-Config {
    try { ($script:Cfg | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding UTF8 }
    catch { Write-Log ('écriture de config.json impossible : {0}' -f $_.Exception.Message) }
}

# ------------------------------------------------------------------- accès EC

function Invoke-FwTool {
    param([string]$Arguments)

    if (-not (Test-Path $script:Cfg.exePath)) {
        throw ('framework_tool.exe introuvable : {0}' -f $script:Cfg.exePath)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $script:Cfg.exePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # framework_tool affiche « Press ENTER to exit... » et attend stdin dès que sa
    # sortie est redirigée : on lui ferme l'entrée pour qu'il rende la main.
    $psi.RedirectStandardInput  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Close() } catch { }

    # Lecture asynchrone : l'appel a lieu sur le thread de l'interface, un enfant
    # bloqué ne doit pas figer la zone de notification.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit(10000)) {
        try { $proc.Kill() } catch { }
        $proc.Dispose()
        throw ('framework_tool.exe ne répond pas (arguments : {0})' -f $Arguments)
    }

    $stdout = $outTask.Result
    $stderr = $errTask.Result
    $code   = $proc.ExitCode
    $proc.Dispose()

    return [pscustomobject]@{ Code = $code; Text = ($stdout + $stderr) }
}

function Read-MaxLimit {
    param([string]$Text)
    $match = [regex]::Match($Text, 'Maximum\s+(\d+)\s*%')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

function Get-ChargeLimit {
    $result = Invoke-FwTool '--charge-limit'
    $value  = Read-MaxLimit $result.Text
    if ($result.Code -ne 0 -or $null -eq $value) {
        throw ('lecture de la limite impossible (code {0}) : {1}' -f $result.Code, $result.Text.Trim())
    }
    return $value
}

function Set-ChargeLimit {
    param([int]$Percent)
    $result = Invoke-FwTool ('--charge-limit {0}' -f $Percent)
    $value  = Read-MaxLimit $result.Text
    if ($result.Code -ne 0 -or $null -eq $value) {
        throw ('écriture de la limite impossible (code {0}) : {1}' -f $result.Code, $result.Text.Trim())
    }
    if ($value -ne $Percent) {
        throw ("l'EC a répondu {0} % au lieu de {1} %." -f $value, $Percent)
    }
    return $value
}

# ---------------------------------------------------------------------- icône

$script:CurrentIcon = $null

function New-BatteryIcon {
    param([int]$FillPercent, [System.Drawing.Color]$Color)

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $gfx.Clear([System.Drawing.Color]::Transparent)

        $pen   = New-Object System.Drawing.Pen $Color, 2
        $brush = New-Object System.Drawing.SolidBrush $Color
        try {
            $gfx.DrawRectangle($pen, 4, 9, 21, 14)              # corps
            $gfx.FillRectangle($brush, 26, 13, 4, 6)            # borne +
            $clamped = [Math]::Max(0, [Math]::Min(100, $FillPercent))
            $width   = [int][Math]::Round(15 * ($clamped / 100.0))
            if ($width -gt 0) { $gfx.FillRectangle($brush, 7, 12, $width, 8) }
        } finally {
            $pen.Dispose()
            $brush.Dispose()
        }

        $hIcon = $bmp.GetHicon()
        try {
            $temp = [System.Drawing.Icon]::FromHandle($hIcon)
            return $temp.Clone()
        } finally {
            [void][FwTray.NativeMethods]::DestroyIcon($hIcon)
        }
    } finally {
        $gfx.Dispose()
        $bmp.Dispose()
    }
}

function Get-BatteryPercent {
    try {
        $ratio = [System.Windows.Forms.SystemInformation]::PowerStatus.BatteryLifePercent
        if ($ratio -lt 0 -or $ratio -gt 1) { return 100 }
        return [int][Math]::Round($ratio * 100)
    } catch { return 100 }
}

# ------------------------------------------------------------------- affichage

function Update-Display {
    param([int]$HardwareLimit)

    $battery = Get-BatteryPercent
    $full    = ($HardwareLimit -ge 100)
    if ($full) { $color = [System.Drawing.Color]::FromArgb(255, 150, 40) }
    else       { $color = [System.Drawing.Color]::FromArgb(60, 190, 110) }

    $newIcon = New-BatteryIcon -FillPercent $battery -Color $color
    $oldIcon = $script:CurrentIcon
    $script:Notify.Icon = $newIcon
    $script:CurrentIcon = $newIcon
    if ($oldIcon) { $oldIcon.Dispose() }

    $script:Notify.Text         = ('Limite {0} % — batterie {1} %' -f $HardwareLimit, $battery)
    $script:ItemStatus.Text     = ('Limite actuelle : {0} %  ·  batterie {1} %' -f $HardwareLimit, $battery)
    $script:ItemDefault.Text    = ('Par défaut Framework ({0} %)' -f $script:Cfg.defaultLimit)
    $script:ItemFull.Checked    = $full
    $script:ItemDefault.Checked = (-not $full)
}

function Show-Balloon {
    param(
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Kind = [System.Windows.Forms.ToolTipIcon]::Info
    )
    $script:Notify.BalloonTipIcon  = $Kind
    $script:Notify.BalloonTipTitle = 'Limite de charge'
    $script:Notify.BalloonTipText  = $Message
    $script:Notify.ShowBalloonTip(4000)
}

function Show-Failure {
    param([string]$Message)
    Write-Log ('ERREUR : {0}' -f $Message)
    $script:Notify.Text     = 'Framework — erreur, voir le journal'
    $script:ItemStatus.Text = 'État inconnu — voir Actualiser'
    Show-Balloon -Message $Message -Kind ([System.Windows.Forms.ToolTipIcon]::Error)
}

# --------------------------------------------------------------------- actions

function Set-Mode {
    param([int]$Percent)
    try {
        $value = Set-ChargeLimit $Percent
        $script:Cfg.desiredLimit = $value
        Export-Config
        Update-Display $value
        Write-Log ('limite réglée sur {0} %' -f $value)
        Show-Balloon ('Charge limitée à {0} %.' -f $value)
    } catch {
        Show-Failure $_.Exception.Message
    }
}

function Sync-ChargeState {
    param([switch]$Reapply)
    $script:LastPoll = Get-Date
    try {
        # Avec un dossier d'état partagé, l'autre session a pu changer la
        # préférence depuis notre dernier sondage : on relit avant de juger.
        Import-Config
        $hardware = Get-ChargeLimit
        $desired  = [int]$script:Cfg.desiredLimit
        if ($Reapply -and $desired -gt 0 -and $hardware -ne $desired) {
            Write-Log ('limite matérielle {0} % au lieu de {1} %, réapplication' -f $hardware, $desired)
            $hardware = Set-ChargeLimit $desired
        }
        Update-Display $hardware
    } catch {
        Show-Failure $_.Exception.Message
    }
}

# ------------------------------------------------------------------- démarrage

$mutexCreated = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\FrameworkChargeTray', [ref]$mutexCreated)
if (-not $mutexCreated) {
    Write-Log 'instance déjà en cours, arrêt.'
    exit 0
}

Import-Config

if (-not (Test-Path $script:Cfg.exePath)) {
    $message = 'framework_tool.exe est introuvable :' + [Environment]::NewLine +
               $script:Cfg.exePath + [Environment]::NewLine + [Environment]::NewLine +
               'Relance install.ps1 pour le télécharger.'
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Framework Charge Tray', 'OK', 'Error')
    exit 1
}

$initialLimit = $null
try { $initialLimit = Get-ChargeLimit }
catch { Write-Log ('lecture initiale impossible : {0}' -f $_.Exception.Message) }

if ([int]$script:Cfg.defaultLimit -le 0) {
    if ($null -ne $initialLimit -and $initialLimit -lt 100) { $script:Cfg.defaultLimit = $initialLimit }
    else { $script:Cfg.defaultLimit = 80 }
    Write-Log ('valeur par défaut retenue : {0} %' -f $script:Cfg.defaultLimit)
    Export-Config
}

# ------------------------------------------------------------------- interface

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# Pas de colonne d'images, mais il faut celle des coches pour voir le mode actif.
$menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $true

$script:ItemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$script:ItemStatus.Text    = 'Lecture…'
$script:ItemStatus.Enabled = $false

$script:ItemFull = New-Object System.Windows.Forms.ToolStripMenuItem
$script:ItemFull.Text = 'Charge maximale 100 %'
$script:ItemFull.Add_Click({ Set-Mode 100 })

$script:ItemDefault = New-Object System.Windows.Forms.ToolStripMenuItem
$script:ItemDefault.Text = 'Par défaut Framework'
$script:ItemDefault.Add_Click({ Set-Mode ([int]$script:Cfg.defaultLimit) })

$itemRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
$itemRefresh.Text = 'Actualiser'
$itemRefresh.Add_Click({ Sync-ChargeState -Reapply })

$itemQuit = New-Object System.Windows.Forms.ToolStripMenuItem
$itemQuit.Text = 'Quitter'
$itemQuit.Add_Click({
    $script:Timer.Stop()
    $script:Notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

[void]$menu.Items.Add($script:ItemStatus)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($script:ItemFull)
[void]$menu.Items.Add($script:ItemDefault)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($itemRefresh)
[void]$menu.Items.Add($itemQuit)

$menu.Add_Opening({
    try { Update-Display (Get-ChargeLimit) } catch { Show-Failure $_.Exception.Message }
})

$script:Notify.ContextMenuStrip = $menu

# Clic gauche : même menu que le clic droit.
$script:Notify.Add_MouseClick({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $method = $sender.GetType().GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($method) { [void]$method.Invoke($sender, $null) }
    else { $menu.Show([System.Windows.Forms.Cursor]::Position) }
})

# ----------------------------------------------------------------------- boucle

$script:PendingSync = $false
$script:LastPoll    = Get-Date

$script:PowerHandler = $null
try {
    $script:PowerHandler = [Microsoft.Win32.PowerModeChangedEventHandler] {
        param($sender, $eventArgs)
        if ($eventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) { $script:PendingSync = $true }
    }
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:PowerHandler)
} catch {
    Write-Log ("événements d'alimentation indisponibles : {0}" -f $_.Exception.Message)
    $script:PowerHandler = $null
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 15000
$script:Timer.Add_Tick({
    $due = ((Get-Date) - $script:LastPoll).TotalSeconds -ge [int]$script:Cfg.pollSeconds
    if ($script:PendingSync -or $due) {
        $script:PendingSync = $false
        Sync-ChargeState -Reapply
    }
})
$script:Timer.Start()

Write-Log 'démarrage'
Sync-ChargeState -Reapply

[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))

# --------------------------------------------------------------------- nettoyage

if ($script:PowerHandler) {
    try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:PowerHandler) } catch { }
}
$script:Timer.Dispose()
$script:Notify.Dispose()
if ($script:CurrentIcon) { $script:CurrentIcon.Dispose() }
Write-Log 'arrêt'
$script:Mutex.ReleaseMutex()
$script:Mutex.Dispose()
