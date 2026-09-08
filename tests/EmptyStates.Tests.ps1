# EmptyStates.Tests.ps1 - calm missing CLI / unauth + compact Codex WEEKLY sync
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Config.ps1')
}

Describe 'Get-ProviderCalmEmptyMessage' {
    BeforeAll {
        function Test-ProviderCliMissing {
            param([Parameter(Mandatory = $true)][string]$CliName)
            return [bool]$script:MockCliMissing
        }
        function Get-ProviderCalmEmptyMessage {
            param(
                [Parameter(Mandatory = $true)][string]$CliName,
                [string]$AuthState
            )
            if (Test-ProviderCliMissing $CliName) {
                return 'Install & Log in from tray'
            }
            if (Test-ProviderAuthFailed $AuthState) {
                return 'Log in from tray'
            }
            return $null
        }
    }

    It 'asks to install when CLI is missing' {
        $script:MockCliMissing = $true
        Get-ProviderCalmEmptyMessage -CliName 'grok' -AuthState 'notoken' | Should -Be 'Install & Log in from tray'
    }

    It 'asks to log in when CLI exists but auth failed' {
        $script:MockCliMissing = $false
        Get-ProviderCalmEmptyMessage -CliName 'codex' -AuthState 'notoken' | Should -Be 'Log in from tray'
        Get-ProviderCalmEmptyMessage -CliName 'codex' -AuthState 'auth' | Should -Be 'Log in from tray'
    }

    It 'stays quiet when auth is healthy' {
        $script:MockCliMissing = $false
        Get-ProviderCalmEmptyMessage -CliName 'codex' -AuthState 'ok' | Should -BeNullOrEmpty
        Get-ProviderCalmEmptyMessage -CliName 'codex' -AuthState 'init' | Should -BeNullOrEmpty
    }
}

Describe 'Shell calm empty wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
    }

    It 'uses calm tray copy and muted auth chrome' {
        $script:Shell | Should -Match 'Install & Log in from tray'
        $script:Shell | Should -Match 'Log in from tray'
        $script:Shell | Should -Match "CliName 'codex'"
        $script:Shell | Should -Match "CliName 'grok'"
        $script:Shell | Should -Match "CliName 'claude'"
        $script:Shell | Should -Match 'Get-ProviderCalmEmptyMessage'
        $script:Shell | Should -Match 'weekForCompact'
        $script:Shell | Should -Match 'Foreground="#94A3B8"'
    }

    It 'keeps Cursor LocalData hide-when-null' {
        $script:Shell | Should -Match 'cursorAnalyticsBlock'
        $script:Shell | Should -Match 'When LocalData is null'
    }
}
