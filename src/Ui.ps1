# Ui.ps1 - XAML window definition, theme application, bar rendering, sparkline, and UI update loop

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <Window.Resources>
    <LinearGradientBrush x:Key="Divider" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="Transparent" Offset="0"/>
      <GradientStop Color="#38BDF828" Offset="0.25"/>
      <GradientStop Color="#C084FC28" Offset="0.75"/>
      <GradientStop Color="Transparent" Offset="1"/>
    </LinearGradientBrush>
  </Window.Resources>

  <Grid Margin="12">
  <Border x:Name="mainBorder" BorderThickness="1" CornerRadius="16" ClipToBounds="True">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="16" Opacity="0.5" ShadowDepth="0"/>
    </Border.Effect>
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
        <GradientStop Color="#FF0F172A" Offset="0"/>
        <GradientStop Color="#FF0B1220" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.BorderBrush>
      <SolidColorBrush Color="#FF1E3A5F"/>
    </Border.BorderBrush>
    <DockPanel>

      <!-- Rainbow accent stripe - CornerRadius matches outer border (16-1=15) -->
      <Border x:Name="accentStripe" DockPanel.Dock="Top" Height="5" CornerRadius="15,15,0,0">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#38BDF8" Offset="0"/>
            <GradientStop Color="#818CF8" Offset="0.33"/>
            <GradientStop Color="#E879F9" Offset="0.66"/>
            <GradientStop Color="#FB923C" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>

      <StackPanel Margin="14,9,14,13" Width="250">

        <!-- Header -->
        <Grid Margin="0,0,0,11">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#4ADE80"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Foreground="#6B8FAF" FontSize="12" FontFamily="Bahnschrift SemiBold" Text="CLAUDE "/>
            <TextBlock Foreground="#E2E8F0" FontSize="12" FontFamily="Bahnschrift SemiBold" Text="USAGE"/>
          </StackPanel>
          <TextBlock x:Name="timeText" Grid.Column="1" Text=""
                     Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
        </Grid>

        <!-- 5h metric - bar = remaining capacity -->
        <StackPanel Margin="0,0,0,10">
          <Grid Margin="0,0,0,3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Bottom">
              <TextBlock x:Name="fivehLabel" Text="5-HOUR SESSION"
                         Foreground="#38BDF8" FontSize="10" FontFamily="Bahnschrift SemiBold"/>
            </StackPanel>
            <TextBlock Grid.Column="1" x:Name="fivehPct" Text="--" Foreground="#F1F5F9"
                       FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
            <TextBlock Grid.Column="2" x:Name="fivehReset" Text=""
                       Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas"
                       VerticalAlignment="Bottom" Margin="0,0,0,2"/>
          </Grid>
          <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
            <Border x:Name="fivehBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#0369A1" Offset="0"/>
                  <GradientStop Color="#38BDF8" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Border>
          <TextBlock x:Name="fivehSub" Text="used" Foreground="#5C7A96"
                     FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
        </StackPanel>

        <!-- Weekly metric -->
        <StackPanel Margin="0,0,0,10">
          <Grid Margin="0,0,0,3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="weekLabel" Grid.Column="0" Text="WEEKLY LIMIT"
                       Foreground="#FB923C" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
            <TextBlock Grid.Column="1" x:Name="weekPct" Text="--" Foreground="#F1F5F9"
                       FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
            <TextBlock Grid.Column="2" x:Name="weekReset" Text=""
                       Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas"
                       VerticalAlignment="Bottom" Margin="0,0,0,2"/>
          </Grid>
          <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
            <Border x:Name="weekBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#C2410C" Offset="0"/>
                  <GradientStop Color="#FB923C" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Border>
          <TextBlock x:Name="weekSub" Text="used" Foreground="#5C7A96"
                     FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
        </StackPanel>

        <!-- Fable metric -->
        <StackPanel Margin="0,0,0,7">
          <Grid Margin="0,0,0,3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="fabLabel" Grid.Column="0" Text="FABLE WEEKLY"
                       Foreground="#C084FC" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
            <TextBlock Grid.Column="1" x:Name="fabPct" Text="--" Foreground="#F1F5F9"
                       FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
            <TextBlock Grid.Column="2" x:Name="fabReset" Text=""
                       Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas"
                       VerticalAlignment="Bottom" Margin="0,0,0,2"/>
          </Grid>
          <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
            <Border x:Name="fabBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#6D28D9" Offset="0"/>
                  <GradientStop Color="#C084FC" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Border>
          <TextBlock x:Name="fabSub" Text="used" Foreground="#5C7A96"
                     FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
        </StackPanel>

        <!-- Opus metric (collapsed unless used) -->
        <StackPanel x:Name="opusRow" Margin="0,0,0,7" Visibility="Collapsed">
          <Grid Margin="0,0,0,3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="opusLabel" Grid.Column="0" Text="OPUS WEEKLY"
                       Foreground="#FDE047" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
            <TextBlock Grid.Column="1" x:Name="opusPct" Text="--" Foreground="#F1F5F9"
                       FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
            <TextBlock Grid.Column="2" x:Name="opusReset" Text=""
                       Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas"
                       VerticalAlignment="Bottom" Margin="0,0,0,2"/>
          </Grid>
          <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
            <Border x:Name="opusBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#92400E" Offset="0"/>
                  <GradientStop Color="#FDE047" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Border>
          <TextBlock x:Name="opusSub" Text="used" Foreground="#5C7A96"
                     FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
        </StackPanel>

        <!-- Sparkline history graphs (collapsed unless ShowGraph is enabled) -->
        <StackPanel x:Name="sparkRow" Visibility="Collapsed" Margin="0,4,0,0">
          <Canvas x:Name="fivehSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left" Margin="0,0,0,3">
            <Polyline x:Name="fivehSpark" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
          </Canvas>
          <Canvas x:Name="weekSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
            <Polyline x:Name="weekSpark" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
          </Canvas>
        </StackPanel>

        <!-- Divider -->
        <Border Height="1" Background="{StaticResource Divider}" Margin="0,4,0,8"/>

        <!-- Stats -->
        <StackPanel x:Name="statsPanel">
          <Grid Margin="0,0,0,2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="EST. COST" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"
                       ToolTip="API-equivalent value of all usage (not a real charge on flat-rate plans)"/>
            <TextBlock Grid.Column="1" x:Name="valText" Text="--" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas"/>
          </Grid>
          <Grid x:Name="extraRow" Margin="0,0,0,2" Visibility="Collapsed">
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="OVERAGE" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"
                       ToolTip="Real spend beyond your plan this month"/>
            <TextBlock Grid.Column="1" x:Name="extraVal" Text="" Foreground="#FBB740" FontSize="11" FontFamily="Consolas"/>
          </Grid>
          <Grid Margin="0,0,0,2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="TOKENS" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"
                       ToolTip="All-time input / output tokens"/>
            <TextBlock Grid.Column="1" x:Name="tokText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
          </Grid>
          <Grid Margin="0,0,0,2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="TODAY" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"
                       ToolTip="Today's tokens and messages (refreshed by Claude Code periodically)"/>
            <TextBlock Grid.Column="1" x:Name="todayText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
          </Grid>
          <Grid Margin="0,0,0,2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="AFTER HRS" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"
                       ToolTip="Today's usage outside configured work hours"/>
            <TextBlock Grid.Column="1" x:Name="afterHoursText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
          </Grid>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="LIFETIME" Foreground="#7BA8C8"
                       FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="lifeText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
          </Grid>
        </StackPanel>

        <!-- Footer divider -->
        <Border Height="1" Background="{StaticResource Divider}" Margin="0,6,0,8"/>

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

