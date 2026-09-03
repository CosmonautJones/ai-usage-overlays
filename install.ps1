# AI Usage Overlay - one-liner installer
# Installs the unified Claude Code + Codex + Cursor + Grok usage overlay.
#
# Run in PowerShell (or paste to your Claude / Cursor agent):
#   irm https://raw.githubusercontent.com/CosmonautJones/ai-usage-overlays/master/install.ps1 | iex

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Windows PowerShell 5.1 or PowerShell 7+ is required.'
}

$repo    = 'https://github.com/CosmonautJones/ai-usage-overlays/archive/refs/heads/master.zip'
$zip     = Join-Path $env:TEMP 'ai-usage-overlays.zip'
$extract = Join-Path $env:TEMP 'ai-usage-overlays-extract'
$src     = Join-Path $extract  'ai-usage-overlays-master'

Write-Host 'Downloading AI Usage Overlays...'
Invoke-WebRequest $repo -OutFile $zip -UseBasicParsing

Write-Host 'Extracting...'
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive $zip $extract -Force

$ps = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $ps) { $ps = (Get-Command powershell.exe -ErrorAction Stop) }

Write-Host 'Installing unified AI usage overlay...'
$dest = "$env:LOCALAPPDATA\AIUsageOverlay"
New-Item -ItemType Directory -Force $dest | Out-Null
New-Item -ItemType Directory -Force (Join-Path $dest 'src') | Out-Null

Copy-Item "$src\unified-overlay.ps1" $dest -Force
Copy-Item "$src\Start-Unified.vbs"   $dest -Force
Copy-Item "$src\Install.bat"         $dest -Force
Copy-Item "$src\Uninstall.bat"       $dest -Force
Copy-Item "$src\sqlite3.exe"         $dest -Force
Copy-Item "$src\src\*"               (Join-Path $dest 'src') -Recurse -Force
if (Test-Path "$src\assets") { Copy-Item "$src\assets" $dest -Recurse -Force }

& $ps.Source -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$dest\unified-overlay.ps1" -Install

# Cleanup
Remove-Item $zip     -Force        -ErrorAction SilentlyContinue
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Done! The unified overlay is installed and running.'
Write-Host 'Look for the AI icon in your system tray.'
Write-Host 'Right-click the overlay for options, themes, opacity, and section toggles.'
