param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# Fresh STA process: the brushes only mean something once WPF has parsed them,
# and the Pester runner must not have WPF loaded first (same reason as ShellFitProbe.ps1).
# WPF reads an 8-digit colour as #AARRGGBB, so a translucent tint has to lead
# with its alpha. Tacking the alpha onto the end (#RRGGBBAA) silently shifts
# every channel: #38BDF8 + '55' became a pale lime instead of a faint sky blue.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:AppDir = $Root
. (Join-Path $Root 'src\Config.ps1')
. (Join-Path $Root 'src\Format.ps1')
. (Join-Path $Root 'src\Layout.ps1')
. (Join-Path $Root 'src\Shell.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-TintHex([string]$Hex, [string]$Alpha) {
    '#' + $Alpha + $Hex.TrimStart('#').ToUpperInvariant()
}

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$script:window = [Windows.Markup.XamlReader]::Load($reader)
$script:AppVersion = '9.9.9'
$script:UpdateState = @{ Status = 'current' }

# --- warning sub-labels: the theme hue, faded, in every theme ---------------
Assert-True ($script:Themes.Count -gt 0) 'no themes loaded from Config.ps1'
foreach ($name in @($script:Themes.Keys)) {
    $t = $script:Themes[$name]
    $script:Cfg = @{ Theme = $name }
    Apply-UnifiedTheme $name

    $grokFg = if ($t.GrokFg) { $t.GrokFg } elseif ($t.OpusFg) { $t.OpusFg } else { '#FDE68A' }
    $expected = [ordered]@{
        fivehSub     = $t.FivehFg
        weekSub      = $t.WeekFg
        fabSub       = $t.FabFg
        opusSub      = $t.OpusFg
        codexWeekSub = $t.WeekFg
        grokWeekSub  = $grokFg
    }
    foreach ($sub in $expected.Keys) {
        if (-not $expected[$sub]) { continue }
        $want = Get-TintHex $expected[$sub] '55'
        $got = $script:window.FindName($sub).Foreground.Color.ToString()
        Assert-True ($got -eq $want) "$name ${sub}: painted $got, expected $want"
    }
}

# --- section divider: sky into purple, barely there -------------------------
$divider = $script:window.Resources['Divider']
Assert-True ($null -ne $divider) 'Divider brush missing from XAML'
$stops = @($divider.GradientStops)
Assert-True ($stops.Count -eq 4) "Divider has $($stops.Count) stops, expected 4"
Assert-True ($stops[1].Color.ToString() -eq '#2838BDF8') "Divider sky stop is $($stops[1].Color)"
Assert-True ($stops[2].Color.ToString() -eq '#28C084FC') "Divider purple stop is $($stops[2].Color)"

'Theme alpha passed'
