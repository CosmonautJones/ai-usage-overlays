<#
    Cursor Usage Overlay
    --------------------
    Always-on-top HUD showing live Cursor IDE usage:
      • Included requests used / limit + reset countdown
      • Agent edits (all-time and today) from local tracking DB
      • Model breakdown (top model + %)
    Right-click the panel for all options.

    Usage:
      pwsh -File cursor-overlay.ps1           # run
      pwsh -File cursor-overlay.ps1 -Install  # add login auto-start + run
      pwsh -File cursor-overlay.ps1 -Uninstall
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Hidden,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'

$script:AppDir    = $PSScriptRoot
$script:StatePath = Join-Path $script:AppDir 'cursor-overlay-state.json'
$script:PidPath   = Join-Path $script:AppDir 'cursor-overlay.pid'
$script:VbsPath   = Join-Path $script:AppDir 'Start-CursorOverlay.vbs'
$script:ErrLog    = Join-Path $script:AppDir 'cursor-overlay-error.log'
$script:LnkPath   = Join-Path ([Environment]::GetFolderPath('Startup')) 'CursorUsageOverlay.lnk'
$script:StateVscdb = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
$script:TrackingDb = Join-Path $env:USERPROFILE '.cursor\ai-tracking\ai-code-tracking.db'

# Ensure TLS 1.2 for HTTPS calls (required on Windows PowerShell 5.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Install-Autostart {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($script:LnkPath)
    $sc.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments        = '"' + $script:VbsPath + '"'
    $sc.WorkingDirectory = $script:AppDir
    $sc.Description      = 'Cursor Usage Overlay'
    $sc.Save()
}
function Uninstall-Autostart { if (Test-Path $script:LnkPath) { Remove-Item $script:LnkPath -Force } }
function Test-Autostart      { Test-Path $script:LnkPath }

if ($Uninstall) { Uninstall-Autostart; Write-Host 'Removed login auto-start.'; return }
if ($Install) {
    Install-Autostart
    $exe = (Get-Process -Id $PID).Path
    Start-Process $exe -ArgumentList '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-NonInteractive','-File',$PSCommandPath,'-Background'
    Write-Host 'Installed. Cursor overlay is running.'
    return
}

if (-not $Background) {
    Add-Type -Name '_CK32' -Namespace '' -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
    if ([_CK32]::GetConsoleWindow() -ne [IntPtr]::Zero) {
        $exe = (Get-Process -Id $PID).Path
        Start-Process $exe -ArgumentList '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-NonInteractive','-File',$PSCommandPath,'-Background'
        exit
    }
}

