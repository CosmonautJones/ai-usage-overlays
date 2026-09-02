#Requires -Module Pester
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $script:root
    $script:ErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'overlay-align-test.log'
    . (Join-Path $script:root 'src\Config.ps1')
    . (Join-Path $script:root 'src\Pricing.ps1')
    . (Join-Path $script:root 'src\CodexData.ps1')
    . (Join-Path $script:root 'src\CursorData.ps1')
    . (Join-Path $script:root 'src\GrokData.ps1')
}

# Every provider must expose the SAME status/message contract. Codex silently
# returned $null on a 401 for 13 days because it had no such contract at all -
# these tests exist so a new provider cannot repeat that.
Describe 'Provider auth-state contract' {
    It 'Codex exposes an auth state and error message like Cursor does' {
        $script:CodexAuthState | Should -Not -BeNullOrEmpty
        Get-Variable -Name CodexErrMsg -Scope Script -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Grok exposes an auth state and error message like Codex does' {
        $script:GrokAuthState | Should -Not -BeNullOrEmpty
        Get-Variable -Name GrokErrMsg -Scope Script -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Codex and Cursor initialise their auth state identically' {
        $script:CodexAuthState | Should -Be 'init'
        $script:AuthState      | Should -Be 'init'
        $script:GrokAuthState  | Should -Be 'init'
    }

    It 'shares one definition of what counts as an auth failure' {
        Test-ProviderAuthFailed 'auth'    | Should -BeTrue
        Test-ProviderAuthFailed 'notoken' | Should -BeTrue
        Test-ProviderAuthFailed 'ok'      | Should -BeFalse
        Test-ProviderAuthFailed 'init'    | Should -BeFalse
        Test-ProviderAuthFailed 'stale'   | Should -BeFalse
        Test-ProviderAuthFailed ''        | Should -BeFalse
        Test-ProviderAuthFailed $null     | Should -BeFalse
    }
}

Describe 'Get-CodexLiveUsage auth reporting' {
    BeforeEach {
        $script:CodexAuthState = 'init'
        $script:CodexErrMsg    = ''
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-auth-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports notoken when auth.json is absent' {
        $missing = Join-Path $script:sandbox 'nope\auth.json'
        Get-CodexLiveUsage -AuthPath $missing | Should -BeNullOrEmpty
        $script:CodexAuthState | Should -Be 'notoken'
        $script:CodexErrMsg    | Should -Not -BeNullOrEmpty
    }

    It 'reports notoken when auth.json holds no access token' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{}}' | Set-Content -LiteralPath $p
        Get-CodexLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:CodexAuthState | Should -Be 'notoken'
    }

    It 'reports auth (not silence) when the endpoint returns 401' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{"access_token":"a.b.c","account_id":"acct"}}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('Response status code does not indicate success: 401 (Unauthorized).') }
        Get-CodexLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:CodexAuthState | Should -Be 'auth'
        # Must name the remedy - a bare "401" taught us nothing for 13 days.
        $script:CodexErrMsg | Should -Match 'codex login'
    }

    It 'reports stale for non-auth request failures' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{"access_token":"a.b.c"}}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw 'The operation has timed out.' }
        Get-CodexLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:CodexAuthState | Should -Be 'stale'
    }
}

Describe 'Snapshot alignment' {
    BeforeAll {
        $script:src = Get-Content (Join-Path $script:root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $start = $script:src.IndexOf('$providers = [ordered]@{')
        $end = $script:src.IndexOf('$snapshot = [ordered]@{', $start)
        $script:block = $script:src.Substring($start, $end - $start)
    }

    It 'exposes a message field for every provider' {
        # Scope each assertion to that provider's own [ordered]@{ ... } literal so
        # a missing field cannot be masked by the next provider's block.
        foreach ($p in 'claude', 'codex', 'cursor', 'grok') {
            $m = [regex]::Match($script:block, "providers\.$p\s*=\s*\[ordered\]@\{(.+?)\r?\n\s{8}\}", 'Singleline')
            $m.Success | Should -BeTrue -Because "the $p snapshot block must be parseable"
            $m.Groups[1].Value | Should -Match 'message\s*=' -Because "$p must report WHY it is unhealthy, not just that it is"
        }
    }

    It 'derives codex status from its auth state, not merely from parsed local stats' {
        # The 13-day silent failure: local logs parsed fine, so status said "ok"
        # while the live quota was 401ing.
        $script:block | Should -Match 'CodexAuthState'
    }
}
