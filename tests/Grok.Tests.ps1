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


    It 'reads prepaidBalance and productUsage from config (live billing shape)' {
        $obj = [pscustomobject]@{
            config = [pscustomobject]@{
                creditUsagePercent = 47
                prepaidBalance = [pscustomobject]@{ val = 0 }
                productUsage = @(
                    [pscustomobject]@{ GrokChat = 20 }
                    [pscustomobject]@{ GrokBuild = 19 }
                    [pscustomobject]@{ GrokAppBuilder = 7 }
                    [pscustomobject]@{ GrokImagine = 1 }
                )
            }
        }

        $parsed = ConvertFrom-GrokBillingResponse $obj
        $parsed.WeekPct | Should -Be 47
        $parsed.PrepaidBalance | Should -Be '0.00'
        $parsed.ProductUsageText | Should -Match 'GrokChat 20%'
        $parsed.ProductUsageText | Should -Match 'GrokBuild 19%'
        $parsed.ProductUsageText | Should -Match 'GrokImagine 1%'
    }

    It 'Convert-GrokPrepaidText accepts val note' {
        Convert-GrokPrepaidText ([pscustomobject]@{ val = 12.5 }) | Should -Be '12.50'
        Convert-GrokPrepaidText @{ val = 0 } | Should -Be '0.00'
    }

    It 'still reads top-level prepaidBalance for older payloads' {
        $obj = [pscustomobject]@{
            config = [pscustomobject]@{ creditUsagePercent = 10 }
            prepaidBalance = 3
            productUsage = @([pscustomobject]@{ product = 'GrokChat'; count = 2 })
        }
        $parsed = ConvertFrom-GrokBillingResponse $obj
        $parsed.PrepaidBalance | Should -Be '3.00'
        $parsed.ProductUsageText | Should -Match 'GrokChat'
    }
    It 'tolerates missing optional fields' {
        $parsed = ConvertFrom-GrokBillingResponse ([pscustomobject]@{})
        $parsed.WeekPct | Should -BeNullOrEmpty
        $parsed.WeekResetsAt | Should -BeNullOrEmpty
        $parsed.PlanType | Should -BeNullOrEmpty
        $parsed.PrepaidBalance | Should -BeNullOrEmpty
    }
}

Describe 'Get-GrokAccessToken' {
    It 'reads a nested OIDC key from an auth.x.ai slot' {
        $auth = [pscustomobject]@{
            'https://auth.x.ai::test-client' = [pscustomobject]@{
                key = 'oidc-key-value'
                auth_mode = 'oidc'
                expires_at = ([datetimeoffset]::Now.AddHours(6)).ToString('o')
            }
        }
        Get-GrokAccessToken $auth | Should -Be 'oidc-key-value'
    }

    It 'prefers the auth.x.ai slot over another nested key' {
        $auth = [pscustomobject]@{
            other = [pscustomobject]@{ key = 'other-key' }
            'https://auth.x.ai::test-client' = [pscustomobject]@{ key = 'xai-key' }
        }
        Get-GrokAccessToken $auth | Should -Be 'xai-key'
    }

    It 'skips an expired auth.x.ai slot and uses another key' {
        $auth = [pscustomobject]@{
            'https://auth.x.ai::test-client' = [pscustomobject]@{
                key = 'expired-key'
                expires_at = ([datetimeoffset]::Now.AddHours(-1)).ToString('o')
            }
            other = [pscustomobject]@{ key = 'fresh-key' }
        }
        Get-GrokAccessToken $auth | Should -Be 'fresh-key'
    }

    It 'returns null when the only slot is expired' {
        $auth = [pscustomobject]@{
            'https://auth.x.ai::test-client' = [pscustomobject]@{
                key = 'expired-key'
                expires_at = ([datetimeoffset]::Now.AddHours(-1)).ToString('o')
            }
        }
        Get-GrokAccessToken $auth | Should -BeNullOrEmpty
    }

    It 'still accepts tokens.access_token' {
        $auth = [pscustomobject]@{ tokens = [pscustomobject]@{ access_token = 'a.b.c' } }
        Get-GrokAccessToken $auth | Should -Be 'a.b.c'
    }

    It 'still accepts a top-level access_token' {
        Get-GrokAccessToken ([pscustomobject]@{ access_token = 'a.b.c' }) | Should -Be 'a.b.c'
    }
}

