param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# Fresh STA process: building the real accordion needs WPF, and the Pester
# runner must not have WPF loaded first (same reason as MenuDpiProbe.ps1).
# Drives the shipping Measure-FittedSize against stubbed monitor work areas and
# fails loudly if the fully expanded window would not fit.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $Root 'src\Layout.ps1')
. (Join-Path $Root 'src\Shell.ps1')

# Stands in for UnifiedState.ps1's monitor lookup.
$script:StubWorkAreaHeight = 816.0
function Get-WorkArea {
    @{ Left = 0.0; Top = 0.0; Right = 1536.0; Bottom = $script:StubWorkAreaHeight }
}

function New-ExpandedWindow {
    param([switch]$WithOpus, [switch]$WithSparklines)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $w = [Windows.Markup.XamlReader]::Load($reader)
    foreach ($s in 'claude', 'codex', 'cursor', 'grok') {
        foreach ($suffix in 'Section', 'Body', 'Full') {
            $el = $w.FindName($s + $suffix)
            if ($el) { $el.Visibility = [System.Windows.Visibility]::Visible }
        }
        $c = $w.FindName($s + 'Compact')
        if ($c) { $c.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    if ($WithOpus) { $w.FindName('opusRow').Visibility = [System.Windows.Visibility]::Visible }
    if ($WithSparklines) {
        foreach ($n in 'fivehSparkRow', 'weekSparkRow', 'codexFivehSparkRow',
                       'codexWeekSparkRow', 'cursorReqSparkRow', 'grokWeekSparkRow') {
            $row = $w.FindName($n)
            if ($row) { $row.Visibility = [System.Windows.Visibility]::Visible }
        }
    }
    $script:window = $w
    return $w
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# --- the reported bug: all four providers open on a 1536x864 display ---------
$script:StubWorkAreaHeight = 816.0
$w = New-ExpandedWindow
Assert-True ($null -ne $w.FindName('sectionScroll')) 'sectionScroll missing from XAML'
Assert-True ($null -ne $w.FindName('sectionStack')) 'sectionStack missing from XAML'
$budget = Get-FitBudget -WorkAreaHeight 816
$h = (Measure-FittedSize).Height
Assert-True ($h -le $budget) "All four expanded: $h DIP exceeds $budget budget"

# --- worst realistic case: Opus row plus every sparkline --------------------
$w = New-ExpandedWindow -WithOpus -WithSparklines
$h = (Measure-FittedSize).Height
Assert-True ($h -le $budget) "Opus + sparklines: $h DIP exceeds $budget budget"

# --- a cramped display must scroll rather than overhang ---------------------
$script:StubWorkAreaHeight = 600.0
$w = New-ExpandedWindow -WithOpus -WithSparklines
$budget600 = Get-FitBudget -WorkAreaHeight 600
$size = Measure-FittedSize
Assert-True ($size.Height -le $budget600) "600px work area: $($size.Height) exceeds $budget600"
Assert-True ($w.FindName('sectionScroll').MaxHeight -lt 600) 'scroll region was not clamped'
Assert-True ($size.Width -eq 304) "scrollbar reflowed content: width $($size.Width), expected 304"

# --- roomy display: no clamp at all ----------------------------------------
$script:StubWorkAreaHeight = 1032.0
$w = New-ExpandedWindow -WithOpus
$size = Measure-FittedSize
Assert-True ([double]::IsPositiveInfinity($w.FindName('sectionScroll').MaxHeight)) 'scroll region clamped even though content fits'

# --- regression guard: spacing must not creep back in -----------------------
# Was 912 DIP with the Opus row and overflowed an 816 work area.
$w = New-ExpandedWindow -WithOpus
$sv = $w.FindName('sectionScroll')
$sv.MaxHeight = [double]::PositiveInfinity
$natural = (Measure-ContentHeight).Height
Assert-True ($natural -lt 780) "natural expanded height regressed to $natural DIP (ceiling 780)"

# --- sub-labels: hidden when they would only repeat 'used' ------------------
$w = New-ExpandedWindow
foreach ($n in 'fivehSub', 'weekSub', 'fabSub', 'codexWeekSub', 'reqSub', 'grokWeekSub') {
    Assert-True ($w.FindName($n).Visibility -eq [System.Windows.Visibility]::Collapsed) "$n should start collapsed"
}
$el = $w.FindName('fivehSub')
Set-BarSubText $el 'critical!'
Assert-True ($el.Visibility -eq [System.Windows.Visibility]::Visible) 'warn text must be visible'
Assert-True ($el.Text -eq 'critical!') 'warn text not written'
Set-BarSubText $el 'used'
Assert-True ($el.Visibility -eq [System.Windows.Visibility]::Collapsed) 'filler must re-hide'
Set-BarSubText $w.FindName('reqSub') '284 / 500'
Assert-True ($w.FindName('reqSub').Visibility -eq [System.Windows.Visibility]::Visible) 'Cursor request count must stay visible'

'Shell fit passed'
