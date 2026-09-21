#Requires -Module Pester
# CodexIncremental.Tests.ps1 - Codex session logs are append-only JSONL and a
# long-lived session keeps growing (one real session passed 535 MB). Get-CodexStats
# used to re-read every changed file whole on every poll, so a session that was
# still being written cost its full size each time. That blew the 60-second poll
# ceiling, the reaper killed the job before it could save its cache, and Codex
# went blank for good. These tests pin the resumable parse: only appended bytes
# are read, and resuming gives exactly what one full parse would.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    $script:ErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'overlay-test-errors.log'
    . (Join-Path $root 'src\Config.ps1')
    function Get-WslHomeRoots { return @() }
    $script:CodexPrices = @{
        'gpt-5.5' = @{ in = 5.00; cachedIn = 0.50; out = 30.00 }
        default   = @{ in = 1.00; cachedIn = 0.10; out = 2.00 }
    }
    . (Join-Path $root 'src\CodexData.ps1')
    # Hermetic: the live quota call is not what these tests are about.
    function Get-CodexLiveUsage { return $null }

    $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    function New-Ts([datetime]$LocalTime) {
        $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($LocalTime)
        return ([System.DateTimeOffset]::new($LocalTime, $offset)).ToString('o')
    }

    function ConvertTo-Line($Object) { return ($Object | ConvertTo-Json -Depth 10 -Compress) }

    function New-MetaLine([string]$Ts, [string]$Id) {
        ConvertTo-Line @{ timestamp = $Ts; type = 'session_meta'; payload = @{ session_id = $Id; timestamp = $Ts } }
    }
    function New-ModelLine([string]$Ts, [string]$Model) {
        ConvertTo-Line @{ timestamp = $Ts; type = 'turn_context'; payload = @{ model = $Model } }
    }
    function New-UserLine([string]$Ts, [string]$Text = 'hello') {
        ConvertTo-Line @{ timestamp = $Ts; type = 'event_msg'; payload = @{ type = 'user_message'; message = $Text } }
    }
    function New-TokenLine([string]$Ts, [long]$In, [long]$Cached, [long]$Out, $Limits = $null) {
        $payload = @{
            type = 'token_count'
            info = @{ total_token_usage = @{ input_tokens = $In; cached_input_tokens = $Cached; output_tokens = $Out } }
        }
        if ($Limits) { $payload.rate_limits = $Limits }
        ConvertTo-Line @{ timestamp = $Ts; type = 'event_msg'; payload = $payload }
    }
    # The bulk of a real session: large payloads the stats never look at.
    function New-NoiseLine([string]$Ts, [int]$Size = 400) {
        ConvertTo-Line @{ timestamp = $Ts; type = 'response_item'; payload = @{ type = 'message'; content = ('x' * $Size) } }
    }

    function Write-SessionLines {
        param([string]$Path, [string[]]$Lines, [switch]$Append, [switch]$NoTrailingNewline)
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $text = ($Lines -join "`n")
        if (-not $NoTrailingNewline) { $text += "`n" }
        if ($Append) { [System.IO.File]::AppendAllText($Path, $text, $script:Utf8NoBom) }
        else { [System.IO.File]::WriteAllText($Path, $text, $script:Utf8NoBom) }
    }

    # Every stat field except the wall-clock stamp, so a mismatch anywhere shows.
    function Get-StatsFingerprint {
        $s = $script:CodexStats
        if (-not $s) { return '<null>' }
        $keys = @($s.Keys | Where-Object { $_ -ne 'LastComputed' } | Sort-Object)
        return (($keys | ForEach-Object { '{0}={1}' -f $_, $s[$_] }) -join '; ')
    }

    # Fresh process per poll in the real app: drop the in-memory cache so the
    # next run has to load the one on disk, exactly like production.
    function Invoke-FreshPoll {
        $script:CodexStatsFileCache = @{}
        $script:CodexStats = $null
        Get-CodexStats
        return Get-StatsFingerprint
    }

    function Reset-CodexSandbox {
        $script:AppDir = $TestDrive
        Remove-Item (Join-Path $TestDrive 'codex-cache.json') -ErrorAction SilentlyContinue
        $script:CodexSessionsDir = Join-Path $TestDrive 'sessions'
        if (Test-Path $script:CodexSessionsDir) { Remove-Item $script:CodexSessionsDir -Recurse -Force }
        New-Item -ItemType Directory -Path $script:CodexSessionsDir -Force | Out-Null
        $script:CodexStatsFileCache = @{}
        $script:CodexStats = $null
        $script:CodexBytesRead = 0L
    }
}

