# Status.Tests.ps1 - which single status the chrome header is allowed to show.
#
# The dot and the header text used to be wired to Claude alone: a Codex 401 left
# the dot green, and a Claude hiccup wiped the only timestamp in the window.
# Pure logic, no WPF types, so this runs headless under Pester 5.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\Config.ps1')
    . (Join-Path $script:Root 'src\Status.ps1')

    $script:AllOn = @{ claude = $true; codex = $true; cursor = $true; grok = $true }
}

Describe 'Get-ProviderStatusSeverity' {
    It 'ranks an expired login above every other state' {
        $auth = Get-ProviderStatusSeverity 'auth'
        foreach ($other in 'error', 'stale', 'ok', 'init', 'notoken', 'unavailable') {
            $auth | Should -BeGreaterThan (Get-ProviderStatusSeverity $other)
        }
    }

    It 'ranks error above stale above ok' {
        (Get-ProviderStatusSeverity 'error') | Should -BeGreaterThan (Get-ProviderStatusSeverity 'stale')
        (Get-ProviderStatusSeverity 'stale') | Should -BeGreaterThan (Get-ProviderStatusSeverity 'ok')
    }

    It 'ranks ok above the states that say nothing yet' {
        $ok = Get-ProviderStatusSeverity 'ok'
        foreach ($quiet in 'init', 'refreshing', 'unavailable', 'notoken', '', $null, 'wat') {
            $ok | Should -BeGreaterThan (Get-ProviderStatusSeverity $quiet)
        }
    }

    It 'treats never-logged-in as a setup gap, not an alarm' {
        # unified-overlay.ps1 maps notoken to 'unavailable' before it asks
        # Test-ProviderAuthFailed; a fresh install must not show a red header.
        (Get-ProviderStatusSeverity 'notoken') |
            Should -Be (Get-ProviderStatusSeverity 'unavailable')
        (Get-ProviderStatusSeverity 'notoken') |
            Should -BeLessThan (Get-ProviderStatusSeverity 'auth')
    }

    It 'ignores case and surrounding whitespace' {
        (Get-ProviderStatusSeverity ' AUTH ') | Should -Be (Get-ProviderStatusSeverity 'auth')
    }
}

