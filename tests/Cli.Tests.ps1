#Requires -Module Pester

Describe 'Unified overlay CLI snapshot mode' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:UnifiedOverlaySource = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
    }

    It 'declares snapshot switches' {
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$Json'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$Snapshot'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$NoHud'
        $script:UnifiedOverlaySource | Should -Match '\[string\[\]\]\$Provider'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$ClaudeOnly'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$CodexOnly'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$CursorOnly'
        $script:UnifiedOverlaySource | Should -Match '\[switch\]\$GrokOnly'
        $script:UnifiedOverlaySource | Should -Match '\[int\]\$TimeoutSec'
        $script:UnifiedOverlaySource | Should -Match '\[int\]\$ClaudeTimeoutSec'
        $script:UnifiedOverlaySource | Should -Match '\[int\]\$CursorTimeoutSec'
    }

    It 'declares the versioned JSON schema and normalized provider envelope' {
        $script:UnifiedOverlaySource | Should -Match "schema = 'ai-usage\.snapshot\.v1'"
        $script:UnifiedOverlaySource | Should -Match 'providers = \$providers'
        $script:UnifiedOverlaySource | Should -Match 'claude = New-SkippedProviderSnapshot'
        $script:UnifiedOverlaySource | Should -Match 'codex\s+= New-SkippedProviderSnapshot'
        $script:UnifiedOverlaySource | Should -Match 'cursor = New-SkippedProviderSnapshot'
        $script:UnifiedOverlaySource | Should -Match 'grok\s+= New-SkippedProviderSnapshot'
    }

    It 'filters providers before invoking provider data fetchers' {
        $resolveIndex = $script:UnifiedOverlaySource.IndexOf('$selectedProviders = Resolve-SnapshotProviders')
        $claudeFetchIndex = $script:UnifiedOverlaySource.IndexOf("Get-Usage -TimeoutSec `$claudeTimeout")
        $codexFetchIndex = $script:UnifiedOverlaySource.IndexOf('Get-CodexStats')
        $cursorFetchIndex = $script:UnifiedOverlaySource.IndexOf("Get-CursorUsage -TimeoutSec `$cursorTimeout")

        $resolveIndex | Should -BeGreaterThan -1
        $claudeFetchIndex | Should -BeGreaterThan -1
        $codexFetchIndex | Should -BeGreaterThan -1
        $cursorFetchIndex | Should -BeGreaterThan -1
        $resolveIndex | Should -BeLessThan $claudeFetchIndex
        $resolveIndex | Should -BeLessThan $codexFetchIndex
        $resolveIndex | Should -BeLessThan $cursorFetchIndex
    }

    It 'bounds network provider timeouts and passes them to Claude and Cursor' {
        $script:UnifiedOverlaySource | Should -Match 'Limit-SnapshotTimeoutSec'
        $script:UnifiedOverlaySource | Should -Match 'Get-Usage -TimeoutSec \$claudeTimeout'
        $script:UnifiedOverlaySource | Should -Match 'Get-CursorUsage -TimeoutSec \$cursorTimeout'
        $script:UnifiedOverlaySource | Should -Match 'Get-CursorLocalStats -TimeoutSec \$cursorTimeout'
    }

    It 'exits through snapshot output before WPF startup' {
        $snapshotIndex = $script:UnifiedOverlaySource.IndexOf('if ($Json -or $Snapshot -or $NoHud)')
        $wpfIndex = $script:UnifiedOverlaySource.IndexOf('Add-Type -AssemblyName PresentationFramework')

        $snapshotIndex | Should -BeGreaterThan -1
        $wpfIndex | Should -BeGreaterThan -1
        $snapshotIndex | Should -BeLessThan $wpfIndex
    }
}