try {

function Log([string]$msg) { Add-Content -Path $script:ErrLog -Value "$(Get-Date -Format 'HH:mm:ss') $msg" }

Log "Starting up"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
                       System.Windows.Forms, System.Drawing, System.Xaml
Log "Assemblies loaded"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
# Single-instance guard — PID file prevents duplicate instances regardless of launch method
if (Test-Path $script:PidPath) {
    $oldPid = [int](Get-Content $script:PidPath -Raw -EA SilentlyContinue)
    if ($oldPid -and $oldPid -ne $PID) { Stop-Process -Id $oldPid -Force -EA SilentlyContinue }
}
$PID | Set-Content $script:PidPath

$script:LiveData      = $null
$script:LocalData     = $null
$script:SummaryData   = $null
$script:OnDemandCents = $null
$script:AuthState     = 'init'
$script:LastFetch     = ''
$script:PendingOpacity = $null   # applied on WPF thread by DispatcherTimer
$script:ErrMsg    = ''
$script:ReallyQuit = $false
$script:Positioned = $false
$script:BarTrackWidth = 250.0

# ---------------------------------------------------------------------------
# Color themes
# ---------------------------------------------------------------------------
$script:Themes = [ordered]@{
    'Cursor Green' = @{
        BgC1 = '#0A1628'; BgC2 = '#060E1C'; BorderC1 = '#0F3D2F'
        BarC1 = '#065F46'; BarC2 = '#34D399'
        LabelFg = '#34D399'; ValueFg = '#6EE7B7'; DimFg = '#7EC4A6'
        BarTrack = '#0C1A12'; OnDemandFg = '#FBBF24'; BrandLabelFg = '#5CA882'
        Stripe = '#065F46','#34D399','#6EE7B7','#A7F3D0'
    }
    'TravOS' = @{
        BgC1 = '#081508'; BgC2 = '#040C06'; BorderC1 = '#1A5C2A'
        BarC1 = '#1A5C2A'; BarC2 = '#2D9F48'
        LabelFg = '#2D9F48'; ValueFg = '#4AE068'; DimFg = '#5AAD78'
        BarTrack = '#0D1F0F'; OnDemandFg = '#FBBF24'; BrandLabelFg = '#3DC95A'
        Stripe = '#1A5C2A','#2D9F48','#4AE068','#86EFAC'
    }
    'Deep Space' = @{
        BgC1 = '#0F111A'; BgC2 = '#080A12'; BorderC1 = '#252B44'
        BarC1 = '#2D3A8A'; BarC2 = '#818CF8'
        LabelFg = '#818CF8'; ValueFg = '#A5B4FC'; DimFg = '#6B82A8'
        BarTrack = '#151A2E'; OnDemandFg = '#FB923C'; BrandLabelFg = '#6B82A8'
        Stripe = '#38BDF8','#818CF8','#C084FC','#FB923C'
    }
    'Mono' = @{
        BgC1 = '#111111'; BgC2 = '#080808'; BorderC1 = '#2A2A2A'
        BarC1 = '#262626'; BarC2 = '#D4D4D4'
        LabelFg = '#D4D4D4'; ValueFg = '#FAFAFA'; DimFg = '#909090'
        BarTrack = '#1C1C1C'; OnDemandFg = '#E5E5E5'; BrandLabelFg = '#909090'
        Stripe = '#404040','#737373','#A3A3A3','#E5E5E5'
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function NewBrush([string]$hex) {
    New-Object System.Windows.Media.SolidColorBrush (
        [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function New-GradBrush([string]$c1, [string]$c2) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = [System.Windows.Point]::new(0,0); $b.EndPoint = [System.Windows.Point]::new(1,0)
    $s1 = New-Object System.Windows.Media.GradientStop
    $s1.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c1); $s1.Offset = 0
    $s2 = New-Object System.Windows.Media.GradientStop
    $s2.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c2); $s2.Offset = 1
    [void]$b.GradientStops.Add($s1); [void]$b.GradientStops.Add($s2); return $b
}

function New-DiagGradBrush([string]$c1, [string]$c2) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = [System.Windows.Point]::new(0,0); $b.EndPoint = [System.Windows.Point]::new(0.7,1)
    $s1 = New-Object System.Windows.Media.GradientStop
    $s1.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c1); $s1.Offset = 0
    $s2 = New-Object System.Windows.Media.GradientStop
    $s2.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($c2); $s2.Offset = 1
    [void]$b.GradientStops.Add($s1); [void]$b.GradientStops.Add($s2); return $b
}

function Fmt-Num([double]$n) {
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0}k'   -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}

function Format-Reset([string]$isoDate) {
    if (-not $isoDate) { return '' }
    try {
        # startOfMonth is billing cycle start; add ~31 days to estimate reset
        $start = [System.DateTimeOffset]::Parse($isoDate)
        # Reset is 1 month after start
        $reset = $start.AddDays(31)
        # Try to snap to same day next month
        try { $reset = [System.DateTimeOffset]::new($start.Year, $start.Month + 1, $start.Day, $start.Hour, $start.Minute, $start.Second, $start.Offset) } catch { }
        $span  = $reset - [System.DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return 'now' }
        if ($span.TotalDays -ge 1)    { return ('in {0}d {1}h' -f [int]$span.TotalDays, $span.Hours) }
        if ($span.TotalHours -ge 1)   { return ('in {0}h{1:00}m' -f [int]$span.TotalHours, $span.Minutes) }
        return ('in {0}m' -f [int]$span.TotalMinutes)
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# SQLite helper — reads Cursor's SQLite databases via bundled sqlite3.exe
# ---------------------------------------------------------------------------
function Invoke-Sqlite {
    param([string]$DbPath, [string]$Query)
    $exe = $null
    if ($PSScriptRoot) {
        $candidate = Join-Path $PSScriptRoot 'sqlite3.exe'
        if (Test-Path $candidate) { $exe = $candidate }
    }
    if (-not $exe) {
        $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }
    if (-not $exe) { return $null }
    try {
        # sqlite3 -json may return output as a string array (one line per line);
        # join into a single string so ConvertFrom-Json can parse the full JSON.
        $lines = & $exe -readonly -json $DbPath $Query 2>$null
        if ($lines) { $lines -join '' } else { $null }
    } catch { $null }
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
                if ($payload.sub) {
                    # sub is auth0|user_xxx — cookie/API expect the user_xxx portion
                    $userId = $payload.sub
                    if ($userId -match '\|') { $userId = ($userId -split '\|')[-1] }
                }
            }
        } catch { }
    }

    return $tok, $userId, $email
}

# ---------------------------------------------------------------------------
# Live data from Cursor API
# ---------------------------------------------------------------------------
function Get-CursorUsage {
    $tok, $userId, $email = Get-CursorToken
    if (-not $tok) {
        $script:AuthState = 'notoken'; $script:ErrMsg = 'Cannot read Cursor token from state.vscdb'
        return
    }

    # IDE access tokens authenticate against api2.cursor.sh, not cursor.com dashboard cookies
    $bearer = @{ Authorization = "Bearer $tok" }

    try {
        $r = Invoke-RestMethod 'https://api2.cursor.sh/auth/usage' -Headers $bearer -TimeoutSec 20
        $script:LiveData  = $r
        $script:AuthState = 'ok'
        $script:ErrMsg    = ''
        $script:LastFetch = (Get-Date -Format 'HH:mm')
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401) { $script:AuthState = 'auth';  $script:ErrMsg = 'Auth expired - reopen Cursor' }
        else                { $script:AuthState = 'stale'; $script:ErrMsg = $_.Exception.Message }
    }

    # On-demand spend: sum chargedCents of usage-based events since billing-cycle start.
    # (api2 DashboardService accepts the same bearer token; GetCurrentPeriodUsage is empty
    #  for team accounts, so we derive the figure from the usage-event log instead.)
    try {
        $cycleStartMs = $null
        if ($script:LiveData -and $script:LiveData.startOfMonth) {
            $cycleStartMs = [System.DateTimeOffset]::Parse([string]$script:LiveData.startOfMonth).ToUnixTimeMilliseconds()
        }
        if ($null -ne $cycleStartMs) {
            $script:OnDemandCents = Get-CursorOnDemandCents $tok $cycleStartMs
        }
    } catch { }
}

