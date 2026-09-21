#Requires -Module Pester
#
# The overlay showed "Auth expired" while still drawing Claude bars that looked
# live: the live 5h window was 8% while the HUD read 32% next to a reset time
# that had already passed. Four defects kept it there - a backoff that outlived
# the token that earned it, one failure counter shared across unrelated failure
# kinds, no local expiry check, and carried-forward data with nothing marking it.
# These cover the three data-layer ones; ClaudeStale.Tests.ps1 covers the fourth.
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    $script:ErrLog = Join-Path $TestDrive 'overlay-test-errors.log'
    $script:CredPath = Join-Path $TestDrive '.credentials.json'
    . (Join-Path $root 'src\Config.ps1')
    function Get-WslHomeRoots { return @() }
    . (Join-Path $root 'src\Data.ps1')
}

Describe 'Test-ClaudeBackoffActive' {
    It 'honours an unexpired backoff recorded against the token still on disk' {
        $hash = Get-ClaudeTokenHash 'token-abc'
        $backoff = @{ Until = (Get-Date).AddMinutes(20); FailureCount = 3; Status = 'auth'; Message = 'Auth expired'; TokenHash = $hash }

        Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash $hash | Should -BeTrue
    }

    It 'releases the backoff as soon as the token on disk changes' {
        $backoff = @{ Until = (Get-Date).AddMinutes(20); FailureCount = 3; Status = 'auth'; Message = 'Auth expired'; TokenHash = (Get-ClaudeTokenHash 'token-old') }

        Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash (Get-ClaudeTokenHash 'token-new') | Should -BeFalse
    }

    It 'honours a legacy backoff that recorded no token hash' {
        $backoff = @{ Until = (Get-Date).AddMinutes(20); FailureCount = 3; Status = 'stale'; Message = 'boom'; TokenHash = '' }

        Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash (Get-ClaudeTokenHash 'token-new') | Should -BeTrue
    }

    It 'honours the backoff when no token could be read from disk' {
        $backoff = @{ Until = (Get-Date).AddMinutes(20); FailureCount = 3; Status = 'auth'; Message = 'Auth expired'; TokenHash = (Get-ClaudeTokenHash 'token-old') }

        Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash '' | Should -BeTrue
    }

    It 'ignores a backoff whose deadline has passed' {
        $hash = Get-ClaudeTokenHash 'token-abc'
        $backoff = @{ Until = (Get-Date).AddMinutes(-1); FailureCount = 3; Status = 'auth'; Message = 'Auth expired'; TokenHash = $hash }

        Test-ClaudeBackoffActive -Backoff $backoff -CurrentTokenHash $hash | Should -BeFalse
    }

    It 'ignores missing or dateless backoff state' {
        Test-ClaudeBackoffActive -Backoff $null -CurrentTokenHash 'abc' | Should -BeFalse
        Test-ClaudeBackoffActive -Backoff @{ Until = $null; FailureCount = 1 } -CurrentTokenHash 'abc' | Should -BeFalse
    }
}

Describe 'Get-ClaudeFailureCount' {
    It 'escalates while the failure kind stays the same' {
        Get-ClaudeFailureCount -Previous @{ FailureCount = 4; Status = 'stale' } -Status 'stale' | Should -Be 5
    }

    It 'restarts the count when the failure kind changes' {
        # The reported lockout: 14 network failures had already driven the count
        # to the 30-minute cap, so the FIRST auth failure inherited failure #16.
        Get-ClaudeFailureCount -Previous @{ FailureCount = 15; Status = 'stale' } -Status 'auth' | Should -Be 1
    }

    It 'starts at one with no previous state' {
        Get-ClaudeFailureCount -Previous $null -Status 'auth' | Should -Be 1
        Get-ClaudeFailureCount -Previous @{ FailureCount = 0; Status = 'auth' } -Status 'auth' | Should -Be 1
    }
}

