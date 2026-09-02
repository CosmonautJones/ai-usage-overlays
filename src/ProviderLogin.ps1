# ProviderLogin.ps1 - tray-spawned CLI login (claude / codex / grok)
#
# Resolve via Get-Command. Never mutate PATH. Never write auth.json or tokens.
# Spawn a visible console; OAuth finishes in the CLI's browser/device prompt.

function Resolve-ProviderLoginCli {
    param([Parameter(Mandatory = $true)][string]$CliName)

    $cmd = Get-Command -Name $CliName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }

    if ([string]$cmd.CommandType -eq 'Alias' -and $cmd.ResolvedCommand) {
        $cmd = $cmd.ResolvedCommand
    }

    $path = $null
    if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) {
        $path = [string]$cmd.Source
    } elseif ($cmd.PSObject.Properties['Path'] -and $cmd.Path) {
        $path = [string]$cmd.Path
    }

    if (-not $path) { return $null }

    [pscustomobject]@{
        Name        = $CliName
        Path        = $path
        CommandType = [string]$cmd.CommandType
    }
}

function Get-ProviderLoginMenuCaption {
    param(
        [Parameter(Mandatory = $true)][string]$CliName,
        $Resolved
    )

    if ($Resolved) { return "Log in $CliName" }
    return "$CliName not installed"
}

function Get-ProviderLoginRefreshKinds {
    param([Parameter(Mandatory = $true)][string]$Provider)

    switch -Regex ($Provider) {
        '^(?i)claude$' { @('ClaudeUsage', 'ClaudeStats') }
        '^(?i)codex$'  { @('CodexStats') }
        '^(?i)grok$'   { @('GrokUsage') }
        default        { @() }
    }
}

function Start-ProviderLoginProcess {
    param($Resolved)

    if (-not $Resolved -or -not $Resolved.Path) { return $null }

    # Visible console (do not hide the window). Click thread must not wait.
    Start-Process -FilePath $Resolved.Path -ArgumentList 'login' -PassThru
}
