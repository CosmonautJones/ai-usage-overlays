#Requires -Module Pester
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $script:root
    $script:ErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'overlay-grok-test.log'
    . (Join-Path $script:root 'src\Config.ps1')
    . (Join-Path $script:root 'src\GrokData.ps1')
}

Describe 'Grok auth-state contract' {
    It 'exposes an auth state and error message like Codex does' {
        $script:GrokAuthState | Should -Not -BeNullOrEmpty
        Get-Variable -Name GrokErrMsg -Scope Script -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'initialises auth state to init' {
        $script:GrokAuthState | Should -Be 'init'
    }
}

Describe 'ConvertFrom-GrokBillingResponse' {
    It 'reads weekly percent and period end from config' {
        $obj = [pscustomobject]@{
            config = [pscustomobject]@{
                creditUsagePercent = 42.5
                currentPeriod = [pscustomobject]@{ end = '2026-09-08T00:00:00Z' }
                product = 'SuperGrok'
            }
            prepaidBalance = 12.5
        }

        $parsed = ConvertFrom-GrokBillingResponse $obj
        $parsed.WeekPct | Should -Be 42.5
        $parsed.WeekResetsAt | Should -Not -BeNullOrEmpty
        $parsed.PlanType | Should -Be 'SuperGrok'
        $parsed.PrepaidBalance | Should -Be '12.50'
    }

    It 'tolerates missing optional fields' {
        $parsed = ConvertFrom-GrokBillingResponse ([pscustomobject]@{})
        $parsed.WeekPct | Should -BeNullOrEmpty
        $parsed.WeekResetsAt | Should -BeNullOrEmpty
        $parsed.PlanType | Should -BeNullOrEmpty
        $parsed.PrepaidBalance | Should -BeNullOrEmpty
    }
}

Describe 'Get-GrokLiveUsage auth reporting' {
    BeforeEach {
        $script:GrokAuthState = 'init'
        $script:GrokErrMsg    = ''
        $script:GrokUsage     = $null
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("grok-auth-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports notoken when auth.json is absent' {
        $missing = Join-Path $script:sandbox 'nope\auth.json'
        Get-GrokLiveUsage -AuthPath $missing | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'notoken'
        $script:GrokErrMsg    | Should -Match 'grok login'
    }

    It 'reports notoken when auth.json holds no access token' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{}}' | Set-Content -LiteralPath $p
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'notoken'
    }

    It 'accepts a top-level access_token' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"access_token":"a.b.c"}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('Response status code does not indicate success: 401 (Unauthorized).') }
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'auth'
        $script:GrokErrMsg | Should -Match 'grok login'
    }

    It 'reports auth when the endpoint returns 401' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{"access_token":"a.b.c"}}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('Response status code does not indicate success: 401 (Unauthorized).') }
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'auth'
        $script:GrokErrMsg | Should -Match 'grok login'
    }

    It 'reports stale for non-auth request failures' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"tokens":{"access_token":"a.b.c"}}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw 'The operation has timed out.' }
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'stale'
    }

    It 'never writes the bearer into the error message' {
        $p = Join-Path $script:sandbox 'auth.json'
        '{"access_token":"super-secret-token-value"}' | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw 'The operation has timed out.' }
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokErrMsg | Should -Not -Match 'super-secret-token-value'
        $script:GrokErrMsg | Should -Not -Match 'Bearer'
    }
}