Describe 'Test-ClaudeCredentialsExpired' {
    BeforeEach { $script:nowMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

    It 'reports expired only when every candidate expiry has passed' {
        Test-ClaudeCredentialsExpired -ExpiresAtUnixMs @(($script:nowMs - 1000), ($script:nowMs - 5000)) -NowUnixMs $script:nowMs |
            Should -BeTrue
    }

    It 'reports usable while any candidate is still valid' {
        Test-ClaudeCredentialsExpired -ExpiresAtUnixMs @(($script:nowMs - 1000), ($script:nowMs + 60000)) -NowUnixMs $script:nowMs |
            Should -BeFalse
    }

    It 'reports usable when an expiry is unknown' {
        Test-ClaudeCredentialsExpired -ExpiresAtUnixMs @(($script:nowMs - 1000), 0) -NowUnixMs $script:nowMs |
            Should -BeFalse
    }

    It 'reports usable when there are no candidates' {
        Test-ClaudeCredentialsExpired -ExpiresAtUnixMs @() -NowUnixMs $script:nowMs | Should -BeFalse
    }
}

Describe 'Get-ClaudeCredentialFingerprints' {
    BeforeEach {
        $script:probeDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:probeDir -Force | Out-Null
    }

    It 'returns a hash and expiry without ever surfacing the raw token' {
        $path = Join-Path $script:probeDir 'creds.json'
        $expiresAt = [System.DateTimeOffset]::UtcNow.AddHours(3).ToUnixTimeMilliseconds()
        Set-Content -Path $path -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"secret-token","expiresAt":{0}}}}}' -f $expiresAt)

        $fingerprints = @(Get-ClaudeCredentialFingerprints @($path))

        $fingerprints.Count | Should -Be 1
        $fingerprints[0].TokenHash | Should -Be (Get-ClaudeTokenHash 'secret-token')
        $fingerprints[0].ExpiresAt | Should -Be $expiresAt
        ($fingerprints | ConvertTo-Json -Depth 4) | Should -Not -Match 'secret-token'
    }

    It 'treats a credential without an expiry as unknown rather than expired' {
        $path = Join-Path $script:probeDir 'no-expiry.json'
        Set-Content -Path $path -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"secret-token"}}'

        @(Get-ClaudeCredentialFingerprints @($path))[0].ExpiresAt | Should -Be 0
    }

    It 'skips missing, unparsable and tokenless credential files' {
        $missing = Join-Path $script:probeDir 'missing.json'
        $garbage = Join-Path $script:probeDir 'garbage.json'
        $empty = Join-Path $script:probeDir 'empty.json'
        Set-Content -Path $garbage -Encoding UTF8 -Value 'not json at all'
        Set-Content -Path $empty -Encoding UTF8 -Value '{"claudeAiOauth":{}}'

        @(Get-ClaudeCredentialFingerprints @($missing, $garbage, $empty)).Count | Should -Be 0
    }

    It 'does not log the token from a half-written credentials file' {
        # Windows PowerShell's JSON errors quote the input they choked on.
        $script:ErrLog = Join-Path $script:probeDir 'errors.log'
        $truncated = Join-Path $script:probeDir 'truncated.json'
        Set-Content -Path $truncated -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"sk-half-written-secret'

        @(Get-ClaudeCredentialFingerprints @($truncated)).Count | Should -Be 0

        $log = ''
        if (Test-Path $script:ErrLog) { $log = Get-Content $script:ErrLog -Raw -Encoding UTF8 }
        $log | Should -Not -Match 'sk-half-written-secret'
    }
}