# Sums usage-based (on-demand) charges in cents for the current billing cycle.
function Get-CursorOnDemandCents([string]$tok, [long]$cycleStartMs) {
    $headers = @{
        Authorization              = "Bearer $tok"
        'Connect-Protocol-Version' = '1'
        'Content-Type'             = 'application/json'
    }
    $nowMs    = [System.DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $page     = 1
    $pageSize = 200
    $cents    = 0.0
    while ($page -le 50) {
        $body = "{`"startDate`":`"$cycleStartMs`",`"endDate`":`"$nowMs`",`"page`":$page,`"pageSize`":$pageSize}"
        $res = Invoke-RestMethod 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents' `
            -Method POST -Headers $headers -Body $body -TimeoutSec 30
        $events = $res.usageEventsDisplay
        if (-not $events -or $events.Count -eq 0) { break }
        foreach ($e in $events) {
            if ($e.kind -eq 'USAGE_EVENT_KIND_USAGE_BASED' -and $null -ne $e.chargedCents) {
                $cents += [double]$e.chargedCents
            }
        }
        if ($events.Count -lt $pageSize) { break }
        $page++
    }
    return $cents
}

# ---------------------------------------------------------------------------
# Local stats from ai-code-tracking.db via sqlite3.exe
# ---------------------------------------------------------------------------
function Get-CursorLocalStats {
    if (-not (Test-Path $script:TrackingDb)) { return }

    # Total edits
    $rawTotal = Invoke-Sqlite $script:TrackingDb "SELECT COUNT(*) AS cnt FROM ai_code_hashes"
    if (-not $rawTotal) { return }
    $total = 0
    try {
        $totalRows = $rawTotal | ConvertFrom-Json
        if ($totalRows -and $totalRows.cnt) { $total = [int]$totalRows.cnt }
    } catch { return }

    # Today edits (createdAt is milliseconds since epoch)
    $rawToday = Invoke-Sqlite $script:TrackingDb "SELECT COUNT(*) AS cnt FROM ai_code_hashes WHERE date(createdAt/1000,'unixepoch') = date('now')"
    $todayCount = 0
    try {
        if ($rawToday) {
            $todayRows = $rawToday | ConvertFrom-Json
            if ($todayRows -and $null -ne $todayRows.cnt) { $todayCount = [int]$todayRows.cnt }
        }
    } catch { }

    # Top model
    $rawModel = Invoke-Sqlite $script:TrackingDb "SELECT model, COUNT(*) AS c FROM ai_code_hashes GROUP BY model ORDER BY c DESC LIMIT 1"
    $topModel = 'unknown'
    $topPct   = 0
    try {
        if ($rawModel) {
            $modelRow = $rawModel | ConvertFrom-Json
            if ($modelRow -and $modelRow.model) {
                $topModel = $modelRow.model
                if ($total -gt 0) {
                    $topPct = [int][Math]::Round([int]$modelRow.c * 100.0 / $total)
                }
            }
        }
    } catch { }

    # Distinct conversations
    $rawConvos = Invoke-Sqlite $script:TrackingDb "SELECT COUNT(DISTINCT conversationId) AS cnt FROM ai_code_hashes"
    $convos = 0
    try {
        if ($rawConvos) {
            $convoRows = $rawConvos | ConvertFrom-Json
            if ($convoRows -and $null -ne $convoRows.cnt) { $convos = [int]$convoRows.cnt }
        }
    } catch { }

    $script:LocalData = [PSCustomObject]@{
        total    = $total
        today    = $todayCount
        topModel = $topModel
        topPct   = $topPct
        convos   = $convos
    }
}

# ---------------------------------------------------------------------------
# XAML — Cursor overlay panel (teal/green accent palette)
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Cursor Usage" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual">

  <Grid Margin="12">
  <Border x:Name="mainBorder" BorderThickness="1" CornerRadius="16" ClipToBounds="True">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="16" Opacity="0.5" ShadowDepth="0"/>
    </Border.Effect>
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
        <GradientStop Color="#FF0A1628" Offset="0"/>
        <GradientStop Color="#FF060E1C" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.BorderBrush>
      <SolidColorBrush Color="#FF0F3D2F"/>
    </Border.BorderBrush>
    <DockPanel>

      <!-- Theme accent stripe — CornerRadius matches outer border (16-1=15) so it curves with the window -->
      <Border x:Name="accentStripe" DockPanel.Dock="Top" Height="5" CornerRadius="15,15,0,0">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#065F46" Offset="0"/>
            <GradientStop Color="#34D399" Offset="0.4"/>
            <GradientStop Color="#6EE7B7" Offset="0.7"/>
            <GradientStop Color="#A7F3D0" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>

      <StackPanel Margin="14,10,14,14" Width="250">

        <!-- Header -->
        <Grid Margin="0,0,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#34D399"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="headerLabel" Foreground="#6BBFA0" FontSize="12"
                       FontFamily="Bahnschrift SemiBold" Text="CURSOR "/>
            <TextBlock Foreground="#D1FAE5" FontSize="12" FontFamily="Bahnschrift SemiBold" Text="USAGE"/>
          </StackPanel>
          <TextBlock x:Name="timeText" Grid.Column="1" Text=""
                     Foreground="#5A9A80" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
        </Grid>

        <!-- ON-DEMAND HERO -->
        <StackPanel Margin="0,0,0,10">
          <TextBlock x:Name="onDemandLabel" Text="ON-DEMAND THIS CYCLE"
                     Foreground="#7EC4A6" FontSize="10" FontFamily="Bahnschrift SemiBold"
                     Margin="0,0,0,2"/>
          <TextBlock x:Name="onDemandText" Text="--"
                     Foreground="#FBBF24" FontSize="30" FontFamily="Bahnschrift Bold"/>
        </StackPanel>

        <!-- Divider -->
        <Border x:Name="divider" Height="1" Margin="0,0,0,10">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="Transparent" Offset="0"/>
              <GradientStop Color="#4034D399" Offset="0.4"/>
              <GradientStop Color="#4034D399" Offset="0.6"/>
              <GradientStop Color="Transparent" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <!-- Included Requests -->
        <StackPanel Margin="0,0,0,10">
          <!-- Label row: section label + over pill + reset countdown -->
          <Grid Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="reqLabel" Grid.Column="0" Text="INCLUDED REQUESTS"
                       Foreground="#34D399" FontSize="11" FontFamily="Bahnschrift SemiBold"
                       VerticalAlignment="Center" Margin="0,0,6,0"/>
            <Border x:Name="overPill" Grid.Column="1" Background="#1F1800"
                    BorderBrush="#FBBF24" BorderThickness="1" CornerRadius="3"
                    Padding="3,1,3,1" VerticalAlignment="Center" HorizontalAlignment="Left"
                    Visibility="Collapsed">
              <TextBlock Text="over" Foreground="#FBBF24" FontSize="9"
                         FontFamily="Bahnschrift SemiBold"/>
            </Border>
            <TextBlock x:Name="reqReset" Grid.Column="2" Text=""
                       Foreground="#7EC4A6" FontSize="10" FontFamily="Consolas"
                       VerticalAlignment="Center"/>
          </Grid>
          <!-- Count row -->
          <Grid Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="reqCountLabel" Grid.Column="0" Text="Requests"
                       Foreground="#7EC4A6" FontSize="11" FontFamily="Segoe UI"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="reqCount" Grid.Column="1" Text="-- / --"
                       Foreground="#6EE7B7" FontSize="12" FontFamily="Bahnschrift Bold"
                       VerticalAlignment="Center"/>
          </Grid>
          <!-- Progress bar -->
          <Border x:Name="barTrack" Height="6" CornerRadius="3" Background="#0E2018"
                  Width="250" HorizontalAlignment="Left">
            <Border x:Name="reqBar" Height="6" CornerRadius="3"
                    HorizontalAlignment="Left" Width="0">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#065F46" Offset="0"/>
                  <GradientStop Color="#34D399" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Border>
        </StackPanel>

        <!-- Local stats -->
        <Grid Margin="0,0,0,5">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="90"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="editsLabel" Grid.Column="0" Text="AGENT EDITS"
                     Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="editsText" Grid.Column="1" Text="--"
                     Foreground="#6EE7B7" FontSize="14" FontFamily="Consolas"/>
        </Grid>
        <Grid Margin="0,0,0,5">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="90"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="todayLabel" Grid.Column="0" Text="TODAY"
                     Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="todayText" Grid.Column="1" Text="--"
                     Foreground="#6EE7B7" FontSize="14" FontFamily="Consolas"/>
        </Grid>
        <Grid Margin="0,0,0,5">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="90"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="modelLabel" Grid.Column="0" Text="TOP MODEL"
                     Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="modelText" Grid.Column="1" Text="--"
                     Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
        </Grid>
        <Grid Margin="0,0,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="90"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="sessLabel" Grid.Column="0" Text="SESSIONS"
                     Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="sessText" Grid.Column="1" Text="--"
                     Foreground="#94A3B8" FontSize="14" FontFamily="Consolas"/>
        </Grid>

        <!-- Footer divider -->
        <Border Height="1" Margin="0,0,0,8">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="Transparent" Offset="0"/>
              <GradientStop Color="#301D2B1B" Offset="0.5"/>
              <GradientStop Color="Transparent" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <!-- TravOS footer -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Viewbox Width="18" Height="18" Stretch="Uniform" Margin="0,0,7,0" VerticalAlignment="Center">
            <Canvas Width="32" Height="32">
              <Path x:Name="brandPath" Fill="#5C8AAA"
                    Data="M6,6 H26 V10 H18 V26 H14 V10 H6 Z"/>
            </Canvas>
          </Viewbox>
          <TextBlock x:Name="brandLabel" Grid.Column="1" Text="TravOS"
                     Foreground="#5C8AAA" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
        </Grid>
</StackPanel>
    </DockPanel>
  </Border>
  </Grid>
</Window>
'@

Log "Loading XAML"
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$script:window = [System.Windows.Markup.XamlReader]::Load($reader)
Log "XAML loaded OK"

# ---------------------------------------------------------------------------
# Update UI
# ---------------------------------------------------------------------------
function Update-UI {
    $dot  = $script:window.FindName('statusDot')
    $time = $script:window.FindName('timeText')

    switch ($script:AuthState) {
        'ok'      { $dot.Fill = NewBrush '#34D399' }
        'stale'   { $dot.Fill = NewBrush '#FBBF24' }
        'auth'    { $dot.Fill = NewBrush '#F87171' }
        'notoken' { $dot.Fill = NewBrush '#F87171' }
        default   { $dot.Fill = NewBrush '#1D6B4E' }
    }

    # Requests bar
    $d = $script:LiveData
    if ($d -and $d.'gpt-4') {
        $used  = [int]$d.'gpt-4'.numRequests
        $limit = [int]$d.'gpt-4'.maxRequestUsage
        $pct   = if ($limit -gt 0) { [math]::Min(100, [math]::Round($used / $limit * 100)) } else { 0 }
        $over  = $used -gt $limit

        # Bar width
        $bar = $script:window.FindName('reqBar')
        $bar.Width = [math]::Min($script:BarTrackWidth, [math]::Round($pct / 100.0 * $script:BarTrackWidth))

        # Over pill and bar color
        $pill = $script:window.FindName('overPill')
        if ($over) {
            # Amber bar — going over is expected, informational not alarming
            $bar.Background = New-GradBrush '#78350F' '#FBBF24'
            if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Visible }
        } else {
            # Restore theme bar color
            $t = $script:Themes[$script:Cfg.Theme]
            if ($t) { $bar.Background = New-GradBrush $t.BarC1 $t.BarC2 }
            if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Collapsed }
        }

        $script:window.FindName('reqCount').Text = "$used / $limit"
        $script:window.FindName('reqReset').Text = Format-Reset $d.startOfMonth
        $time.Text = $script:LastFetch

        if ($script:notify) {
            $script:notify.Text = "Cursor  $used/$limit requests used"
        }
    } else {
        $script:window.FindName('reqBar').Width  = 0
        $script:window.FindName('reqCount').Text = '-- / --'
        $pill = $script:window.FindName('overPill')
        if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Collapsed }
        $time.Text = $script:LastFetch
    }

    # Spend is only returned for some plans. Enterprise request-based accounts
    # fall back to showing how far over the included request limit they are.
    $od = $script:window.FindName('onDemandText')
    if ($od) {
        if ($script:AuthState -eq 'auth' -or $script:AuthState -eq 'notoken') {
            # Error state — show message in hero area, time slot stays clean
            $od.FontSize = 11
            $od.Text = $script:ErrMsg
            $od.Foreground = NewBrush '#F87171'
        } else {
            $od.FontSize = 30
            if ($null -ne $script:OnDemandCents) {
                $dollars = [double]$script:OnDemandCents / 100.0
                $od.Text = ('${0:N2}' -f $dollars)
                $od.Foreground = if ($dollars -gt 0) { NewBrush '#FBBF24' } else { NewBrush '#5B9A80' }
            } else {
                $od.Text = '--'
                $od.Foreground = NewBrush '#5B9A80'
            }
        }
    }

    # Local stats
    $l = $script:LocalData
    if ($l) {
        $script:window.FindName('editsText').Text = ('{0} all-time' -f (Fmt-Num $l.total))
        $script:window.FindName('todayText').Text = ('{0} edits' -f (Fmt-Num $l.today))
        # Shorten model name
        $mn = $l.topModel -replace 'claude-','cl-' -replace 'composer-','cmp-' -replace '-latest','' -replace 'gpt-','gpt-'
        $script:window.FindName('modelText').Text = "$mn ($($l.topPct)%)"
        $script:window.FindName('sessText').Text  = ('{0} conversations' -f (Fmt-Num $l.convos))
    }
}

