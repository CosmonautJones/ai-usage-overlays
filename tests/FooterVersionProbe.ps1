param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# Fresh STA process: the footer row has to go through real WPF layout, and the
# Pester runner must not have WPF loaded first (same reason as ShellFitProbe.ps1).
# Proves two things the source text cannot: the version costs zero vertical
# height, and it repaints amber/chrome off the live update state.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $Root 'src\Format.ps1')
. (Join-Path $Root 'src\Layout.ps1')
. (Join-Path $Root 'src\Shell.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$script:window = [Windows.Markup.XamlReader]::Load($reader)

$footer = $script:window.FindName('footerRow')
Assert-True ($null -ne $footer) 'footerRow missing from XAML'
$version = $script:window.FindName('versionLabel')
Assert-True ($null -ne $version) 'versionLabel missing from XAML'
$brand = $script:window.FindName('brandLabel')
Assert-True ($null -ne $brand) 'brandLabel missing from XAML'

# --- right-aligned in its own column, clear of the brand's * slack -----------
Assert-True ([System.Windows.Controls.Grid]::GetColumn($version) -eq 2) 'versionLabel is not in the trailing column'
Assert-True ([System.Windows.Controls.Grid]::GetColumn($brand) -eq 1) 'brandLabel lost its * column'
Assert-True ($version.HorizontalAlignment -eq [System.Windows.HorizontalAlignment]::Right) 'versionLabel is not right-aligned'

# --- zero extra vertical height: it rides inside the 18px brand mark ---------
$version.Text = 'v0.4.1'
$sized = Measure-ContentHeight
$withVersion = $footer.ActualHeight
$contentWithVersion = $sized.Height

$version.Visibility = [System.Windows.Visibility]::Collapsed
$sized = Measure-ContentHeight
$withoutVersion = $footer.ActualHeight
$contentWithoutVersion = $sized.Height
$version.Visibility = [System.Windows.Visibility]::Visible

Assert-True ($withVersion -eq $withoutVersion) "footer row grew from $withoutVersion to $withVersion DIP"
Assert-True ($contentWithVersion -eq $contentWithoutVersion) "window content grew from $contentWithoutVersion to $contentWithVersion DIP"

# --- the paint: amber only while a release is waiting ------------------------
$script:AppVersion = '9.9.9'
$script:Themes = @{
    'Probe' = @{ BrandLabelFg = '#5C8AAA' }
    'Other' = @{ BrandLabelFg = '#3DC95A' }
}
$script:Cfg = @{ Theme = 'Probe' }

$script:UpdateState = @{ Status = 'current' }
Update-FooterVersion
Assert-True ($version.Text -eq 'v9.9.9') "version text was '$($version.Text)'"
Assert-True ($version.Foreground.Color.ToString() -eq '#FF5C8AAA') "up-to-date paint was $($version.Foreground.Color)"

$script:UpdateState = @{ Status = 'available' }
Update-FooterVersion
Assert-True ($version.Foreground.Color.ToString() -eq '#FFFBBF24') "update paint was $($version.Foreground.Color)"

# --- a theme switch repaints the brand but must not clobber the amber --------
$script:Cfg.Theme = 'Other'
Apply-UnifiedTheme 'Other'
Assert-True ($brand.Foreground.Color.ToString() -eq '#FF3DC95A') "theme did not reach the brand label: $($brand.Foreground.Color)"
Assert-True ($version.Foreground.Color.ToString() -eq '#FFFBBF24') 'theme switch clobbered the update tint'

$script:UpdateState = @{ Status = 'current' }
Apply-UnifiedTheme 'Other'
Assert-True ($version.Foreground.Color.ToString() -eq '#FF3DC95A') "cleared update did not fall back to theme chrome: $($version.Foreground.Color)"

'Footer version passed'