Describe 'Get-ClaudeCredentialSetHash' {
    BeforeAll {
        $script:hashA = Get-ClaudeTokenHash 'token-a'
        $script:hashB = Get-ClaudeTokenHash 'token-b'
    }

    It 'is the same whatever order the credentials are tried in' {
        Get-ClaudeCredentialSetHash @($script:hashA, $script:hashB) |
            Should -Be (Get-ClaudeCredentialSetHash @($script:hashB, $script:hashA))
    }

    It 'changes when any one credential changes' {
        Get-ClaudeCredentialSetHash @($script:hashA, $script:hashB) |
            Should -Not -Be (Get-ClaudeCredentialSetHash @($script:hashA, (Get-ClaudeTokenHash 'token-b2')))
    }

    It 'treats the same token at two paths as one member' {
        Get-ClaudeCredentialSetHash @($script:hashA, $script:hashA) |
            Should -Be (Get-ClaudeCredentialSetHash @($script:hashA))
    }

    It 'is empty when no credential could be read' {
        Get-ClaudeCredentialSetHash @() | Should -Be ''
    }
}

Describe 'Get-Usage token-aware backoff' {
    BeforeEach {
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:CredPath = Join-Path $script:AppDir '.credentials.json'
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-123"}}'
        $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
        $script:ClaudeIdentity = $null
        function Add-HistorySample { param($data) }
        function Save-History { }

        $script:usageOk = {
            [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 8; resets_at = '2026-07-06T18:00:00Z' }
                seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                limits = @()
            }
        }
    }

    It 'retries immediately once Claude Code has rotated the token' {
        Set-ClaudeBackoffUntil -BackoffUntil (Get-Date).AddMinutes(28) -FailureCount 16 -Status 'auth' -Message 'Auth expired' -TokenHash (Get-ClaudeCredentialSetHash @(Get-ClaudeTokenHash 'token-123'))
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-rotated"}}'
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { [pscustomobject]@{ account = [pscustomobject]@{ email = 'x@y.z' } } } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
        $script:State.Data.five_hour.utilization | Should -Be 8
        Get-ClaudeBackoffState | Should -BeNullOrEmpty
    }

    It 'still waits out the backoff while the same token is on disk' {
        Set-ClaudeBackoffUntil -BackoffUntil (Get-Date).AddMinutes(28) -FailureCount 16 -Status 'auth' -Message 'Auth expired' -TokenHash (Get-ClaudeCredentialSetHash @(Get-ClaudeTokenHash 'token-123'))
        Mock Invoke-RestMethod { throw 'network must not be touched' }

        Get-Usage

        $script:State.Status | Should -Be 'auth'
        $script:State.Message | Should -Be 'Auth expired'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'records the failing token hash on a 401 so a rotation can release it' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('401 Unauthorized')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
            throw $ex
        } -ParameterFilter { $Uri -like '*oauth/usage' }

        Get-Usage

        (Get-ClaudeBackoffState).TokenHash | Should -Be (Get-ClaudeCredentialSetHash @(Get-ClaudeTokenHash 'token-123'))
    }

    It 'leaves a 429 cooldown unkeyed so a rotation cannot walk over it' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('429 Too Many Requests')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429 })
            throw $ex
        } -ParameterFilter { $Uri -like '*oauth/usage' }

        Get-Usage

        (Get-ClaudeBackoffState).TokenHash | Should -BeNullOrEmpty
    }

    It 'never writes a raw token into the backoff file' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('401 Unauthorized')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
            throw $ex
        } -ParameterFilter { $Uri -like '*oauth/usage' }

        Get-Usage

        (Get-Content (Get-ClaudeBackoffPath) -Raw -Encoding UTF8) | Should -Not -Match 'token-123'
    }
}