Describe 'Get-WorstProviderStatus' {
    It 'reports ok when every enabled provider is healthy' {
        $s = @{ claude = 'ok'; codex = 'ok'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status | Should -Be 'ok'
    }

    It 'surfaces a Codex auth failure instead of leaving the dot green' {
        # The reported bug: Codex/Cursor/Grok could 401 while the header stayed green.
        $s = @{ claude = 'ok'; codex = 'auth'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'codex'
    }

    It 'surfaces a Cursor auth failure' {
        $s = @{ claude = 'ok'; codex = 'ok'; cursor = 'auth'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'cursor'
    }

    It 'surfaces a Grok auth failure' {
        $s = @{ claude = 'ok'; codex = 'ok'; cursor = 'ok'; grok = 'auth' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'grok'
    }

    It 'lets auth outrank stale when several providers are unhappy' {
        $s = @{ claude = 'stale'; codex = 'ok'; cursor = 'ok'; grok = 'auth' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'grok'
    }

    It 'lets error outrank stale' {
        $s = @{ claude = 'stale'; codex = 'error'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'error'
        $r.Provider | Should -Be 'codex'
    }

    It 'keeps stale when that is the worst thing happening' {
        $s = @{ claude = 'ok'; codex = 'stale'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'stale'
        $r.Provider | Should -Be 'codex'
    }

    It 'ignores a failing provider the user has disabled' {
        $enabled = @{ claude = $true; codex = $false; cursor = $true; grok = $true }
        $s = @{ claude = 'ok'; codex = 'auth'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
        $r.Status   | Should -Be 'ok'
        $r.Provider | Should -Not -Be 'codex'
    }

    It 'keeps the Claude-hidden gate (MS-HIDE-CLAUDE-AUTH-CHROME)' {
        # Claude hidden by the user must not push auth/stale/error into the chrome.
        $enabled = @{ claude = $false; codex = $true; cursor = $true; grok = $true }
        foreach ($bad in 'auth', 'error', 'stale') {
            $s = @{ claude = $bad; codex = 'ok'; cursor = 'ok'; grok = 'ok' }
            $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
            $r.Status   | Should -Be 'ok'
            $r.Provider | Should -Not -Be 'claude'
        }
    }

    It 'stays neutral when every section is switched off' {
        $enabled = @{ claude = $false; codex = $false; cursor = $false; grok = $false }
        $s = @{ claude = 'auth'; codex = 'error'; cursor = 'auth'; grok = 'stale' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
        $r.Status   | Should -Be 'init'
        $r.Provider | Should -BeNullOrEmpty
    }

    It 'stays on init while nothing has reported yet' {
        $s = @{ claude = 'init'; codex = 'init'; cursor = 'init'; grok = 'init' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status | Should -Be 'init'
    }

    It 'prefers a provider that reported ok over one still initialising' {
        $s = @{ claude = 'init'; codex = 'ok'; cursor = 'init'; grok = 'init' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'ok'
        $r.Provider | Should -Be 'codex'
    }

    It 'reports unavailable rather than auth for a provider never logged in' {
        $s = @{ claude = 'notoken'; codex = 'notoken'; cursor = 'notoken'; grok = 'notoken' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status | Should -Be 'unavailable'
    }

    It 'treats an unknown status word as saying nothing' {
        $s = @{ claude = 'refreshing'; codex = 'banana'; cursor = 'ok'; grok = '' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Status   | Should -Be 'ok'
        $r.Provider | Should -Be 'cursor'
    }

    It 'treats a missing status entry as not-yet-reported' {
        $r = Get-WorstProviderStatus -Status @{ codex = 'ok' } -Enabled $script:AllOn
        $r.Status   | Should -Be 'ok'
        $r.Provider | Should -Be 'codex'
    }

    It 'treats a missing Enabled map as every provider enabled' {
        $s = @{ claude = 'ok'; codex = 'auth'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $null
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'codex'
    }

    It 'treats a provider missing from the Enabled map as enabled' {
        $s = @{ claude = 'ok'; codex = 'auth'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled @{ claude = $true }
        $r.Status   | Should -Be 'auth'
        $r.Provider | Should -Be 'codex'
    }

    It 'reads a settings map that came back from JSON as an object' {
        # Cfg.Sections is a PSCustomObject when the settings file round-trips.
        $enabled = [pscustomobject]@{ claude = $true; codex = $false; cursor = $true; grok = $true }
        $s = [pscustomobject]@{ claude = 'ok'; codex = 'auth'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
        $r.Status | Should -Be 'ok'
    }

    It 'breaks ties in the section order shown on screen' {
        $s = @{ claude = 'auth'; codex = 'auth'; cursor = 'auth'; grok = 'auth' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $script:AllOn
        $r.Provider | Should -Be 'claude'
    }

    It 'survives a completely empty call' {
        $r = Get-WorstProviderStatus -Status @{} -Enabled @{}
        $r.Status | Should -Be 'init'
    }
}

Describe 'Get-ChromeStatusText' {
    It 'keeps the last-fetch time while everything enabled is healthy' {
        Get-ChromeStatusText -Status 'ok' -Provider 'claude' -LastFetch '14:32' |
            Should -Be '14:32'
    }

    It 'names the unhappy provider rather than a different one message' {
        Get-ChromeStatusText -Status 'auth' -Provider 'codex' -LastFetch '14:32' |
            Should -Be 'CODEX auth'
    }

    It 'names the culprit for stale and error too' {
        Get-ChromeStatusText -Status 'stale' -Provider 'cursor' -LastFetch '14:32' |
            Should -Be 'CURSOR stale'
        Get-ChromeStatusText -Status 'error' -Provider 'grok' -LastFetch '14:32' |
            Should -Be 'GROK error'
    }

    It 'keeps the timestamp for the quiet non-alarm states' {
        foreach ($quiet in 'init', 'unavailable', 'refreshing') {
            Get-ChromeStatusText -Status $quiet -Provider 'codex' -LastFetch '14:32' |
                Should -Be '14:32'
        }
    }

    It 'falls back to empty text when there is no timestamp yet' {
        Get-ChromeStatusText -Status 'ok' -Provider 'claude' -LastFetch '' | Should -Be ''
        Get-ChromeStatusText -Status 'init' -Provider $null -LastFetch $null | Should -Be ''
    }

    It 'still reports the trouble when no provider was named' {
        Get-ChromeStatusText -Status 'auth' -Provider $null -LastFetch '14:32' |
            Should -Be 'auth'
    }

    It 'shows manual-refresh feedback over everything else while it runs' {
        # Invoke-ManualRefresh sets 'refreshing...' so the click visibly landed.
        Get-ChromeStatusText -Status 'ok' -Provider 'claude' -LastFetch '14:32' -Busy 'refreshing...' |
            Should -Be 'refreshing...'
        Get-ChromeStatusText -Status 'auth' -Provider 'codex' -LastFetch '14:32' -Busy 'refreshing...' |
            Should -Be 'refreshing...'
    }

    It 'ignores an empty busy message' {
        Get-ChromeStatusText -Status 'auth' -Provider 'codex' -LastFetch '14:32' -Busy '' |
            Should -Be 'CODEX auth'
    }
}

Describe 'Get-StatusDotColor' {
    It 'keeps the palette the chrome dot has always used' {
        Get-StatusDotColor 'ok'    | Should -Be '#4ADE80'
        Get-StatusDotColor 'stale' | Should -Be '#FBBF24'
        Get-StatusDotColor 'auth'  | Should -Be '#F87171'
        Get-StatusDotColor 'error' | Should -Be '#F87171'
    }

    It 'paints the no-information states neutral slate' {
        foreach ($quiet in 'init', 'refreshing', 'unavailable', 'notoken', '', $null) {
            Get-StatusDotColor $quiet | Should -Be '#4B6A8A'
        }
    }
}

Describe 'Get-SectionStatusTip' {
    It 'explains a failure with the provider message' {
        Get-SectionStatusTip -Status 'auth' -Message 'Codex login expired - run codex login' |
            Should -Be 'auth - Codex login expired - run codex login'
    }

    It 'says when a healthy provider last fetched, if it knows' {
        Get-SectionStatusTip -Status 'ok' -Message '' -LastFetch '14:32' | Should -Be 'ok 14:32'
        Get-SectionStatusTip -Status 'ok' -Message '' -LastFetch '' | Should -Be 'ok'
    }

    It 'names never-logged-in the same way the snapshot does' {
        Get-SectionStatusTip -Status 'notoken' -Message 'run grok login' |
            Should -Be 'unavailable - run grok login'
    }

    It 'falls back to the state word alone' {
        Get-SectionStatusTip -Status $null | Should -Be 'init'
    }
}

Describe 'Status module is wired into the shell' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:Entry = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
    }

    It 'dot-sources Status.ps1 before Shell.ps1' {
        $status = $script:Entry.IndexOf("src\Status.ps1")
        $shell = $script:Entry.IndexOf("src\Shell.ps1")
        $status | Should -BeGreaterThan -1
        $status | Should -BeLessThan $shell
    }

    It 'feeds every provider status into the chrome decision' {
        $start = $script:Shell.IndexOf('function Update-AllSections {')
        $start | Should -BeGreaterThan -1
        $fn = $script:Shell.Substring($start)
        $fn | Should -Match 'Get-WorstProviderStatus'
        $fn | Should -Match 'Get-ChromeStatusText'
        $fn | Should -Match 'Get-StatusDotColor'
        $fn | Should -Match 'claude\s*=\s*\$status'
        $fn | Should -Match 'codex\s*=\s*\$script:CodexAuthState'
        $fn | Should -Match 'cursor\s*=\s*\$script:AuthState'
        $fn | Should -Match 'grok\s*=\s*\$script:GrokAuthState'
        $fn | Should -Match 'Cfg\.Sections'
    }

    It 'no longer shows Claude message in the header regardless of who failed' {
        $script:Shell | Should -Not -Match 'elseif \(\$claudeShown\)'
    }

    It 'gives every section its own status dot' {
        foreach ($n in 'claudeStatusDot', 'codexStatusDot', 'cursorStatusDot', 'grokStatusDot') {
            $script:Shell | Should -Match ('x:Name="{0}"' -f $n)
        }
        $script:Shell | Should -Match 'function Set-SectionStatusDots'
    }

    It 'keeps the section dots off the vertical budget' {
        # 5 DIP inside a 12pt header row cannot grow it; a Margin with any top or
        # bottom component could. ShellFit.Tests.ps1 pins the real measurement.
        $dots = [regex]::Matches($script:Shell, '<Ellipse x:Name="\w+StatusDot"[^>]*>')
        $dots.Count | Should -Be 4
        foreach ($d in $dots) {
            $d.Value | Should -Match 'Height="5"'
            $d.Value | Should -Match 'Margin="0,0,7,0"'
        }
    }
}