# ---------------------------------------------------------------------------
# Settings & positioning
# ---------------------------------------------------------------------------
$script:Cfg = @{ Left = $null; Top = $null; Opacity = 1.0; StartHidden = $false; Theme = 'Cursor Green' }
$script:themeItems = @{}

function Apply-CursorTheme([string]$name) {
    $t = $script:Themes[$name]
    if (-not $t) { $t = $script:Themes['Cursor Green'] }

    # Main panel background and border
    $mb = $script:window.FindName('mainBorder')
    if ($mb -and $t.BgC1) {
        $mb.Background = New-DiagGradBrush $t.BgC1 $t.BgC2
        $mb.BorderBrush = NewBrush $t.BorderC1
    }

    # Bar gradient and track
    $rb = $script:window.FindName('reqBar')
    if ($rb) { $rb.Background = New-GradBrush $t.BarC1 $t.BarC2 }
    $bt = $script:window.FindName('barTrack')
    if ($bt) { $bt.Background = NewBrush $t.BarTrack }

    # Section label (bright accent color)
    $rl = $script:window.FindName('reqLabel')
    if ($rl) { $rl.Foreground = NewBrush $t.LabelFg }

    # Dim labels
    foreach ($n in @('reqCountLabel','onDemandLabel','editsLabel','todayLabel','modelLabel','sessLabel','headerLabel')) {
        $el = $script:window.FindName($n)
        if ($el) { $el.Foreground = NewBrush $t.DimFg }
    }

    # Value text
    foreach ($n in @('reqCount','editsText','todayText','sessText')) {
        $el = $script:window.FindName($n)
        if ($el) { $el.Foreground = NewBrush $t.ValueFg }
    }
    foreach ($n in @('modelText')) {
        $el = $script:window.FindName($n)
        if ($el) { $el.Foreground = NewBrush ($t.ValueFg + 'AA') }  # slightly muted
    }

    # On-demand color
    $od = $script:window.FindName('onDemandText')
    if ($od) { $od.Foreground = NewBrush $t.OnDemandFg }

    $brand = $script:window.FindName('brandLabel')
    if ($brand -and $t.BrandLabelFg) { $brand.Foreground = NewBrush $t.BrandLabelFg }
    $bp = $script:window.FindName('brandPath')
    if ($bp -and $t.BrandLabelFg) { $bp.Fill = NewBrush $t.BrandLabelFg }

    # Accent stripe
    $stripe = $script:window.FindName('accentStripe')
    if ($stripe) {
        $gb = New-Object System.Windows.Media.LinearGradientBrush
        $gb.StartPoint = [System.Windows.Point]::new(0,0); $gb.EndPoint = [System.Windows.Point]::new(1,0)
        $offsets = @(0, 0.33, 0.66, 1)
        for ($i = 0; $i -lt 4; $i++) {
            $gs = New-Object System.Windows.Media.GradientStop
            $gs.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($t.Stripe[$i])
            $gs.Offset = $offsets[$i]
            [void]$gb.GradientStops.Add($gs)
        }
        $stripe.Background = $gb
    }

    # Sync menu checkmarks
    if ($script:themeItems) {
        foreach ($kv in $script:themeItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $name) }
    }
}

