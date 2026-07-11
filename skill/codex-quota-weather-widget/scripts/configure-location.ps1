param(
    [Parameter(Mandatory=$true)][string]$LocationName,
    [Parameter(Mandatory=$true)][double]$Latitude,
    [Parameter(Mandatory=$true)][double]$Longitude,
    [switch]$Restart,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'CodexQuotaWeatherWidget'
$configPath = Join-Path $installDir 'widget-config.json'
$widgetPath = Join-Path $installDir 'CodexQuotaWidget.ps1'

if ([string]::IsNullOrWhiteSpace($LocationName)) { throw 'A user-confirmed city or region is required.' }
if ($Latitude -lt -90 -or $Latitude -gt 90) { throw 'Latitude must be between -90 and 90.' }
if ($Longitude -lt -180 -or $Longitude -gt 180) { throw 'Longitude must be between -180 and 180.' }

if ($Test) {
    [pscustomobject]@{ valid=$true; weather_enabled=$true } | ConvertTo-Json
    exit 0
}

if (-not (Test-Path -LiteralPath $widgetPath)) { throw 'Widget is not installed.' }

$config = [ordered]@{
    weather_enabled = $true
    city = $LocationName.Trim()
    latitude = $Latitude
    longitude = $Longitude
    refresh_minutes = 15
    weather_cache_max_minutes = 45
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

if ($Restart) {
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($widgetPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$installDir\CodexQuotaWidget.vbs`""
}

[pscustomobject]@{ configured=$true; location=$LocationName.Trim(); restarted=[bool]$Restart } | ConvertTo-Json

