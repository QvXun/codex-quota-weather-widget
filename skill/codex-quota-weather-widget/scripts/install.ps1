param(
    [string]$LocationName,
    [double]$Latitude = [double]::NaN,
    [double]$Longitude = [double]::NaN,
    [switch]$DisableWeather,
    [switch]$EnableAutoStart,
    [switch]$NoLaunch,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$assetDir = Join-Path $skillRoot 'assets\widget'
$installDir = Join-Path $env:LOCALAPPDATA 'CodexQuotaWeatherWidget'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Quota Weather Widget'
$startupDir = [Environment]::GetFolderPath('Startup')
$startMenuShortcut = Join-Path $startMenuDir 'Codex Quota Weather Widget.lnk'
$startupShortcut = Join-Path $startupDir 'Codex Quota Weather Widget.lnk'

function Assert-Inputs {
    if (-not (Test-Path -LiteralPath (Join-Path $assetDir 'CodexQuotaWidget.ps1'))) { throw 'Widget asset is missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $assetDir 'CodexQuotaWidget.vbs'))) { throw 'Launcher asset is missing.' }
    if (-not $DisableWeather) {
        if ([string]::IsNullOrWhiteSpace($LocationName)) { throw 'A user-confirmed city or region is required.' }
        if ([double]::IsNaN($Latitude) -or $Latitude -lt -90 -or $Latitude -gt 90) { throw 'Latitude must be between -90 and 90.' }
        if ([double]::IsNaN($Longitude) -or $Longitude -lt -180 -or $Longitude -gt 180) { throw 'Longitude must be between -180 and 180.' }
    }
}

function New-WidgetShortcut([string]$path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $shortcut.Arguments = "`"$installDir\CodexQuotaWidget.vbs`""
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = 'Codex quota and weather widget'
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
    $shortcut.Save()
}

Assert-Inputs

if ($Test) {
    [pscustomobject]@{
        valid = $true
        weather_enabled = -not $DisableWeather
        auto_start = [bool]$EnableAutoStart
        asset_count = @(Get-ChildItem -LiteralPath $assetDir -File).Count
    } | ConvertTo-Json
    exit 0
}

New-Item -ItemType Directory -Force -Path $installDir, $startMenuDir | Out-Null
Get-ChildItem -LiteralPath $assetDir -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $installDir $_.Name) -Force
}

$config = [ordered]@{
    weather_enabled = -not $DisableWeather
    city = if ($DisableWeather) { '' } else { $LocationName.Trim() }
    latitude = if ($DisableWeather) { 0 } else { $Latitude }
    longitude = if ($DisableWeather) { 0 } else { $Longitude }
    refresh_minutes = 15
    weather_cache_max_minutes = 45
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDir 'widget-config.json') -Encoding UTF8

New-WidgetShortcut $startMenuShortcut
if ($EnableAutoStart) {
    New-WidgetShortcut $startupShortcut
} elseif (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}

if (-not $NoLaunch) {
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$installDir\CodexQuotaWidget.vbs`""
}

[pscustomobject]@{
    installed = $true
    install_dir = $installDir
    weather_enabled = -not $DisableWeather
    location = if ($DisableWeather) { $null } else { $LocationName.Trim() }
    auto_start = [bool]$EnableAutoStart
} | ConvertTo-Json

