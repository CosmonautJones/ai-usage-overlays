#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    $script:ErrLog = Join-Path $TestDrive 'overlay-test-errors.log'
    $script:CredPath = Join-Path $TestDrive '.credentials.json'
    . (Join-Path $root 'src\Config.ps1')
    function Get-WslHomeRoots { return @() }
    . (Join-Path $root 'src\Data.ps1')
}

Describe 'ConvertTo-ClaudeIdentity' {
    It 'extracts email and organization from the OAuth profile payload' {
        $profile = [pscustomobject]@{
            account = [pscustomobject]@{ email = 'dev@example.test' }
            organization = [pscustomobject]@{
                uuid = 'org-123'
                name = 'Example Org'
            }
        }

        $identity = ConvertTo-ClaudeIdentity $profile

        $identity.Email | Should -Be 'dev@example.test'
        $identity.Organization | Should -Be 'Example Org'
        $identity.OrganizationId | Should -Be 'org-123'
        $identity.Display | Should -Be 'dev@example.test / Example Org'
    }

    It 'returns null when the profile has no usable identity fields' {
        ConvertTo-ClaudeIdentity ([pscustomobject]@{}) | Should -BeNullOrEmpty
    }
}

Describe 'Select-ClaudeCredential' {
    It 'prefers an unexpired credential over an expired credential' {
        $expiredPath = Join-Path $TestDrive 'expired-credentials.json'
        $validPath = Join-Path $TestDrive 'valid-credentials.json'
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
        $validAt = [System.DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeMilliseconds()

        @{ claudeAiOauth = @{ accessToken = 'expired-token'; expiresAt = $expiredAt } } |
            ConvertTo-Json -Depth 3 |
            Set-Content -Path $expiredPath -Encoding UTF8
        @{ claudeAiOauth = @{ accessToken = 'valid-token'; expiresAt = $validAt } } |
            ConvertTo-Json -Depth 3 |
            Set-Content -Path $validPath -Encoding UTF8

        Select-ClaudeCredential @($expiredPath, $validPath) | Should -Be 'valid-token'
    }

    It 'uses the newest credential file when every token is expired' {
        $olderPath = Join-Path $TestDrive 'older-expired-credentials.json'
        $newerPath = Join-Path $TestDrive 'newer-expired-credentials.json'
        $expiredAt = [System.DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()

        @{ claudeAiOauth = @{ accessToken = 'older-token'; expiresAt = $expiredAt } } |
            ConvertTo-Json -Depth 3 |
            Set-Content -Path $olderPath -Encoding UTF8
        @{ claudeAiOauth = @{ accessToken = 'newer-token'; expiresAt = $expiredAt } } |
            ConvertTo-Json -Depth 3 |
            Set-Content -Path $newerPath -Encoding UTF8

        (Get-Item $olderPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-2)
        (Get-Item $newerPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-1)

        Select-ClaudeCredential @($olderPath, $newerPath) | Should -Be 'newer-token'
    }
}

Describe 'Get-Usage Claude profile behavior' {
    BeforeEach {
        # Isolate every persisted file (creds, backoff, profile cache) per test.
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:CredPath = Join-Path $script:AppDir '.credentials.json'
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-123"}}'
        $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
        $script:ClaudeIdentity = $null
        function Add-HistorySample { param($data) }
        function Save-History { }

        # Defined here (not in the Describe body) so they exist at run time under
        # Pester 5's discovery/run split.
        $script:usageOk = {
            [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 10; resets_at = '2026-07-06T18:00:00Z' }
                seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                limits = @()
            }
        }
        $script:profileOk = {
            [pscustomobject]@{
                account = [pscustomobject]@{ email = 'dev@example.test' }
                organization = [pscustomobject]@{ name = 'Example Org'; uuid = 'org-123' }
            }
        }
    }

    It 'stores Claude identity when usage and profile fetches succeed' {
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod $script:profileOk -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
        $script:ClaudeIdentity.Display | Should -Be 'dev@example.test / Example Org'
    }

    It 'keeps usage data when the profile fetch fails' {
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { throw 'profile down' } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
        $script:State.Data | Should -Not -BeNullOrEmpty
        $script:ClaudeIdentity | Should -BeNullOrEmpty
    }

    It 'hits the profile endpoint at most once per token across repeated polls' {
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod $script:profileOk -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage
        Get-Usage
        Get-Usage

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*oauth/profile' }
        $script:ClaudeIdentity.Display | Should -Be 'dev@example.test / Example Org'
    }

    It 'does not retry a profile fetch that already failed for the same token' {
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { throw 'profile down' } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage
        Get-Usage

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*oauth/profile' }
    }

    It 'refetches the profile after the token rotates' {
        Mock Invoke-RestMethod $script:usageOk -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod $script:profileOk -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-999"}}'
        Get-Usage

        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/profile' }
    }
    It 'falls back after a preferred credential returns 401 and persists only its path' {
        $preferredPath = Join-Path $TestDrive 'preferred-credentials.json'
        Set-Content -Path $preferredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"preferred-token"}}'
        Save-PreferredClaudeCredentialPath $preferredPath

        Mock Invoke-RestMethod {
            if ($Headers.Authorization -eq 'Bearer preferred-token') {
                $ex = [System.Exception]::new('401 Unauthorized')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
                throw $ex
            }
            & $script:usageOk
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod $script:profileOk -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'ok'
        $saved = Get-Content (Get-ClaudeCredentialPreferencePath) -Raw
        $saved | Should -Match [regex]::Escape($script:CredPath)
        $saved | Should -Not -Match 'token-123'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*oauth/usage' }
    }
}