Describe 'Read-CodexNewLines' {
    BeforeEach { $script:File = Join-Path $TestDrive 'lines.jsonl' }

    It 'returns every complete line and an offset at end of file' {
        Write-SessionLines $script:File @('{"a":1}', '{"b":2}')
        $r = Read-CodexNewLines -Path $script:File -Offset 0
        $r.Lines | Should -Be @('{"a":1}', '{"b":2}')
        $r.NextOffset | Should -Be (Get-Item $script:File).Length
    }

    It 'does not consume a trailing line that is still being written' {
        Write-SessionLines $script:File @('{"a":1}', '{"b":') -NoTrailingNewline
        $r = Read-CodexNewLines -Path $script:File -Offset 0
        $r.Lines | Should -Be @('{"a":1}')
        $r.NextOffset | Should -Be 8
    }

    It 'resumes from an offset and returns only what was appended' {
        Write-SessionLines $script:File @('{"a":1}')
        $first = Read-CodexNewLines -Path $script:File -Offset 0
        Write-SessionLines $script:File @('{"b":2}', '{"c":3}') -Append
        $next = Read-CodexNewLines -Path $script:File -Offset $first.NextOffset
        $next.Lines | Should -Be @('{"b":2}', '{"c":3}')
        $next.BytesRead | Should -Be 16
    }

    It 'returns nothing when no complete line has been appended' {
        Write-SessionLines $script:File @('{"a":1}')
        $first = Read-CodexNewLines -Path $script:File -Offset 0
        $again = Read-CodexNewLines -Path $script:File -Offset $first.NextOffset
        @($again.Lines).Count | Should -Be 0
        $again.NextOffset | Should -Be $first.NextOffset
    }

    It 'strips a UTF-8 byte-order mark at the start of the file' {
        # Windows PowerShell 5.1's Set-Content -Encoding UTF8 writes one.
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $body = [System.Text.Encoding]::UTF8.GetBytes("{`"a`":1}`n")
        [System.IO.File]::WriteAllBytes($script:File, [byte[]]($bom + $body))
        $r = Read-CodexNewLines -Path $script:File -Offset 0
        $r.Lines | Should -Be @('{"a":1}')
        ($r.Lines[0] | ConvertFrom-Json).a | Should -Be 1
    }

    It 'handles CRLF line endings' {
        [System.IO.File]::WriteAllText($script:File, "{`"a`":1}`r`n{`"b`":2}`r`n", $script:Utf8NoBom)
        $r = Read-CodexNewLines -Path $script:File -Offset 0
        $r.Lines | Should -Be @('{"a":1}', '{"b":2}')
    }

    It 'reassembles lines that straddle a read-chunk boundary' {
        $lines = 1..40 | ForEach-Object { '{"n":' + $_ + ',"pad":"' + ('p' * ($_ % 7)) + '"}' }
        Write-SessionLines $script:File $lines
        $r = Read-CodexNewLines -Path $script:File -Offset 0 -ChunkBytes 7
        $r.Lines | Should -Be $lines
    }

    It 'decodes multi-byte UTF-8 split across a chunk boundary' {
        $line = '{"t":"caf' + [char]0x00E9 + ' ' + [char]0x2713 + '"}'
        Write-SessionLines $script:File @($line, $line)
        $r = Read-CodexNewLines -Path $script:File -Offset 0 -ChunkBytes 3
        $r.Lines | Should -Be @($line, $line)
    }

    It 'reads a file that Codex still holds open for writing' {
        Write-SessionLines $script:File @('{"a":1}')
        $writer = [System.IO.File]::Open($script:File, 'Open', 'Write', 'ReadWrite')
        try {
            $r = Read-CodexNewLines -Path $script:File -Offset 0
            $r.Lines | Should -Be @('{"a":1}')
        } finally {
            $writer.Dispose()
        }
    }
}

Describe 'Convert-CodexCacheDate' {
    # Windows PowerShell 5.1 writes a [datetime] as \/Date(ms)\/ and reads it back
    # as UTC, so a cached 09:03 local returned as 13:03 UTC. DateTime compares
    # ticks, not kind, which skewed Today, after-hours, the current model and
    # which file's rate limits counted as latest.
    It 'returns a UTC value as local time, like Convert-CodexTimestamp does' {
        $local = [datetime]::new(2026, 6, 10, 9, 3, 0, [System.DateTimeKind]::Local)
        $utc = $local.ToUniversalTime()
        $utc.Kind | Should -Be ([System.DateTimeKind]::Utc)

        $back = Convert-CodexCacheDate $utc
        $back.Kind | Should -Be ([System.DateTimeKind]::Local)
        $back      | Should -Be $local
    }

    It 'leaves a local value alone' {
        $local = [datetime]::new(2026, 6, 10, 9, 3, 0, [System.DateTimeKind]::Local)
        (Convert-CodexCacheDate $local) | Should -Be $local
    }

    It 'survives a real cache round-trip in this shell' {
        $local = [System.DateTimeOffset]::Parse('2026-06-10T09:03:00-04:00').LocalDateTime
        $back = (@{ D = $local } | ConvertTo-Json | ConvertFrom-Json).D
        (Convert-CodexCacheDate $back) | Should -Be $local
    }
}

Describe 'Test-CodexLineRelevant' {
    It 'keeps the four line kinds the stats read' {
        Test-CodexLineRelevant (New-MetaLine 't' 's1')         | Should -BeTrue
        Test-CodexLineRelevant (New-ModelLine 't' 'gpt-5.5')   | Should -BeTrue
        Test-CodexLineRelevant (New-UserLine 't')              | Should -BeTrue
        Test-CodexLineRelevant (New-TokenLine 't' 1 0 1)       | Should -BeTrue
        Test-CodexLineRelevant '{"type":"token_count","payload":{}}' | Should -BeTrue
    }

    It 'skips the bulk payload lines without parsing them' {
        Test-CodexLineRelevant (New-NoiseLine 't') | Should -BeFalse
        Test-CodexLineRelevant '{"type":"response_item","payload":{"type":"reasoning"}}' | Should -BeFalse
    }

    It 'lets a line through when it merely mentions a kind; the type check still decides' {
        # A superset is safe: a false positive is parsed and ignored as before.
        Test-CodexLineRelevant '{"type":"response_item","payload":{"text":"about token_count"}}' | Should -BeTrue
    }
}

Describe 'Get-CodexStats resumable parse' {
    BeforeEach {
        Reset-CodexSandbox
        $script:OriginalCodexEnvironment = @{}
        foreach ($name in @('CODEX_HOME', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA')) {
            $script:OriginalCodexEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            [System.Environment]::SetEnvironmentVariable($name, $TestDrive, 'Process')
        }
        $script:Session = Join-Path $script:CodexSessionsDir '2026\06\10\rollout-live.jsonl'
        $script:Base = (Get-Date).Date.AddHours(9)
        $script:Limits = @{
            primary   = @{ used_percent = 12; window_minutes = 300;   resets_at = 1783651392 }
            secondary = @{ used_percent = 40; window_minutes = 10080; resets_at = 1784238192 }
        }
        # A session that switches model mid-way, with noise between the events.
        $b = $script:Base
        $script:Head = @(
            (New-MetaLine  (New-Ts $b) 'live-1')
            (New-ModelLine (New-Ts $b.AddMinutes(1)) 'gpt-5.5')
            (New-UserLine  (New-Ts $b.AddMinutes(2)) 'first')
            (New-NoiseLine (New-Ts $b.AddMinutes(2)))
            (New-TokenLine (New-Ts $b.AddMinutes(3)) 1000 100 200)
            (New-NoiseLine (New-Ts $b.AddMinutes(3)))
            (New-TokenLine (New-Ts $b.AddMinutes(4)) 3000 400 500)
        )
        $script:Tail = @(
            (New-ModelLine (New-Ts $b.AddMinutes(5)) 'other-model')
            (New-UserLine  (New-Ts $b.AddMinutes(6)) 'second')
            (New-NoiseLine (New-Ts $b.AddMinutes(6)))
            (New-TokenLine (New-Ts $b.AddMinutes(7)) 7000 900 1100 $script:Limits)
        )
    }

    AfterEach {
        foreach ($name in $script:OriginalCodexEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:OriginalCodexEnvironment[$name], 'Process')
        }
    }

    It 'resuming after an append gives exactly the stats of one full parse' {
        Write-SessionLines $script:Session ($script:Head + $script:Tail)
        $full = Invoke-FreshPoll

        Reset-CodexSandbox
        Write-SessionLines $script:Session $script:Head
        $null = Invoke-FreshPoll
        Write-SessionLines $script:Session $script:Tail -Append
        $resumed = Invoke-FreshPoll

        $resumed | Should -Be $full
    }

    It 'does not double-count cumulative token counters across the resume point' {
        Write-SessionLines $script:Session $script:Head
        $null = Invoke-FreshPoll
        Write-SessionLines $script:Session $script:Tail -Append
        $null = Invoke-FreshPoll
        # Cumulative snapshots: the last one is the session total.
        $script:CodexStats.InTokens  | Should -Be 7000
        $script:CodexStats.OutTokens | Should -Be 1100
        $script:CodexStats.Messages  | Should -Be 2
        $script:CodexStats.Sessions  | Should -Be 1
    }

    It 'reads only the appended bytes on the next poll, not the whole file' {
        # A large head stands in for a long-lived session.
        $big = 1..400 | ForEach-Object { New-NoiseLine (New-Ts $script:Base) 2000 }
        Write-SessionLines $script:Session ($script:Head + $big)
        $null = Invoke-FreshPoll
        $fileSize = (Get-Item $script:Session).Length

        $appended = [System.Text.Encoding]::UTF8.GetByteCount((($script:Tail -join "`n") + "`n"))
        Write-SessionLines $script:Session $script:Tail -Append
        $script:CodexBytesRead = 0L
        $null = Invoke-FreshPoll

        # Lower bound too, or an implementation that never counts would pass.
        $script:CodexBytesRead | Should -BeGreaterOrEqual $appended
        $script:CodexBytesRead | Should -BeLessOrEqual ($appended + 8192)
        $script:CodexBytesRead | Should -BeLessThan ($fileSize / 10)
        $script:CodexStats.InTokens | Should -Be 7000
    }

    It 'counts a half-written trailing line once it is completed, and only once' {
        $last = New-TokenLine (New-Ts $script:Base.AddMinutes(8)) 9000 1000 1500
        $cut = [int]($last.Length / 2)
        Write-SessionLines $script:Session ($script:Head + $script:Tail)
        [System.IO.File]::AppendAllText($script:Session, $last.Substring(0, $cut), $script:Utf8NoBom)
        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens | Should -Be 7000

        [System.IO.File]::AppendAllText($script:Session, $last.Substring($cut) + "`n", $script:Utf8NoBom)
        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens | Should -Be 9000

        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens | Should -Be 9000
    }

    It 'falls back to a full re-parse when a file is replaced rather than appended' {
        Write-SessionLines $script:Session ($script:Head + $script:Tail)
        $null = Invoke-FreshPoll

        # Same path, different history, longer than before: a naive offset resume
        # would splice two sessions together.
        $b = $script:Base
        $replacement = @(
            (New-MetaLine  (New-Ts $b) 'replaced')
            (New-ModelLine (New-Ts $b.AddMinutes(1)) 'gpt-5.5')
            (New-NoiseLine (New-Ts $b.AddMinutes(1)) 4000)
            (New-TokenLine (New-Ts $b.AddMinutes(2)) 50 5 10)
        )
        Write-SessionLines $script:Session $replacement
        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens  | Should -Be 50
        $script:CodexStats.OutTokens | Should -Be 10
    }

    It 'falls back to a full re-parse when a file shrinks' {
        Write-SessionLines $script:Session ($script:Head + $script:Tail)
        $null = Invoke-FreshPoll
        Write-SessionLines $script:Session $script:Head
        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens | Should -Be 3000
    }

    It 'discards cache entries from an older cache version' {
        Write-SessionLines $script:Session ($script:Head + $script:Tail)
        $stale = @{}
        $stale[$script:Session] = @{
            CacheVersion = 3
            Stamp        = "$((Get-Item $script:Session).LastWriteTimeUtc.Ticks):$((Get-Item $script:Session).Length)"
            Records      = @(@{ Model = 'x'; Date = (Get-Date); In = 999999; CachedIn = 0; Out = 999999; SessionId = 'bogus'; MessageDates = @() })
        }
        $stale | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $TestDrive 'codex-cache.json') -Encoding UTF8
        $null = Invoke-FreshPoll
        $script:CodexStats.InTokens | Should -Be 7000
    }

    It 'catches up over several polls when a cold parse exceeds the time budget' {
        # A cold parse (first run after an upgrade, or a replaced file) of a
        # huge session can outlast the 60-second poll ceiling. Each poll must
        # bank its progress so the next one continues, instead of starting over.
        $big = 1..300 | ForEach-Object { New-NoiseLine (New-Ts $script:Base) 2000 }
        Write-SessionLines $script:Session ($script:Head + $big + $script:Tail)
        $full = Invoke-FreshPoll

        Reset-CodexSandbox
        Write-SessionLines $script:Session ($script:Head + $big + $script:Tail)
        $script:CodexParseBudgetSeconds = 0
        $script:CodexSliceBytes = 65536
        try {
            $polls = 0
            do {
                $polls++
                $result = Invoke-FreshPoll
            } while ($result -eq '<null>' -and $polls -lt 50)
        } finally {
            $script:CodexParseBudgetSeconds = 35
            $script:CodexSliceBytes = 67108864
        }

        $polls | Should -BeGreaterThan 1
        $result | Should -Be $full
    }

    It 'does not publish partial stats while it is still catching up' {
        $big = 1..300 | ForEach-Object { New-NoiseLine (New-Ts $script:Base) 2000 }
        Write-SessionLines $script:Session ($script:Head + $big + $script:Tail)
        $script:CodexParseBudgetSeconds = 0
        $script:CodexSliceBytes = 65536
        try {
            $first = Invoke-FreshPoll
        } finally {
            $script:CodexParseBudgetSeconds = 35
            $script:CodexSliceBytes = 67108864
        }
        $first | Should -Be '<null>'
    }

    It 'keeps other files cached when a poll stops early' {
        # Sorts after the live session, so it is still unvisited when the poll
        # stops early inside the live one - the case that must not drop it.
        $other = Join-Path $script:CodexSessionsDir '2026\06\11\rollout-done.jsonl'
        Write-SessionLines $other @(
            (New-MetaLine  (New-Ts $script:Base.AddDays(-1)) 'done-1')
            (New-TokenLine (New-Ts $script:Base.AddDays(-1).AddMinutes(1)) 500 0 50)
        )
        $null = Invoke-FreshPoll

        $big = 1..300 | ForEach-Object { New-NoiseLine (New-Ts $script:Base) 2000 }
        Write-SessionLines $script:Session ($script:Head + $big + $script:Tail)
        $script:CodexParseBudgetSeconds = 0
        $script:CodexSliceBytes = 65536
        try {
            $null = Invoke-FreshPoll
        } finally {
            $script:CodexParseBudgetSeconds = 35
            $script:CodexSliceBytes = 67108864
        }

        $saved = Get-Content (Join-Path $TestDrive 'codex-cache.json') -Raw | ConvertFrom-Json
        $saved.PSObject.Properties.Name | Should -Contain $other
    }

    It 'keeps the latest rate limits across a resume' {
        Write-SessionLines $script:Session $script:Head
        $null = Invoke-FreshPoll
        Write-SessionLines $script:Session $script:Tail -Append
        $null = Invoke-FreshPoll
        $script:CodexStats.WeekPct | Should -Be 40
    }
}
