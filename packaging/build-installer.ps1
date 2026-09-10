# Builds the Inno Setup installer artifact.
[CmdletBinding()]
param(
    [string]$Version = '0.4.1',
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'

$issPath = Join-Path $PSScriptRoot 'inno\AIUsageOverlay.iss'
$resolvedOutput = New-Item -ItemType Directory -Force -Path $OutputDir
$buildDir = New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'build')
Set-Content -Path (Join-Path $buildDir.FullName 'app-version.txt') -Value $Version -Encoding ASCII

$isccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$iscc = if ($isccCandidates.Count -gt 0) {
    @($isccCandidates)[0]
} else {
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
}

if (-not $iscc) {
    throw 'Inno Setup 6 is required. Install it from https://jrsoftware.org/isinfo.php or add ISCC.exe to PATH.'
}

& $iscc `
    "/DAppVersion=$Version" `
    "/O$($resolvedOutput.FullName)" `
    $issPath

if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

$artifact = Join-Path $resolvedOutput.FullName 'AIUsageOverlaySetup.exe'
if (-not (Test-Path $artifact)) {
    throw "Expected installer artifact was not created: $artifact"
}

Write-Host "Created $artifact"