# $xaml is consumed by overlay.ps1 after dot-sourcing this module.
# The window is created there (one instance only).

# ---------------------------------------------------------------------------
# Theme application
# ---------------------------------------------------------------------------
function Apply-Theme([string]$name) {
    $t = $script:Themes[$name]
    if (-not $t) { return }

    # Main panel background and border
    $mb = $script:window.FindName('mainBorder')
    if ($mb -and $t.BgC1) {
        $bgb = New-GradientBrush2 $t.BgC1 $t.BgC2
        $mb.Background  = $bgb
        $mb.BorderBrush = NewBrush $t.BorderC1
    }

    $brand = $script:window.FindName('brandLabel')
    if ($brand -and $t.BrandLabelFg) { $brand.Foreground = NewBrush $t.BrandLabelFg }
    $bp = $script:window.FindName('brandPath')
    if ($bp -and $t.BrandLabelFg) { $bp.Fill = NewBrush $t.BrandLabelFg }

    $bars   = @('fivehBar','weekBar','fabBar','opusBar')
    $labels = @('fivehLabel','weekLabel','fabLabel','opusLabel')
    $subs   = @('fivehSub','weekSub','fabSub','opusSub')
    $fgKeys = @('FivehFg','WeekFg','FabFg','OpusFg')
    $bgKeys = @('FivehColors','WeekColors','FabColors','OpusColors')

    for ($i = 0; $i -lt $bars.Count; $i++) {
        $b = $script:window.FindName($bars[$i])
        if ($b) { $b.Background = New-GradientBrush $t[$bgKeys[$i]][0] $t[$bgKeys[$i]][1] }
        $l = $script:window.FindName($labels[$i])
        if ($l) { $l.Foreground = NewBrush $t[$fgKeys[$i]] }
        $s = $script:window.FindName($subs[$i])
        if ($s) { $s.Foreground = NewBrush ($t[$fgKeys[$i]] + '55') }
    }

    # Update the rainbow stripe
    $stripe = $script:window.FindName('accentStripe')
    if ($stripe) {
        $gb = New-Object System.Windows.Media.LinearGradientBrush
        $gb.StartPoint = [System.Windows.Point]::new(0,0)
        $gb.EndPoint   = [System.Windows.Point]::new(1,0)
        $offsets = @(0, 0.33, 0.66, 1)
        for ($i = 0; $i -lt 4; $i++) {
            $gs = New-Object System.Windows.Media.GradientStop
            $gs.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($t.Stripe[$i])
            $gs.Offset = $offsets[$i]
            [void]$gb.GradientStops.Add($gs)
        }
        $stripe.Background = $gb
    }

    # Update spark Polyline stroke colors to match theme
    $fivehSpark = $script:window.FindName('fivehSpark')
    if ($fivehSpark) { $fivehSpark.Stroke = NewBrush $t.FivehFg }
    $weekSpark = $script:window.FindName('weekSpark')
    if ($weekSpark) { $weekSpark.Stroke = NewBrush $t.WeekFg }

    # Sync checkmarks on theme menu items (WinForms: .Checked not .IsChecked)
    if ($script:themeItems) {
        foreach ($kv in $script:themeItems.GetEnumerator()) {
            $kv.Value.Checked = ($kv.Key -eq $name)
        }
    }
}