Describe 'Get-Usage backoff across several credentials' {
    BeforeAll {
        function Set-TestCredential([string]$Path, [string]$Token, [long]$ExpiresAt = 0) {
            if ($ExpiresAt -eq 0) { $ExpiresAt = [System.DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds() }
            Set-Content -Path $Path -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"{0}","expiresAt":{1}}}}}' -f $Token, $ExpiresAt)
        }
    }

    BeforeEach {
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
        $script:ClaudeIdentity = $null

        # A Windows credential plus a WSL one; both are always candidates.
        $script:CredPath = Join-Path $script:AppDir '.credentials.json'
        $script:wslRoot = Join-Path $script:AppDir 'wsl-home'
        New-Item -ItemType Directory -Path (Join-Path $script:wslRoot '.claude') -Force | Out-Null
        $script:wslCred = Join-Path $script:wslRoot '.claude\.credentials.json'
        Mock Get-WslHomeRoots { @($script:wslRoot) }

        # Tokens in goodTokens get usage back; every other token gets a 401.
        $script:goodTokens = @()
        Mock Invoke-RestMethod {
            $token = $Headers.Authorization -replace '^Bearer ', ''
            if ($script:goodTokens -contains $token) {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 8; resets_at = '2026-07-06T18:00:00Z' }
                    seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                    limits = @()
                }
            }
            $ex = [System.Exception]::new('401 Unauthorized')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
            throw $ex
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { [pscustomobject]@{ account = [pscustomobject]@{ email = 'x@y.z' } } } -ParameterFilter { $Uri -like '*oauth/profile' }
    }

    It 'retries when a credential other than the preferred one rotates' {
        # A WSL token once succeeded, so it is preferred; it has since gone
        # stale, and the user re-authenticates Claude Code on Windows.
        Set-TestCredential $script:wslCred 'wsl-stale'
        Set-TestCredential $script:CredPath 'win-old'
        Save-PreferredClaudeCredentialPath $script:wslCred

        Get-Usage
        $script:State.Status | Should -Be 'auth'
        (Get-ClaudeBackoffState).Until | Should -BeGreaterThan (Get-Date)

        Set-TestCredential $script:CredPath 'win-new'
        $script:goodTokens = @('win-new')
        Get-Usage

        $script:State.Status | Should -Be 'ok'
        Get-ClaudeBackoffState | Should -BeNullOrEmpty
    }

    It 'holds the backoff when only the preference order changes' {
        Set-TestCredential $script:wslCred 'wsl-stale'
        Set-TestCredential $script:CredPath 'win-old'
        Save-PreferredClaudeCredentialPath $script:wslCred
        Get-Usage
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }

        Save-PreferredClaudeCredentialPath $script:CredPath
        Get-Usage

        $script:State.Status | Should -Be 'auth'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }
    }

    It 'holds the backoff when a sync rewrites an unchanged token' {
        # wsl-mirror recopies the WSL credential every 60s. A fresh write of the
        # same token - new mtime, different bytes - is not a rotation.
        $expiresAt = [System.DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds()
        Set-TestCredential $script:wslCred 'wsl-stale' $expiresAt
        Set-TestCredential $script:CredPath 'win-old'
        Get-Usage
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }

        Set-Content -Path $script:wslCred -Encoding UTF8 -Value ('{{ "claudeAiOauth": {{ "expiresAt": {0}, "accessToken": "wsl-stale" }} }}' -f $expiresAt)
        (Get-Item $script:wslCred).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
        Get-Usage

        $script:State.Status | Should -Be 'auth'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }
    }

    It 'releases an expiry lockout when any one credential is refreshed' {
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        Set-TestCredential $script:wslCred 'wsl-expired' $expiredAt
        Set-TestCredential $script:CredPath 'win-expired' $expiredAt
        Save-PreferredClaudeCredentialPath $script:wslCred

        Get-Usage
        $script:State.Message | Should -Be 'Token expired - open Claude Code to refresh'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }

        Set-TestCredential $script:CredPath 'win-fresh'
        $script:goodTokens = @('win-fresh')
        Get-Usage

        $script:State.Status | Should -Be 'ok'
    }
}

