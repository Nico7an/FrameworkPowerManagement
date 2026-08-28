#Requires -Version 5.1
<#
.SYNOPSIS
    Compile FrameworkChargeTray.exe : un seul fichier, framework_tool.exe
    embarqué en ressource.

.DESCRIPTION
    Utilise csc.exe du .NET Framework 4.x, présent sur tout Windows 10/11 — pas
    de SDK à installer, pas de runtime à livrer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param(
    # framework_tool.exe à embarquer. Par défaut bin\ à la racine du dépôt.
    [string]$Tool,

    # Sortie. Par défaut dist\FrameworkChargeTray.exe.
    [string]$Out
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $PSCommandPath
$Repo = Split-Path -Parent $Root
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

# $PSCommandPath n'est pas encore peuplé quand PowerShell évalue les valeurs par
# défaut des paramètres : on résout ici.
if (-not $Tool) { $Tool = Join-Path $Repo 'bin\framework_tool.exe' }
if (-not $Out)  { $Out  = Join-Path $Repo 'dist\FrameworkChargeTray.exe' }

if (-not (Test-Path $csc))  { throw "csc.exe introuvable : $csc" }
if (-not (Test-Path $Tool)) { throw "framework_tool.exe introuvable : $Tool`nRécupère-le sur https://github.com/FrameworkComputer/framework-system/releases" }

$outDir = Split-Path -Parent $Out
if (-not (Test-Path $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }

# Une instance en cours verrouille le fichier de sortie : csc rendrait un CS0016
# peu parlant.
$running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Out)) -ErrorAction SilentlyContinue)
foreach ($r in $running) {
    Write-Host ("arret de l'instance en cours : PID {0}" -f $r.Id) -ForegroundColor DarkGray
    Stop-Process -Id $r.Id -Force -ErrorAction SilentlyContinue
}
if ($running.Count) { Start-Sleep -Seconds 2 }

# ------------------------------------------------------------------ icône .ico

$icoPath = Join-Path $env:TEMP ('fct-icon-' + [guid]::NewGuid().ToString('N') + '.ico')

function New-BatteryPng {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $s = $Size / 32.0

        $body = New-Object System.Drawing.RectangleF (4*$s), (9*$s), (22*$s), (14*$s)
        $pen  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(240,240,240)), (2*$s)
        $g.DrawRectangle($pen, $body.X, $body.Y, $body.Width, $body.Height)
        $pen.Dispose()

        $cap = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240,240,240))
        $g.FillRectangle($cap, (26*$s), (13*$s), (3*$s), (6*$s))
        $cap.Dispose()

        # 80 % de remplissage, vert : l'état « limité », celui qu'on veut vendre.
        $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(76,175,80))
        $g.FillRectangle($fill, ($body.X + 2*$s), ($body.Y + 2*$s), ($body.Width - 4*$s) * 0.8, ($body.Height - 4*$s))
        $fill.Dispose()
    } finally { $g.Dispose() }

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [byte[]]$bytes = $ms.ToArray()
    $ms.Dispose()
    # La virgule empêche PowerShell de dérouler le byte[] en octets isolés :
    # sans elle le tableau ressort en Object[] et BinaryWriter n'écrit rien.
    return ,$bytes
}

# ICO conteneur, entrées PNG (supporté depuis Vista).
$sizes = @(16, 32, 48, 256)
$pngs  = @{}
foreach ($sz in $sizes) { $pngs[$sz] = New-BatteryPng -Size $sz }

$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
try {
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($sz in $sizes) {
        $bytes = $pngs[$sz]
        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($sz in $sizes) { $bw.Write($pngs[$sz]) }
} finally { $bw.Dispose(); $fs.Dispose() }

Write-Host ("icone generee : {0:N0} octets" -f (Get-Item $icoPath).Length) -ForegroundColor DarkGray

# ------------------------------------------------------------------ compilation

$args = @(
    '/nologo'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    '/warn:4'
    "/out:$Out"
    "/win32manifest:$(Join-Path $Root 'app.manifest')"
    "/win32icon:$icoPath"
    "/resource:$Tool,FrameworkChargeTray.framework_tool.exe"
    '/reference:System.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    (Join-Path $Root 'FrameworkChargeTray.cs')
)

Write-Host "compilation..." -ForegroundColor Cyan
& $csc @args
$code = $LASTEXITCODE
Remove-Item $icoPath -Force -ErrorAction SilentlyContinue
if ($code -ne 0) { throw "csc a echoue (code $code)" }

$exe = Get-Item $Out
Write-Host ("`nOK : {0}" -f $exe.FullName) -ForegroundColor Green
Write-Host ("     {0:N0} octets  (dont {1:N0} pour framework_tool.exe)" -f $exe.Length, (Get-Item $Tool).Length)
