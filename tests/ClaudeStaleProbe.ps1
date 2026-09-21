param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# Fresh STA process: Update-ClaudeSection drives real WPF elements, and the
# Pester runner must not have WPF loaded first (same reason as ShellFitProbe.ps1).
# Renders the Claude section from a carried-forward state and fails loudly if
# frozen numbers are still dressed up as live ones.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $Root 'src\Config.ps1')
. (Join-Path $Root 'src\Format.ps1')
. (Join-Path $Root 'src\Layout.ps1')
. (Join-Path $Root 'src\Shell.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-ProbeWindow {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $script:window = [Windows.Markup.XamlReader]::Load($reader)
    return $script:window
}

$script:Cfg = $null
$script:History = $null
$script:Stats = $null
$script:ClaudeIdentity = $null

# The reported shape: a 5h window whose reset time is already in the past.
$usage = [pscustomobject]@{
    five_hour       = [pscustomobject]@{ utilization = 32.0; resets_at = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o') }
    seven_day       = [pscustomobject]@{ utilization = 44.0; resets_at = (Get-Date).ToUniversalTime().AddDays(2).ToString('o') }
    seven_day_fable = [pscustomobject]@{ utilization = 12.0; resets_at = (Get-Date).ToUniversalTime().AddDays(3).ToString('o') }
}

# --- carried-forward data: numbers stay, countdowns become 'as of HH:mm' -----
$w = New-ProbeWindow
$script:State = @{ Data = $usage; Status = 'auth'; Message = 'Auth expired'; LastFetch = ''; Stale = $true; DataAsOf = '19:12' }
Update-ClaudeSection

Assert-True ($w.FindName('fivehPct').Text -eq '32%') "stale numbers must stay on screen, got '$($w.FindName('fivehPct').Text)'"
Assert-True ($w.FindName('weekPct').Text -eq '44%') "stale numbers must stay on screen, got '$($w.FindName('weekPct').Text)'"
foreach ($n in 'fivehReset', 'weekReset', 'fabReset') {
    Assert-True ($w.FindName($n).Text -eq 'as of 19:12') "$n should read 'as of 19:12', got '$($w.FindName($n).Text)'"
}
Assert-True ($w.FindName('claudeHeaderDetail').Text -eq 'as of 19:12') "compact header detail should read 'as of 19:12', got '$($w.FindName('claudeHeaderDetail').Text)'"
Assert-True ($w.FindName('claudeBody').Opacity -lt 1.0) 'a stale Claude section must be dimmed'

# --- stale with no known fetch time still refuses to draw a countdown --------
$w = New-ProbeWindow
$script:State = @{ Data = $usage; Status = 'auth'; Message = 'Auth expired'; LastFetch = ''; Stale = $true; DataAsOf = '' }
Update-ClaudeSection
Assert-True ($w.FindName('weekReset').Text -eq 'stale') "unknown as-of should read 'stale', got '$($w.FindName('weekReset').Text)'"

# --- fresh data: real countdowns, full opacity ------------------------------
$w = New-ProbeWindow
$script:State = @{ Data = $usage; Status = 'ok'; Message = ''; LastFetch = '19:40'; Stale = $false; DataAsOf = '19:40' }
Update-ClaudeSection

Assert-True ($w.FindName('weekReset').Text -notmatch 'as of') "fresh data must show a countdown, got '$($w.FindName('weekReset').Text)'"
Assert-True ($w.FindName('weekReset').Text -match '\d+d \d+h') "fresh countdown missing, got '$($w.FindName('weekReset').Text)'"
Assert-True ($w.FindName('claudeBody').Opacity -eq 1.0) 'a fresh Claude section must not be dimmed'

# --- a state predating the stale flags renders as fresh ---------------------
$w = New-ProbeWindow
$script:State = @{ Data = $usage; Status = 'ok'; Message = ''; LastFetch = '19:40' }
Update-ClaudeSection
Assert-True ($w.FindName('claudeBody').Opacity -eq 1.0) 'a state without the stale keys must not dim the section'
Assert-True ($w.FindName('weekReset').Text -notmatch 'as of') 'a state without the stale keys must keep its countdown'

# --- no data at all: the dimming must not stick -----------------------------
$w = New-ProbeWindow
$script:State = @{ Data = $null; Status = 'auth'; Message = 'Auth expired'; LastFetch = '' }
Update-ClaudeSection
Assert-True ($w.FindName('fivehPct').Text -eq '--') 'an empty Claude section still reads --'
Assert-True ($w.FindName('claudeBody').Opacity -eq 1.0) 'an empty Claude section must not be dimmed'

'Claude stale render passed'