Describe 'Get-Usage local expiry pre-check' {
    BeforeEach {
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:CredPath = Join-Path $script:AppDir '.credentials.json'
        $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
        $script:ClaudeIdentity = $null
        function Add-HistorySample { param($data) }
        function Save-History { }
    }

    It 'does not spend a 401 on a token that has already expired' {
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"stale-token","expiresAt":{0}}}}}' -f $expiredAt)
        Mock Invoke-RestMethod { throw 'network must not be touched' }

        Get-Usage

        $script:State.Status | Should -Be 'auth'
        $script:State.Message | Should -Be 'Token expired - open Claude Code to refresh'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'keys the expiry cooldown to the expired token so a refresh releases it' {
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"stale-token","expiresAt":{0}}}}}' -f $expiredAt)
        Mock Invoke-RestMethod { throw 'network must not be touched' }

        Get-Usage
        $state = Get-ClaudeBackoffState
        $state.Until | Should -BeGreaterThan (Get-Date)
        $state.TokenHash | Should -Be (Get-ClaudeCredentialSetHash @(Get-ClaudeTokenHash 'stale-token'))

        $freshAt = [System.DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds()
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"fresh-token","expiresAt":{0}}}}}' -f $freshAt)
        Test-ClaudeBackoffActive -Backoff (Get-ClaudeBackoffState) -CurrentTokenHash (Get-ClaudeCredentialSetHash @(Get-ClaudeTokenHash 'fresh-token')) |
            Should -BeFalse
    }

    It 'gives the expiry lockout the short first-failure retry, not the escalated cap' {
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"stale-token","expiresAt":{0}}}}}' -f $expiredAt)
        Set-ClaudeBackoffUntil -BackoffUntil (Get-Date).AddMinutes(-1) -FailureCount 15 -Status 'stale' -Message 'No such host is known'
        Mock Invoke-RestMethod { throw 'network must not be touched' }

        Get-Usage

        $state = Get-ClaudeBackoffState
        $state.FailureCount | Should -Be 1
        ($state.Until - (Get-Date)).TotalSeconds | Should -BeLessOrEqual 61
    }

    It 'still calls the API when the credential carries no expiry' {
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-123"}}'
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 8; resets_at = '2026-07-06T18:00:00Z' }
                seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                limits = @()
            }
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { [pscustomobject]@{ account = [pscustomobject]@{ email = 'x@y.z' } } } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
    }

    It 'still calls the API when one candidate credential is expired and another is live' {
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        $freshAt = [System.DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds()
        $preferred = Join-Path $script:AppDir 'preferred.json'
        Set-Content -Path $preferred -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"expired-token","expiresAt":{0}}}}}' -f $expiredAt)
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value ('{{"claudeAiOauth":{{"accessToken":"live-token","expiresAt":{0}}}}}' -f $freshAt)
        Save-PreferredClaudeCredentialPath $preferred

        Mock Invoke-RestMethod {
            if ($Headers.Authorization -eq 'Bearer expired-token') {
                $ex = [System.Exception]::new('401 Unauthorized')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
                throw $ex
            }
            [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 8; resets_at = '2026-07-06T18:00:00Z' }
                seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                limits = @()
            }
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { [pscustomobject]@{ account = [pscustomobject]@{ email = 'x@y.z' } } } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
    }
}

Describe 'Register-ClaudeFailure across failure kinds' {
    BeforeEach {
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    }

    It 'gives the first auth failure a short retry after a run of network failures' {
        1..14 | ForEach-Object { [void](Register-ClaudeFailure -Status 'stale' -Message 'No such host is known' -MinSeconds 60) }
        (Get-ClaudeBackoffState).FailureCount | Should -Be 14

        $now = Get-Date
        $until = Register-ClaudeFailure -Status 'auth' -Message 'Auth expired' -MinSeconds 60

        (Get-ClaudeBackoffState).FailureCount | Should -Be 1
        ($until - $now).TotalSeconds | Should -BeLessOrEqual 61
    }

    It 'persists the token hash it was handed' {
        [void](Register-ClaudeFailure -Status 'auth' -Message 'Auth expired' -MinSeconds 60 -TokenHash 'deadbeef')

        (Get-ClaudeBackoffState).TokenHash | Should -Be 'deadbeef'
    }
}