Describe 'Get-Usage failure backoff' {
    BeforeEach {
        $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:CredPath = Join-Path $script:AppDir '.credentials.json'
        Set-Content -Path $script:CredPath -Encoding UTF8 -Value '{"claudeAiOauth":{"accessToken":"token-123"}}'
        $script:State = @{ Data = $null; Status = 'init'; LastFetch = ''; Message = '' }
        $script:ClaudeIdentity = $null
        function Add-HistorySample { param($data) }
        function Save-History { }
    }

    It 'backs off on a 401 and skips the profile call' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('401 Unauthorized')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
            throw $ex
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { throw 'should not be called' } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage

        $script:State.Status | Should -Be 'auth'
        $script:State.Message | Should -Be 'Auth expired'
        (Get-ClaudeBackoffState).Until | Should -BeGreaterThan (Get-Date)
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*oauth/profile' }
    }

    It 'early-returns while an auth backoff is active and replays its cause' {
        Set-ClaudeBackoffUntil -BackoffUntil (Get-Date).AddMinutes(10) -FailureCount 1 -Status 'auth' -Message 'Auth expired'
        Mock Invoke-RestMethod { throw 'network must not be touched' }

        Get-Usage

        $script:State.Status | Should -Be 'auth'
        $script:State.Message | Should -Be 'Auth expired'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'clears the backoff on a successful fetch' {
        Set-ClaudeBackoffUntil -BackoffUntil (Get-Date).AddMinutes(10) -FailureCount 3 -Status 'auth' -Message 'Auth expired'
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 10; resets_at = '2026-07-06T18:00:00Z' }
                seven_day = [pscustomobject]@{ utilization = 20; resets_at = '2026-07-13T18:00:00Z' }
                limits = @()
            }
        } -ParameterFilter { $Uri -like '*oauth/usage' }
        Mock Invoke-RestMethod { [pscustomobject]@{ account = [pscustomobject]@{ email = 'x@y.z' } } } -ParameterFilter { $Uri -like '*oauth/profile' }

        Get-Usage -Force

        $script:State.Status | Should -Be 'ok'
        Get-ClaudeBackoffState | Should -BeNullOrEmpty
    }
}

Describe 'Register-ClaudeFailure escalation' {
    BeforeEach { $script:AppDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

    It 'escalates the delay as consecutive failures accrue' {
        $now = Get-Date
        $first = Register-ClaudeFailure -Status 'stale' -Message 'x' -MinSeconds 60
        $second = Register-ClaudeFailure -Status 'stale' -Message 'x' -MinSeconds 60
        $third = Register-ClaudeFailure -Status 'stale' -Message 'x' -MinSeconds 60

        (Get-ClaudeBackoffState).FailureCount | Should -Be 3
        ($second - $now).TotalSeconds | Should -BeGreaterThan ($first - $now).TotalSeconds
        ($third - $now).TotalSeconds | Should -BeGreaterThan ($second - $now).TotalSeconds
    }

    It 'honors a server Retry-After over the exponential default' {
        $retryAt = (Get-Date).AddHours(1)
        $until = Register-ClaudeFailure -Status 'stale' -Message '' -RetryAfter $retryAt -MinSeconds 900

        [math]::Abs(($until - $retryAt).TotalSeconds) | Should -BeLessThan 2
    }

    It 'caps the exponential delay at thirty minutes' {
        $now = Get-Date
        $until = $now
        1..10 | ForEach-Object { $until = Register-ClaudeFailure -Status 'stale' -Message 'x' -MinSeconds 60 }

        ($until - $now).TotalSeconds | Should -BeLessOrEqual 1801
    }
}

Describe 'Claude rate-limit backoff helpers' {
    BeforeEach {
        $script:AppDir = $TestDrive
    }

    It 'persists and reloads the Claude backoff timestamp' {
        $until = (Get-Date).AddMinutes(12)

        Set-ClaudeBackoffUntil $until
        $loaded = Get-ClaudeBackoffUntil

        $loaded | Should -Not -BeNullOrEmpty
        [math]::Abs(($loaded - $until).TotalSeconds) | Should -BeLessThan 2
    }

    It 'parses Retry-After seconds with a one-minute floor' {
        $before = Get-Date

        $retryAt = ConvertFrom-RetryAfter '15'

        ($retryAt - $before).TotalSeconds | Should -BeGreaterOrEqual 59
    }

    It 'clears persisted Claude backoff state' {
        Set-ClaudeBackoffUntil (Get-Date).AddMinutes(10)

        Clear-ClaudeBackoff

        Get-ClaudeBackoffUntil | Should -BeNullOrEmpty
    }
}