function Save-State {
    try {
        $script:Cfg.Left = $script:window.Left; $script:Cfg.Top = $script:window.Top
        $script:Cfg | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding UTF8
    } catch { }
}

function Load-State {
    try {
        if (-not (Test-Path $script:StatePath)) { return }
        $s = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        foreach ($k in @('Left','Top','Opacity','StartHidden','Theme')) { if ($null -ne $s.$k) { $script:Cfg[$k] = $s.$k } }
    } catch { }
}

function Clamp-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:window.Left = [math]::Max($wa.Left, [math]::Min($script:window.Left, $wa.Right  - $script:window.ActualWidth))
    $script:window.Top  = [math]::Max($wa.Top,  [math]::Min($script:window.Top,  $wa.Bottom - $script:window.ActualHeight))
}

function Snap-ToCorner([string]$corner) {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w = $script:window.ActualWidth; $h = $script:window.ActualHeight
    switch ($corner) {
        'TR' { $script:window.Left = $wa.Right - $w - 16; $script:window.Top = $wa.Top    + 16 }
        'TL' { $script:window.Left = $wa.Left  + 16;      $script:window.Top = $wa.Top    + 16 }
        'BR' { $script:window.Left = $wa.Right - $w - 16; $script:window.Top = $wa.Bottom - $h - 16 }
        'BL' { $script:window.Left = $wa.Left  + 16;      $script:window.Top = $wa.Bottom - $h - 16 }
    }
    Save-State
}

