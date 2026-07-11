param([switch]$Test)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'CodexQuotaWeatherWidget'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Quota Weather Widget'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Quota Weather Widget.lnk'
$expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexQuotaWeatherWidget'))

if ([IO.Path]::GetFullPath($installDir) -ne $expectedRoot) { throw 'Refusing to remove an unexpected path.' }

if ($Test) {
    [pscustomobject]@{ valid=$true; target_name=(Split-Path -Leaf $installDir) } | ConvertTo-Json
    exit 0
}

try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf((Join-Path $installDir 'CodexQuotaWidget.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

if (Test-Path -LiteralPath $startupShortcut) { Remove-Item -LiteralPath $startupShortcut -Force }
if (Test-Path -LiteralPath $startMenuDir) { Remove-Item -LiteralPath $startMenuDir -Recurse -Force }
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }

[pscustomobject]@{ uninstalled=$true } | ConvertTo-Json