Describe 'Get-GrokLiveUsage auth reporting' {
    BeforeEach {
        Mock Get-GrokRemainingResets { @{ResetsAvailable=$null;ResetStatus='unavailable'} }
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

    It 'treats a nested OIDC key as a present token' {
        $p = Join-Path $script:sandbox 'auth.json'
        $exp = ([datetimeoffset]::Now.AddHours(6)).ToString('o')
        @{ 'https://auth.x.ai::test-client' = @{ key = 'oidc-key-value'; expires_at = $exp } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('Response status code does not indicate success: 401 (Unauthorized).') }
        Get-GrokLiveUsage -AuthPath $p | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'auth'
        $script:GrokErrMsg | Should -Not -Match 'oidc-key-value'
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

Describe 'Format-GrokProductUsage' {
    It 'formats usagePercent chips as Name N% without dumping prop names' {
        $usage = @(
            [pscustomobject]@{ product = 'GrokChat'; usagePercent = 20 }
            [pscustomobject]@{ product = 'GrokBuild'; usagePercent = 5 }
            [pscustomobject]@{ product = 'GrokImagine'; usagePercent = 1 }
        )
        $text = Format-GrokProductUsage $usage
        $text | Should -Be (@('GrokChat 20%', 'GrokBuild 5%', 'GrokImagine 1%') -join [Environment]::NewLine)
        $text | Should -Not -Match 'usagePercent'
    }

    It 'formats shorthand product notes as percent chips' {
        $text = Format-GrokProductUsage @(
            [pscustomobject]@{ GrokChat = 20 }
            [pscustomobject]@{ GrokBuild = 19 }
        )
        $text | Should -Match 'GrokChat 20%'
        $text | Should -Match 'GrokBuild 19%'
        $text | Should -Not -Match 'usagePercent'
    }
}

Describe 'Grok OIDC refresh' {
    BeforeEach {
        Mock Get-GrokRemainingResets { @{ ResetsAvailable = 0; ResetStatus = 'ok'; ResetExpiresAt = $null } }
        $script:GrokAuthState = 'init'
        $script:GrokErrMsg    = ''
        $script:GrokUsage     = $null
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("grok-refresh-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:tokenCalls = 0
        $script:billingAuth = $null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'turns a refresh response into a stored access token without inventing a new refresh token' {
        $now = [datetimeoffset]::Parse('2026-09-25T20:00:00Z')
        $parsed = ConvertFrom-GrokRefreshResponse -Response ([pscustomobject]@{
            access_token = 'fresh-access'
            expires_in   = 3600
        }) -PreviousRefresh 'keep-refresh' -Now $now

        $parsed.AccessToken | Should -Be 'fresh-access'
        $parsed.RefreshToken | Should -Be 'keep-refresh'
        ([datetimeoffset]::Parse($parsed.ExpiresAt)) | Should -Be $now.AddSeconds(3600)
    }

    It 'refreshes an expired session and keeps the weekly reset time' {
        $path = Join-Path $script:sandbox 'auth.json'
        $periodEnd = [datetimeoffset]::UtcNow.AddHours(60)
        @{
            'https://auth.x.ai::test-client' = @{
                key            = 'expired-key'
                refresh_token  = 'refresh-value'
                expires_at     = ([datetimeoffset]::UtcNow.AddHours(-1)).ToString('o')
                auth_mode      = 'oidc'
                oidc_issuer    = 'https://auth.x.ai'
                oidc_client_id = 'test-client'
                email          = 'keep-me@example.com'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8

        Mock Invoke-RestMethod {
            $uriText = [string]$Uri
            if ($uriText -match '/oauth2/token$') {
                $script:tokenCalls++
                $bodyText = [string]$Body
                if ($bodyText -notmatch 'grant_type=refresh_token') { throw 'missing grant' }
                if ($bodyText -notmatch 'client_id=test-client') { throw 'missing client' }
                if ($bodyText -notmatch 'refresh_token=refresh-value') { throw 'missing refresh' }
                return [pscustomobject]@{ access_token = 'fresh-access'; expires_in = 21600 }
            }
            if ($uriText -match '/v1/billing') {
                $script:billingAuth = [string]$Headers['Authorization']
                return [pscustomobject]@{
                    config = [pscustomobject]@{
                        creditUsagePercent = 21
                        currentPeriod = [pscustomobject]@{ end = $periodEnd.ToString('o') }
                    }
                }
            }
            throw "unexpected uri $uriText"
        }

        $usage = Get-GrokLiveUsage -AuthPath $path -TimeoutSec 5
        $usage.WeekPct | Should -Be 21
        $usage.WeekResetsAt | Should -Not -BeNullOrEmpty
        . (Join-Path $script:root 'src\Format.ps1')
        Format-Reset $usage.WeekResetsAt | Should -Match ([regex]::Escape([string][char]0x21BA) + ' \d+d \d+h')
        $script:tokenCalls | Should -Be 1
        $script:billingAuth | Should -Be 'Bearer fresh-access'
        $script:GrokAuthState | Should -Be 'ok'
        $script:GrokErrMsg | Should -Not -Match 'expired-key|fresh-access|refresh-value'

        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $slot = $saved.'https://auth.x.ai::test-client'
        $slot.key | Should -Be 'fresh-access'
        $slot.refresh_token | Should -Be 'refresh-value'
        $slot.email | Should -Be 'keep-me@example.com'
        ([datetimeoffset]::Parse([string]$slot.expires_at)) | Should -BeGreaterThan ([datetimeoffset]::UtcNow.AddHours(4))
    }

    It 'refreshes a token inside the early-expiry window before billing' {
        $path = Join-Path $script:sandbox 'auth.json'
        @{
            'https://auth.x.ai::test-client' = @{
                key            = 'about-to-expire'
                refresh_token  = 'refresh-value'
                expires_at     = ([datetimeoffset]::UtcNow.AddSeconds(120)).ToString('o')
                auth_mode      = 'oidc'
                oidc_issuer    = 'https://auth.x.ai'
                oidc_client_id = 'test-client'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8

        Mock Invoke-RestMethod {
            $uriText = [string]$Uri
            if ($uriText -match '/oauth2/token$') {
                $script:tokenCalls++
                return [pscustomobject]@{ access_token = 'fresh-access'; refresh_token = 'rotated-refresh'; expires_in = 21600 }
            }
            return [pscustomobject]@{ config = [pscustomobject]@{ creditUsagePercent = 4; currentPeriod = [pscustomobject]@{ end = ([datetimeoffset]::UtcNow.AddDays(3)).ToString('o') } } }
        }

        $usage = Get-GrokLiveUsage -AuthPath $path -TimeoutSec 5
        $usage.WeekPct | Should -Be 4
        $script:tokenCalls | Should -Be 1
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.'https://auth.x.ai::test-client'.refresh_token | Should -Be 'rotated-refresh'
        $saved.'https://auth.x.ai::test-client'.key | Should -Be 'fresh-access'
    }

    It 'leaves the saved session alone when refresh is rejected' {
        $path = Join-Path $script:sandbox 'auth.json'
        @{
            'https://auth.x.ai::test-client' = @{
                key            = 'expired-key'
                refresh_token  = 'refresh-value'
                expires_at     = ([datetimeoffset]::UtcNow.AddHours(-2)).ToString('o')
                auth_mode      = 'oidc'
                oidc_issuer    = 'https://auth.x.ai'
                oidc_client_id = 'test-client'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8

        Mock Invoke-RestMethod {
            if ([string]$Uri -match '/oauth2/token$') { throw 'invalid_grant' }
            throw 'billing should not run'
        }

        Get-GrokLiveUsage -AuthPath $path -TimeoutSec 5 | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'auth'
        $script:GrokErrMsg | Should -Not -Match 'expired-key|refresh-value|invalid_grant'
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.'https://auth.x.ai::test-client'.key | Should -Be 'expired-key'
        $saved.'https://auth.x.ai::test-client'.refresh_token | Should -Be 'refresh-value'
    }

    It 'keeps billing with the current token when refresh fails but the access token is still valid' {
        $path = Join-Path $script:sandbox 'auth.json'
        @{
            'https://auth.x.ai::test-client' = @{
                key            = 'still-good'
                refresh_token  = 'refresh-value'
                expires_at     = ([datetimeoffset]::UtcNow.AddHours(5)).ToString('o')
                auth_mode      = 'oidc'
                oidc_issuer    = 'https://auth.x.ai'
                oidc_client_id = 'test-client'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8

        Mock Update-GrokStoredSession { throw 'lock timeout' }
        Mock Invoke-RestMethod {
            $script:billingAuth = [string]$Headers['Authorization']
            return [pscustomobject]@{
                config = [pscustomobject]@{
                    creditUsagePercent = 21
                    currentPeriod = [pscustomobject]@{ end = ([datetimeoffset]::UtcNow.AddHours(60)).ToString('o') }
                }
            }
        }

        $usage = Get-GrokLiveUsage -AuthPath $path -TimeoutSec 5
        $usage.WeekPct | Should -Be 21
        $usage.WeekResetsAt | Should -Not -BeNullOrEmpty
        $script:billingAuth | Should -Be 'Bearer still-good'
        $script:GrokAuthState | Should -Be 'ok'
        $script:GrokErrMsg | Should -Not -Match 'still-good|refresh-value|lock timeout'
    }
}

Describe 'Grok usage carry-forward' {
    It 'keeps the last weekly reset when a poll is only stale' {
        $previous = @{ WeekPct = 21; WeekResetsAt = '2026-09-28T13:14:09Z' }
        $kept = Resolve-GrokUsageCarryForward -Previous $previous -Incoming $null -AuthState 'stale'
        $kept.WeekResetsAt | Should -Be '2026-09-28T13:14:09Z'
    }

    It 'drops the last reading when the session is logged out' {
        $previous = @{ WeekPct = 21; WeekResetsAt = '2026-09-28T13:14:09Z' }
        Resolve-GrokUsageCarryForward -Previous $previous -Incoming $null -AuthState 'auth' | Should -BeNullOrEmpty
        Resolve-GrokUsageCarryForward -Previous $previous -Incoming $null -AuthState 'notoken' | Should -BeNullOrEmpty
    }

    It 'uses a fresh reading when one arrives' {
        $previous = @{ WeekPct = 21; WeekResetsAt = '2026-09-28T13:14:09Z' }
        $incoming = @{ WeekPct = 22; WeekResetsAt = '2026-09-28T13:14:09Z' }
        (Resolve-GrokUsageCarryForward -Previous $previous -Incoming $incoming -AuthState 'ok').WeekPct | Should -Be 22
    }
}