function Position-Window {
    if ($script:Positioned) { return }
    $script:Positioned = $true
    if ($null -ne $script:Cfg.Left) {
        $script:window.Left = [double]$script:Cfg.Left
        $script:window.Top  = [double]$script:Cfg.Top
        Clamp-Position
    } else {
        # Default: center of primary work area — impossible to miss on first launch
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:window.Left = $wa.Left + ($wa.Width  - $script:window.ActualWidth)  / 2
        $script:window.Top  = $wa.Top  + ($wa.Height - $script:window.ActualHeight) / 2
    }
}

function Copy-Stats {
    $d = $script:LiveData; $l = $script:LocalData
    $lines = @("Cursor Usage - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    if ($d -and $d.'gpt-4') {
        $lines += "Requests: $($d.'gpt-4'.numRequests) / $($d.'gpt-4'.maxRequestUsage)"
        $lines += "Reset: $(Format-Reset $d.startOfMonth)"
    }
    if ($l) {
        $lines += "Agent edits: $(Fmt-Num $l.total) all-time, $(Fmt-Num $l.today) today"
        $lines += "Top model: $($l.topModel) ($($l.topPct)%)"
        $lines += "Conversations: $(Fmt-Num $l.convos)"
    }
    [System.Windows.Clipboard]::SetText(($lines -join "`n"))
}

$script:window.Add_MouseLeftButtonDown({ try { $script:window.DragMove() } catch { }; Save-State })
$script:window.Add_Loaded({ Position-Window })
$script:window.Add_Closing({ param($s,$e) if (-not $script:ReallyQuit) { $e.Cancel = $true; $script:window.Hide() } })

function Toggle-Window {
    if ($script:window.IsVisible) { $script:window.Hide() }
    else { $script:window.Show(); $script:window.Activate(); $script:window.Topmost = $true }
}

function Quit-App {
    $script:ReallyQuit = $true
    if ($script:pollTimer) { $script:pollTimer.Stop() }
    if ($script:tickTimer) { $script:tickTimer.Stop() }
    if ($script:notify)    { $script:notify.Visible = $false; $script:notify.Dispose() }
    if (Test-Path $script:PidPath) { Remove-Item $script:PidPath -Force -EA SilentlyContinue }
    $script:window.Close()
    $script:window.Dispatcher.InvokeShutdown()
}

