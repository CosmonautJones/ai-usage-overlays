#Requires -Module Pester

Describe 'Provider login CLI resolve' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLogin.ps1')
    }

    It 'returns null when Get-Command finds nothing and grok.exe is absent' {
        Mock Get-Command { $null }
        Mock Test-Path { $false }
        Resolve-ProviderLoginCli 'grok' | Should -BeNullOrEmpty
    }

    It 'falls back to ~/.grok/bin/grok.exe when Get-Command misses grok' {
        Mock Get-Command { $null }
        Mock Test-Path { $true }
        $resolved = Resolve-ProviderLoginCli 'grok'
        $resolved.Name | Should -Be 'grok'
        $resolved.Path | Should -Match '[\\/]\.grok[\\/]bin[\\/]grok\.exe$'
        $resolved.CommandType | Should -Be 'Application'
    }

    It 'resolves via Get-Command Source and does not mutate PATH' {
        $before = $env:PATH
        Mock Get-Command {
            [pscustomobject]@{
                Name        = 'claude'
                Source      = 'C:\tools\claude.exe'
                Path        = 'C:\tools\claude.exe'
                CommandType = 'Application'
            }
        }

        $resolved = Resolve-ProviderLoginCli 'claude'
        $resolved.Name | Should -Be 'claude'
        $resolved.Path | Should -Be 'C:\tools\claude.exe'
        $env:PATH | Should -Be $before
    }
}

Describe 'Provider login menu caption' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLogin.ps1')
    }

    It 'uses Log in <cli> when the CLI is present' {
        $resolved = [pscustomobject]@{ Name = 'codex'; Path = 'C:\tools\codex.exe' }
        Get-ProviderLoginMenuCaption -CliName 'codex' -Resolved $resolved | Should -Be 'Log in codex'
    }

    It 'uses <cli> not installed when the CLI is missing' {
        Get-ProviderLoginMenuCaption -CliName 'grok' -Resolved $null | Should -Be 'grok not installed'
    }
}

Describe 'Provider login refresh kinds' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLogin.ps1')
    }

    It 'maps each provider to its refresh job kinds' {
        Get-ProviderLoginRefreshKinds 'Claude' | Should -Be @('ClaudeUsage', 'ClaudeStats')
        Get-ProviderLoginRefreshKinds 'Codex' | Should -Be @('CodexStats')
        Get-ProviderLoginRefreshKinds 'Grok' | Should -Be @('GrokUsage')
    }
}

Describe 'Start-ProviderLoginProcess' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLogin.ps1')
    }

    It 'does nothing and does not throw when the CLI is missing' {
        Mock Start-Process { throw 'should not spawn' }
        { Start-ProviderLoginProcess $null } | Should -Not -Throw
        Assert-MockCalled Start-Process -Times 0 -Exactly
    }

    It 'starts a visible login process and never hides the window' {
        Mock Start-Process {
            [pscustomobject]@{ Id = 4242 }
        }

        $resolved = [pscustomobject]@{ Name = 'claude'; Path = 'C:\tools\claude.exe' }
        $proc = Start-ProviderLoginProcess $resolved
        $proc.Id | Should -Be 4242

        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\tools\claude.exe' -and
            @($ArgumentList) -contains 'login' -and
            "$WindowStyle" -ne 'Hidden'
        }
    }
}

Describe 'Tray login menu wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:UnifiedTraySource = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
        $script:OverlaySource = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $script:LoginSource = Get-Content (Join-Path $root 'src\ProviderLogin.ps1') -Raw -Encoding UTF8
    }

    It 'dots ProviderLogin.ps1 into the overlay' {
        $script:OverlaySource | Should -Match "src\\ProviderLogin\.ps1"
    }

    It 'adds Log in tray items and syncs enabled state from Get-Command' {
        $script:UnifiedTraySource | Should -Match 'Sync-ProviderLoginMenuItems'
        $script:UnifiedTraySource | Should -Match 'Invoke-ProviderLogin'
        $script:UnifiedTraySource | Should -Match "Log in"
        $script:LoginSource | Should -Match 'not installed'
        $script:UnifiedTraySource | Should -Match 'Get-ProviderLoginMenuCaption'
    }

    It 'waits for the login process off the click thread then Force-refreshes that provider' {
        $script:UnifiedTraySource | Should -Match 'function Invoke-ProviderLogin'
        $script:UnifiedTraySource | Should -Match 'Start-ProviderLoginProcess'
        $script:UnifiedTraySource | Should -Match 'Start-OverlayBackgroundJob'
        $script:UnifiedTraySource | Should -Match 'WaitForExit'
        $script:UnifiedTraySource | Should -Match 'Complete-ProviderLoginWatchers'
        $script:OverlaySource | Should -Match 'Complete-ProviderLoginWatchers'
        $script:UnifiedTraySource | Should -Match 'Start-AllRefreshJobs -Force -Kind'
    }

    It 'does not hide the login console or mutate PATH' {
        $script:LoginSource | Should -Not -Match 'WindowStyle Hidden'
        $script:LoginSource | Should -Not -Match '\$env:PATH\s*='
        $script:UnifiedTraySource | Should -Not -Match 'WindowStyle Hidden'
        $script:LoginSource | Should -Match 'Get-Command'
    }
}

Describe 'Start-AllRefreshJobs provider Kind filter' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $source = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $start = $source.IndexOf('function Start-AllRefreshJobs {')
        $end = $source.IndexOf("`nfunction Complete-RefreshJobs {", $start)
        . ([scriptblock]::Create($source.Substring($start, $end - $start)))

        function Write-Log { param([string]$Message) }
        function Start-OverlayBackgroundJob {
            param(
                [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
                [object[]]$ArgumentList = @()
            )
        }
    }

    BeforeEach {
        $script:pollJobs = @{}
        $script:pollJobStartedAt = @{}
        $script:ClaudeUsageScript = {}
        $script:ClaudeStatsScript = {}
        $script:CodexStatsScript = {}
        $script:GrokUsageScript = {}
        $script:AppDir = 'C:\overlay'
        $script:CredPath = 'C:\overlay\credentials.json'
        $script:ErrLog = 'C:\overlay\errors.log'
        $script:nextJobId = 0

        Mock Start-OverlayBackgroundJob {
            $script:nextJobId++
            [pscustomobject]@{ State = 'Running'; Id = $script:nextJobId }
        }
        Mock Stop-Job {}
        Mock Remove-Job {}
        Mock Write-Log {}
    }

    It 'starts only GrokUsage when Kind is GrokUsage' {
        Start-AllRefreshJobs -Force -Kind @('GrokUsage')
        Assert-MockCalled Start-OverlayBackgroundJob -Times 1 -Exactly
        $script:pollJobs.Keys | Should -Be 'GrokUsage'
    }
}