# ---------------------------------------------------------------------------
# Set-Bar - shows REMAINING capacity (100 - utilisation)
# Bar width: full = 100% remaining, empty = 0% remaining
# ---------------------------------------------------------------------------
function Set-Bar([string]$bar, [string]$pct, [string]$sub, [string]$reset, $util, $resetsAt) {
    $b  = $script:window.FindName($bar)
    $p  = $script:window.FindName($pct)
    $sb = if ($sub)   { $script:window.FindName($sub)   } else { $null }
    $r  = if ($reset) { $script:window.FindName($reset) } else { $null }
    if ($null -eq $util) {
        $b.Width = 0; $p.Text = '--'; $p.Foreground = NewBrush '#F1F5F9'
        if ($sb) { $sb.Text = 'used' }
        if ($r)  { $r.Text  = '' }
        return
    }
    $u        = [double]$util
    $b.Width  = [math]::Max(0, [math]::Min($script:BarTrackWidth, [math]::Round($u / 100.0 * $script:BarTrackWidth)))
    $p.Text   = ('{0:0}%' -f $u)
    $fg = if ($u -ge $script:CritPct) { '#F87171' } elseif ($u -ge $script:WarnPct) { '#FBBF24' } else { '#F1F5F9' }
    $p.Foreground = NewBrush $fg
    if ($sb) { $sb.Text = if ($u -ge $script:CritPct) { 'critical!' } elseif ($u -ge $script:WarnPct) { 'high' } else { 'used' } }
    if ($r)  { $r.Text  = Format-Reset $resetsAt }
}

# ---------------------------------------------------------------------------
# Set-Spark - renders a sparkline polyline onto a named Canvas
# ---------------------------------------------------------------------------
function Set-Spark([string]$sparkName, [string]$canvasName, [string]$metricKey) {
    $spark  = $script:window.FindName($sparkName)
    $canvas = $script:window.FindName($canvasName)
    if (-not $spark -or -not $canvas) { return }
    $spark.Points.Clear()

    $samples = $script:History
    if ($null -eq $samples -or $samples.Count -lt 2) { return }

    # Filter to samples with a value for this metric
    $valid = @($samples | Where-Object { $null -ne $_.$metricKey })
    if ($valid.Count -lt 2) { return }

    # X: time range; Y: utilization 0-100 mapped to canvas height (inverted: 0% at bottom, 100% at top)
    $w = $canvas.Width
    $h = $canvas.Height

    $t0 = [System.DateTimeOffset]::Parse($valid[0].t)
    $t1 = [System.DateTimeOffset]::Parse($valid[-1].t)
    $tRange = ($t1 - $t0).TotalSeconds
    if ($tRange -le 0) { return }

    foreach ($s in $valid) {
        $tSec = ([System.DateTimeOffset]::Parse($s.t) - $t0).TotalSeconds
        $x = [double]($tSec / $tRange) * $w
        $y = $h - ([math]::Max(0, [math]::Min(100, [double]($s.$metricKey))) / 100.0 * $h)  # invert; clamp 0-100
        [void]$spark.Points.Add([System.Windows.Point]::new($x, $y))
    }
}