# ---------------------------------------------------------------------------
# Right-click menu — dark themed WinForms ContextMenuStrip
# ---------------------------------------------------------------------------
# Called from WinForms click events — accesses $script:window directly in script scope
function Set-CursorOpacity([double]$val, [string]$label) {
    $script:Cfg.Opacity = $val
    $script:PendingOpacity = $val   # DispatcherTimer applies on WPF thread
    Save-State
    foreach ($x in $script:copItems.Values) { $x.Checked = $false }
    if ($script:copItems.ContainsKey($label)) { $script:copItems[$label].Checked = $true }
}

$_sdPath  = [System.Drawing.Color].Assembly.Location
$_swfPath = [System.Windows.Forms.Form].Assembly.Location
Add-Type -ReferencedAssemblies $_sdPath, $_swfPath -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class CursorDarkColorTable : ProfessionalColorTable {
    public override Color MenuItemSelected              { get { return Color.FromArgb(13, 61, 47); } }
    public override Color MenuItemBorder                { get { return Color.FromArgb(52, 211, 153); } }
    public override Color MenuBorder                    { get { return Color.FromArgb(13, 61, 47); } }
    public override Color ToolStripDropDownBackground   { get { return Color.FromArgb(10, 22, 40); } }
    public override Color ImageMarginGradientBegin      { get { return Color.FromArgb(10, 22, 40); } }
    public override Color ImageMarginGradientMiddle     { get { return Color.FromArgb(10, 22, 40); } }
    public override Color ImageMarginGradientEnd        { get { return Color.FromArgb(10, 22, 40); } }
    public override Color CheckBackground               { get { return Color.FromArgb(13, 61, 47); } }
    public override Color CheckSelectedBackground       { get { return Color.FromArgb(52, 211, 153); } }
    public override Color SeparatorDark                 { get { return Color.FromArgb(13, 61, 47); } }
    public override Color SeparatorLight                { get { return Color.FromArgb(10, 22, 40); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(13, 61, 47); } }
    public override Color MenuItemSelectedGradientEnd   { get { return Color.FromArgb(13, 61, 47); } }
    public override Color MenuItemPressedGradientBegin  { get { return Color.FromArgb(52, 211, 153); } }
    public override Color MenuItemPressedGradientEnd    { get { return Color.FromArgb(52, 211, 153); } }
    public override Color MenuStripGradientBegin        { get { return Color.FromArgb(10, 22, 40); } }
    public override Color MenuStripGradientEnd          { get { return Color.FromArgb(10, 22, 40); } }
}
public class CursorMenuRenderer : ToolStripProfessionalRenderer {
    public CursorMenuRenderer() : base(new CursorDarkColorTable()) { RoundedEdges = false; }
}
'@ -EA SilentlyContinue

$menuFg   = [System.Drawing.Color]::FromArgb(209, 250, 229)
$menuBg   = [System.Drawing.Color]::FromArgb(10, 22, 40)
$menuFont = New-Object System.Drawing.Font('Segoe UI', 9.5)

function New-CursorMI([string]$text, [scriptblock]$onClick) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.ForeColor = $menuFg; $mi.BackColor = $menuBg; $mi.Font = $menuFont
    if ($onClick) { $mi.add_Click($onClick) }
    return $mi
}

$script:ctxStrip = New-Object System.Windows.Forms.ContextMenuStrip
try { $script:ctxStrip.Renderer = New-Object CursorMenuRenderer } catch { }
$script:ctxStrip.BackColor = $menuBg; $script:ctxStrip.ForeColor = $menuFg; $script:ctxStrip.Font = $menuFont
$script:ctxStrip.ShowImageMargin = $false

function Add-CSep {
    $sep = New-Object System.Windows.Forms.ToolStripSeparator
    $sep.BackColor = $menuBg; $sep.ForeColor = $menuFg
    [void]$script:ctxStrip.Items.Add($sep)
}

[void]$script:ctxStrip.Items.Add((New-CursorMI 'Refresh now'             { Get-CursorUsage; Get-CursorLocalStats; Update-UI }))
[void]$script:ctxStrip.Items.Add((New-CursorMI 'Copy stats to clipboard' { Copy-Stats }))
[void]$script:ctxStrip.Items.Add((New-CursorMI 'Open Cursor dashboard'   { Start-Process 'https://cursor.com/settings' }))
Add-CSep

$miSnap = New-CursorMI 'Snap to corner' $null
foreach ($pair in @(('Top right','TR'),('Top left','TL'),('Bottom right','BR'),('Bottom left','BL'))) {
    $lbl=$pair[0]; $key=$pair[1]
    [void]$miSnap.DropDownItems.Add((New-CursorMI $lbl ([scriptblock]::Create("Snap-ToCorner '$key'"))))
}
[void]$script:ctxStrip.Items.Add($miSnap)

$miOp = New-CursorMI 'Opacity' $null
$script:copItems = @{}
foreach ($pair in @(('100%',1.0),('80%',0.8),('60%',0.6),('40%',0.4))) {
    $lbl=$pair[0]; $val=$pair[1]
    $sub = New-CursorMI $lbl ([scriptblock]::Create("Set-CursorOpacity $val '$lbl'"))
    $sub.Checked = ([double]$script:Cfg.Opacity -eq [double]$val)
    $script:copItems[$lbl] = $sub
    [void]$miOp.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miOp)

