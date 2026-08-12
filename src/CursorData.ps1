$script:StateVscdb = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
$script:TrackingDb = Join-Path $env:USERPROFILE '.cursor\ai-tracking\ai-code-tracking.db'

$script:LiveData        = $null
$script:LocalData       = $null
$script:SummaryData     = $null
$script:AuthState       = 'init'
$script:CursorLastFetch = ''
$script:CursorErrMsg    = ''

function Fmt-Num([double]$n) {
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0}k'   -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}

# ---------------------------------------------------------------------------
# SQLite helper - reads Cursor's SQLite databases via bundled sqlite3.exe
# ---------------------------------------------------------------------------
# The bundled sqlite3.exe ships in the app ROOT ({app}\sqlite3.exe) while these
# modules install to {app}\src, so resolution must walk one level up. Relying on
# PATH instead is what used to break the Cursor section outright - see the
# PATH-hygiene note in unified-overlay.ps1.
function Resolve-Sqlite3Path {
    param([string]$BaseDir)

    if ($BaseDir) {
        $candidates = @((Join-Path $BaseDir 'sqlite3.exe'))
        $parent = Split-Path $BaseDir -Parent
        if ($parent) { $candidates += (Join-Path $parent 'sqlite3.exe') }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Sqlite {
    param([string]$DbPath, [string]$Query)
    $exe = Resolve-Sqlite3Path $PSScriptRoot
    if (-not $exe) { return $null }
    try {
        # sqlite3 -json may return output as a string array (one line per line);
        # join into a single string so ConvertFrom-Json can parse the full JSON.
        $lines = & $exe -readonly -json $DbPath $Query 2>$null
        if ($lines) { $lines -join '' } else { $null }
    } catch { $null }
}

# Windows PowerShell 5.1 silently drops a 'Cookie' entry passed through -Headers
# (its own CookieContainer wins), so every cursor.com call 401s. Carry the session
# cookie in a WebRequestSession instead - that path works on both 5.1 and 7+.
function New-CursorWebSession {
    param([string]$UserId, [string]$Token)
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $value   = [Uri]::EscapeDataString($UserId + '::' + $Token)
    $session.Cookies.Add((New-Object System.Net.Cookie('WorkosCursorSessionToken', $value, '/', 'cursor.com')))
    return $session
}

function Get-CursorToken {
    # Read accessToken and email from state.vscdb
    $raw = Invoke-Sqlite $script:StateVscdb "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/cachedEmail')"
    if (-not $raw) { return $null, $null, $null }
    $rows = $null
    try { $rows = $raw | ConvertFrom-Json } catch { return $null, $null, $null }
    if (-not $rows) { return $null, $null, $null }

    $tok    = $null
    $email  = $null
    $userId = $null

    foreach ($row in $rows) {
        if ($row.key -eq 'cursorAuth/accessToken') { $tok   = $row.value -replace '^"|"$','' }
        if ($row.key -eq 'cursorAuth/cachedEmail')  { $email = $row.value -replace '^"|"$','' }
    }

    # Decode JWT payload to extract userId (sub field)
    if ($tok) {
        try {
            $parts = $tok -split '\.'
            if ($parts.Count -ge 2) {
                $b64 = $parts[1]
                $pad = $b64.Length % 4
                if ($pad -ne 0) { $b64 += '=' * (4 - $pad) }
                $payload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64)) | ConvertFrom-Json
                if ($payload.sub) { $userId = $payload.sub }
            }
        } catch { }
    }

    return $tok, $userId, $email
}

# ---------------------------------------------------------------------------
# Live data from Cursor API
# ---------------------------------------------------------------------------
function Get-CursorUsage {
    param([int]$TimeoutSec = 20)

    $tok, $userId, $email = Get-CursorToken
    if (-not $tok -or -not $userId) {
        $script:AuthState = 'notoken'; $script:CursorErrMsg = 'Cannot read Cursor token from state.vscdb'
        return
    }

    $session = New-CursorWebSession -UserId $userId -Token $tok

    try {
        $r = Invoke-RestMethod "https://cursor.com/api/usage?user=$([Uri]::EscapeDataString($userId))" `
            -WebSession $session -TimeoutSec $TimeoutSec
        $script:LiveData        = $r
        $script:AuthState       = 'ok'
        $script:CursorErrMsg    = ''
        $script:CursorLastFetch = (Get-Date -Format 'HH:mm')
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401) { $script:AuthState = 'auth';  $script:CursorErrMsg = 'Auth expired - reopen Cursor' }
        else                { $script:AuthState = 'stale'; $script:CursorErrMsg = $_.Exception.Message }
    }

    # Also fetch usage-summary for on-demand spend
    try {
        $script:SummaryData = Invoke-RestMethod 'https://cursor.com/api/usage-summary' `
            -WebSession $session -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec $TimeoutSec
    } catch { }
}

# ---------------------------------------------------------------------------
# Edit/model stats from the Cursor dashboard analytics API.
# Cursor stopped writing the local ai-code-tracking.db (ai_code_hashes) around
# 2026-05-27 and serves these live from cursor.com instead. The endpoint is
# user-scoped and returns a fixed ~30-day rolling window of per-day metrics.
# (No web or live-local source exposes a conversation/session count anymore.)
# ---------------------------------------------------------------------------
function Get-CursorLocalStats {
    param([int]$TimeoutSec = 20)

    $tok, $userId, $email = Get-CursorToken
    if (-not $tok -or -not $userId) { return }
    $session = New-CursorWebSession -UserId $userId -Token $tok

    try {
        $a = Invoke-RestMethod 'https://cursor.com/api/dashboard/get-user-analytics' `
            -WebSession $session -TimeoutSec $TimeoutSec
    } catch { return }
    if (-not $a -or -not $a.dailyMetrics) { return }

    # date is UTC-midnight ms; match the bucket whose day == today (UTC).
    $todayMs = [System.DateTimeOffset]::new([datetime]::UtcNow.Date, [TimeSpan]::Zero).ToUnixTimeMilliseconds()

    $edits30d = 0; $editsToday = 0; $linesAcc = 0
    $models = @{}
    foreach ($day in $a.dailyMetrics) {
        $edits30d += [int]$day.totalApplies
        $linesAcc += [int]$day.acceptedLinesAdded
        if ([long]$day.date -eq $todayMs) { $editsToday = [int]$day.totalApplies }
        foreach ($m in $day.modelUsage) {
            if ($m.name) { $models[$m.name] = [int]$models[$m.name] + [int]$m.count }
        }
    }

    $topModel = $null; $topCount = 0; $totalModel = 0
    foreach ($kv in $models.GetEnumerator()) {
        $totalModel += $kv.Value
        if ($kv.Value -gt $topCount) { $topCount = $kv.Value; $topModel = $kv.Key }
    }
    $topPct = if ($totalModel -gt 0) { [int][Math]::Round($topCount * 100.0 / $totalModel) } else { 0 }

    $script:LocalData = [PSCustomObject]@{
        edits30d      = $edits30d
        editsToday    = $editsToday
        topModel      = $topModel
        topPct        = $topPct
        linesAccepted = $linesAcc
    }
}
