param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# Fresh STA process: Update-ClaudeSection drives real WPF elements, and the
# Pester runner must not have WPF loaded first (same reason as ShellFitProbe.ps1).
# Accounts without a Fable weekly window get seven_day_fable = null, which used
# to leave a FABLE WEEKLY row reading '--' forever. It should come and go with
# the data, the way the Opus row does.

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

function Assert-FableRows([object]$Window, [System.Windows.Visibility]$Want, [string]$Case) {
    foreach ($n in 'fabRow', 'fabRowC') {
        $row = $Window.FindName($n)
        Assert-True ($null -ne $row) "$n missing from XAML"
        Assert-True ($row.Visibility -eq $Want) "${Case}: $n is $($row.Visibility), expected $Want"
    }
}

function New-Usage($Fable) {
    [pscustomobject]@{
        five_hour       = [pscustomobject]@{ utilization = 32.0; resets_at = (Get-Date).ToUniversalTime().AddHours(2).ToString('o') }
        seven_day       = [pscustomobject]@{ utilization = 44.0; resets_at = (Get-Date).ToUniversalTime().AddDays(2).ToString('o') }
        seven_day_fable = $Fable
        seven_day_opus  = $null
    }
}

$script:Cfg = $null
$script:History = $null
$script:Stats = $null
$script:ClaudeIdentity = $null
$collapsed = [System.Windows.Visibility]::Collapsed
$visible = [System.Windows.Visibility]::Visible
$fable = [pscustomobject]@{ utilization = 12.0; resets_at = (Get-Date).ToUniversalTime().AddDays(3).ToString('o') }

# --- before any data: nothing to show yet ------------------------------------
$w = New-ProbeWindow
Assert-FableRows $w $collapsed 'fresh window'

# --- the reported case: the API sends seven_day_fable = null -----------------
$script:State = @{ Data = (New-Usage $null); Status = 'ok'; Message = ''; LastFetch = '19:40' }
Update-ClaudeSection
Assert-FableRows $w $collapsed 'null Fable window'
Assert-True ($w.FindName('weekPct').Text -eq '44%') 'the rest of the section must still render'

# --- a window object with no reading is no better than null ------------------
$script:State = @{ Data = (New-Usage ([pscustomobject]@{ utilization = $null; resets_at = $null })); Status = 'ok'; Message = ''; LastFetch = '19:40' }
Update-ClaudeSection
Assert-FableRows $w $collapsed 'Fable window without utilization'

# --- a real reading shows the row in both views ------------------------------
$script:State = @{ Data = (New-Usage $fable); Status = 'ok'; Message = ''; LastFetch = '19:40' }
Update-ClaudeSection
Assert-FableRows $w $visible 'Fable reading'
Assert-True ($w.FindName('fabPct').Text -eq '12%') "fabPct read '$($w.FindName('fabPct').Text)'"
Assert-True ($w.FindName('fabPctC').Text -eq '12%') "fabPctC read '$($w.FindName('fabPctC').Text)'"

# --- zero is a reading, not an absence ---------------------------------------
$script:State = @{ Data = (New-Usage ([pscustomobject]@{ utilization = 0.0; resets_at = $fable.resets_at })); Status = 'ok'; Message = ''; LastFetch = '19:40' }
Update-ClaudeSection
Assert-FableRows $w $visible 'Fable at 0%'
Assert-True ($w.FindName('fabPct').Text -eq '0%') "fabPct read '$($w.FindName('fabPct').Text)'"

# --- and the row leaves again when the window disappears ---------------------
$script:State = @{ Data = (New-Usage $null); Status = 'ok'; Message = ''; LastFetch = '19:41' }
Update-ClaudeSection
Assert-FableRows $w $collapsed 'Fable window dropped'

'Claude Fable row passed'