$miTheme = New-CursorMI 'Theme' $null
foreach ($tname in $script:Themes.Keys) {
    $tn = $tname
    $sub = New-CursorMI $tname ([scriptblock]::Create("`$script:Cfg.Theme='$tn'; Apply-CursorTheme '$tn'; Save-State"))
    $sub.CheckOnClick = $false
    $sub.Checked = ($tname -eq $script:Cfg.Theme)
    $script:themeItems[$tname] = $sub
    [void]$miTheme.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miTheme)
Add-CSep

$script:miCLogin = New-CursorMI 'Open at login' {
    if (Test-Autostart) { Uninstall-Autostart } else { Install-Autostart }
    $script:miCLogin.Checked = (Test-Autostart)
}
$script:miCLogin.Checked = (Test-Autostart)
[void]$script:ctxStrip.Items.Add($script:miCLogin)

$cmiSH = New-CursorMI 'Start hidden to tray' {
    $script:Cfg.StartHidden = -not [bool]$script:Cfg.StartHidden; $cmiSH.Checked = [bool]$script:Cfg.StartHidden; Save-State
}
$cmiSH.Checked = [bool]$script:Cfg.StartHidden
[void]$script:ctxStrip.Items.Add($cmiSH)
Add-CSep

[void]$script:ctxStrip.Items.Add((New-CursorMI 'Minimize to tray' { $script:window.Hide() }))
[void]$script:ctxStrip.Items.Add((New-CursorMI 'Quit'             { Quit-App }))

$script:window.Add_MouseRightButtonUp({
    $pt = [System.Windows.Forms.Control]::MousePosition
    $script:ctxStrip.Show($pt.X, $pt.Y)
})

# ---------------------------------------------------------------------------
# Tray icon — Cursor green
# ---------------------------------------------------------------------------
function New-CursorTrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $grd = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 1,1),(New-Object System.Drawing.Point 31,31),
        [System.Drawing.Color]::FromArgb(255,6,95,70),
        [System.Drawing.Color]::FromArgb(255,52,211,153))
    $g.FillEllipse($grd,1,1,30,30)
    $fnt = New-Object System.Drawing.Font('Bahnschrift',13,[System.Drawing.FontStyle]::Bold)
    $sf  = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('Cu',$fnt,[System.Drawing.Brushes]::White,(New-Object System.Drawing.RectangleF(0,0,32,32)),$sf)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon    = New-CursorTrayIcon
$script:notify.Text    = 'Cursor Usage  (L=show  R=menu)'
$script:notify.Visible = $true

# Minimal tray context menu so you can always quit even when panel is hidden
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
try { $trayMenu.Renderer = New-Object CursorMenuRenderer } catch { }
$trayMenu.BackColor = $menuBg; $trayMenu.ForeColor = $menuFg; $trayMenu.Font = $menuFont
$trayMenu.ShowImageMargin = $false
[void]$trayMenu.Items.Add((New-CursorMI 'Show / Hide' { Toggle-Window }))
[void]$trayMenu.Items.Add((New-CursorMI 'Refresh now' { Get-CursorUsage; Get-CursorLocalStats; Update-UI }))
$tSep = New-Object System.Windows.Forms.ToolStripSeparator; $tSep.BackColor=$menuBg
[void]$trayMenu.Items.Add($tSep)
[void]$trayMenu.Items.Add((New-CursorMI 'Quit' { Quit-App }))
$script:notify.ContextMenuStrip = $trayMenu

$script:notify.add_MouseClick({ param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window }
})

# ---------------------------------------------------------------------------
# Timers — poll API every 5 min (less aggressive than Claude's 3 min)
# ---------------------------------------------------------------------------
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromSeconds(300)
$script:pollTimer.add_Tick({ Get-CursorUsage; Get-CursorLocalStats; Update-UI })

$script:tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:tickTimer.Interval = [TimeSpan]::FromSeconds(60)
$script:tickTimer.add_Tick({ Update-UI })   # refreshes reset countdown every minute

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
Log "Loading state"
Load-State
$script:PendingOpacity = [double]$script:Cfg.Opacity   # timer applies this
Apply-CursorTheme $script:Cfg.Theme
Log "Fetching usage"
Get-CursorUsage
Get-CursorLocalStats
Update-UI
$script:opacityTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:opacityTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:opacityTimer.add_Tick({
    if ($null -ne $script:PendingOpacity) {
        try { $script:window.Opacity = [double]$script:PendingOpacity } catch { }
        $script:PendingOpacity = $null
    }
})

$script:pollTimer.Start()
$script:tickTimer.Start()
$script:opacityTimer.Start()

Log "About to show window (Hidden=$Hidden StartHidden=$($script:Cfg.StartHidden))"
if (-not $Hidden -and -not [bool]$script:Cfg.StartHidden) { $script:window.Show() }
Log "Window shown - starting dispatcher"
[System.Windows.Threading.Dispatcher]::Run()
Log "Dispatcher exited"

}
catch {
    $msg = "[{0}] {1}`n{2}" -f (Get-Date -Format 's'), $_.Exception.Message, $_.ScriptStackTrace
    try { Add-Content -Path $script:ErrLog -Value $msg } catch { }
    throw
}