# ---------------------------------------------------------------------------
# Update-UI
# ---------------------------------------------------------------------------
function Update-UI {
    $dot  = $script:window.FindName('statusDot')
    $time = $script:window.FindName('timeText')

    switch ($script:State.Status) {
        'ok'    { $dot.Fill = NewBrush '#4ADE80' }
        'stale' { $dot.Fill = NewBrush '#FBBF24' }
        'auth'  { $dot.Fill = NewBrush '#F87171' }
        'error' { $dot.Fill = NewBrush '#F87171' }
        default { $dot.Fill = NewBrush '#4B6A8A' }
    }

    $s = $script:Stats
    if ($s) {
        $script:window.FindName('valText').Text   = ('~{0} all-time' -f (Fmt-Money $s.ValueUSD))
        $script:window.FindName('tokText').Text   = ('{0} in / {1} out' -f (Fmt-Tok $s.InTokens), (Fmt-Tok $s.OutTokens))
        $script:window.FindName('todayText').Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayTok), $s.TodayMsg)
        $afterHoursText = $script:window.FindName('afterHoursText')
        if ($afterHoursText) { $afterHoursText.Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayAfterHoursTok), $s.TodayAfterHoursMsg) }
        $script:window.FindName('lifeText').Text  = ('{0} sessions  {1} msgs' -f $s.Sessions, (Fmt-Tok $s.Messages))
        $script:window.FindName('statsPanel').ToolTip = ('Cache last updated: {0}  |  Prices as of {1}' -f $s.LastComputed, $script:PricesAsOf)
    }

    $d = $script:State.Data
    if ($null -eq $d) {
        Set-Bar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $null $null
        Set-Bar 'weekBar'  'weekPct'  'weekSub'  'weekReset'  $null $null
        Set-Bar 'fabBar'   'fabPct'   'fabSub'   'fabReset'   $null $null
        $time.Text = if ($script:State.Message) { $script:State.Message } else { 'connecting...' }
        return
    }

    $hasAlert = [bool](Get-Command Check-Alert -ErrorAction SilentlyContinue)

    Set-Bar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $d.five_hour.utilization        $d.five_hour.resets_at
    Set-Spark 'fivehSpark' 'fivehSparkCanvas' 'five_hour'
    if ($hasAlert) { Check-Alert 'five_hour' $d.five_hour.utilization }

    Set-Bar 'weekBar'  'weekPct'  'weekSub'  'weekReset'  $d.seven_day.utilization         $d.seven_day.resets_at
    Set-Spark 'weekSpark' 'weekSparkCanvas' 'seven_day'
    if ($hasAlert) { Check-Alert 'seven_day' $d.seven_day.utilization }

    Set-Bar 'fabBar'   'fabPct'   'fabSub'   'fabReset'   $d.seven_day_fable.utilization   $d.seven_day_fable.resets_at
    if ($hasAlert) { Check-Alert 'seven_day_fable' $d.seven_day_fable.utilization }

    if ($d.seven_day_opus) {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Visible
        Set-Bar 'opusBar' 'opusPct' 'opusSub' 'opusReset' $d.seven_day_opus.utilization $d.seven_day_opus.resets_at
        if ($hasAlert) { Check-Alert 'seven_day_opus' $d.seven_day_opus.utilization }
    } else {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Collapsed
    }

    $ex = $d.extra_usage
    if ($ex -and $ex.is_enabled -and $ex.monthly_limit) {
        $sym   = if ($ex.currency -eq 'USD') { '$' } else { "$($ex.currency) " }
        $used  = [double]$ex.used_credits  / 100.0
        $limit = [double]$ex.monthly_limit / 100.0
        $script:window.FindName('extraRow').Visibility = [System.Windows.Visibility]::Visible
        $script:window.FindName('extraVal').Text = ('{0}{1:N2} / {0}{2:N0}' -f $sym, $used, $limit)
    } else {
        $script:window.FindName('extraRow').Visibility = [System.Windows.Visibility]::Collapsed
    }

    $time.Text = if ($script:State.Status -eq 'ok') { $script:State.LastFetch } else { $script:State.Message }
    if ($script:notify) {
        $script:notify.Text = ('Claude  5h {0:0}%  Wk {1:0}%' -f [double]$d.five_hour.utilization, [double]$d.seven_day.utilization)
    }
}
