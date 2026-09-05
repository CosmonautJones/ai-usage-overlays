# Shell.ps1 - unified accordion window: XAML, theme application, animated section
# toggle, and per-section render functions. The single window for the unified overlay.
#
# Consumes (speculative - defined by other legs / Claude modules):
#   $script:Themes (Leg F), $script:State/$script:Stats/$script:BarTrackWidth/$script:WarnPct/
#   $script:CritPct + Fmt-Tok/Fmt-Money/Format-Reset/NewBrush/New-GradientBrush/New-GradientBrush2
#   (Claude modules), $script:CodexStats (Leg A), $script:LiveData/$script:LocalData/
#   $script:SummaryData/$script:AuthState/$script:CursorErrMsg/$script:CursorLastFetch/Fmt-Num
#   (Leg B), $script:window/Save-UnifiedState (Leg E).

# ---------------------------------------------------------------------------
# XAML - merged accordion window (Claude / Codex / Cursor sections)
# Every x:Name is globally unique: Claude keeps its Ui.ps1 names; Codex names are
# codex*; Cursor dup names become cursor*.
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="root"
        Title="AI Usage" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="Manual" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <Window.Resources>
    <LinearGradientBrush x:Key="Divider" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="Transparent" Offset="0"/>
      <GradientStop Color="#38BDF828" Offset="0.25"/>
      <GradientStop Color="#C084FC28" Offset="0.75"/>
      <GradientStop Color="Transparent" Offset="1"/>
    </LinearGradientBrush>
  </Window.Resources>

  <Grid>
  <!-- ============================================================
       Quake view: a full-width terminal strip. Deliberately plain -
       monospace text, block-character gauges, no rounded corners or
       gradients - so it reads as a console, not as a widget. Content is
       built as coloured Runs from PowerShell (see QuakeView.ps1).
       ============================================================ -->
  <Border x:Name="quakeRoot" Visibility="Collapsed" BorderThickness="0,1,0,1"
          Background="#F00A0E14" BorderBrush="#FF1E3A5F">
    <Grid Margin="10,6,10,7">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="qHeader" Grid.Row="0" FontFamily="Consolas" FontSize="12"
                 Foreground="#7B9EC4" TextWrapping="NoWrap" Margin="0,0,0,4"/>
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="qClaude" Grid.Column="0" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="1" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qCodex" Grid.Column="2" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="3" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qCursor" Grid.Column="4" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="5" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qGrok" Grid.Column="6" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
      </Grid>
      <TextBlock x:Name="qFooter" Grid.Row="2" FontFamily="Consolas" FontSize="11"
                 Foreground="#4B6A8A" TextWrapping="NoWrap" Margin="0,5,0,0"/>
    </Grid>
  </Border>

  <Grid x:Name="pinnedRoot" Margin="12">
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

        <!-- Chrome header -->
        <Grid Margin="0,0,0,11">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#4ADE80"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Foreground="#6B8FAF" FontSize="12" FontFamily="Bahnschrift SemiBold" Text="AI "/>
            <TextBlock Foreground="#E2E8F0" FontSize="12" FontFamily="Bahnschrift SemiBold" Text="USAGE"/>
          </StackPanel>
          <TextBlock x:Name="timeText" Grid.Column="1" Text=""
                     Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
        </Grid>

        <!-- ============ CLAUDE SECTION ============ -->
        <StackPanel x:Name="claudeSection" Margin="0,0,0,4">
          <Border x:Name="claudeHeader" Background="#11FFFFFF" CornerRadius="6"
                  Padding="7,5" Margin="0,0,0,6" Cursor="Hand">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="claudeChevron" Grid.Column="0" Text="v"
                         Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Grid.Column="1" Text="CLAUDE" Foreground="#E2E8F0"
                         FontSize="12" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="claudeHeaderDetail" Grid.Column="2" Text="" Foreground="#7B9EC4"
                         FontSize="10" FontFamily="Consolas" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
          </Border>

          <StackPanel x:Name="claudeBody">

           <StackPanel x:Name="claudeFull">

            <!-- 5h metric -->
            <StackPanel Margin="0,0,0,10">
              <Grid Margin="0,0,0,3">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="fivehLabel" Grid.Column="0" Text="5-HOUR SESSION"
                           Foreground="#38BDF8" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="fivehPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="fivehReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="fivehBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/>
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
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="weekLabel" Grid.Column="0" Text="WEEKLY LIMIT"
                           Foreground="#FB923C" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="weekPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="weekReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="weekBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/>
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
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="fabLabel" Grid.Column="0" Text="FABLE WEEKLY"
                           Foreground="#C084FC" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="fabPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="fabReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="fabBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#6D28D9" Offset="0"/><GradientStop Color="#C084FC" Offset="1"/>
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
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="opusLabel" Grid.Column="0" Text="OPUS WEEKLY"
                           Foreground="#FDE047" FontSize="8" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="opusPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="opusReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="opusBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#92400E" Offset="0"/><GradientStop Color="#FDE047" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                </Border>
              </Border>
              <TextBlock x:Name="opusSub" Text="used" Foreground="#5C7A96"
                         FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
            </StackPanel>

            <StackPanel x:Name="fivehSparkRow" Visibility="Collapsed" Margin="0,2,0,6">
              <Canvas x:Name="fivehSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                <Polyline x:Name="fivehSpark" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            <StackPanel x:Name="weekSparkRow" Visibility="Collapsed" Margin="0,2,0,6">
              <Canvas x:Name="weekSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                <Polyline x:Name="weekSpark" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>

            <Border Height="1" Background="{StaticResource Divider}" Margin="0,4,0,8"/>

            <!-- Stats -->
            <StackPanel x:Name="statsPanel">
              <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="ACCOUNT" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="claudeIdentityText" Text="--" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas"
                           TextTrimming="CharacterEllipsis"/>
              </Grid>
              <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="EST. COST" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="valText" Text="--" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas"/>
              </Grid>
              <Grid x:Name="extraRow" Margin="0,0,0,2" Visibility="Collapsed">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="OVERAGE" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="extraVal" Text="" Foreground="#FBB740" FontSize="11" FontFamily="Consolas"/>
              </Grid>
              <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="TOKENS" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="tokText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
              </Grid>
              <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="TODAY" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="todayText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
              </Grid>
              <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="AFTER HRS" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="afterHoursText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
              </Grid>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="LIFETIME" Foreground="#7BA8C8"
                           FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="lifeText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
              </Grid>
            </StackPanel>
           </StackPanel>
           <!-- ===== CLAUDE compact (single-line) ===== -->
           <StackPanel x:Name="claudeCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="fivehLabelC" Text="5-HOUR" Foreground="#38BDF8" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="fivehBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="fivehPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="fivehSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="fivehSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="fivehSparkC" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="weekLabelC" Text="WEEKLY" Foreground="#FB923C" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="weekBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="weekPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="weekSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="weekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="weekSparkC" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="fabLabelC" Text="FABLE" Foreground="#C084FC" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="fabBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#6D28D9" Offset="0"/><GradientStop Color="#C084FC" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="fabPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <Grid x:Name="opusRowC" Margin="0,0,0,7" Visibility="Collapsed">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="opusLabelC" Text="OPUS" Foreground="#FDE047" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="opusBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#92400E" Offset="0"/><GradientStop Color="#FDE047" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="opusPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
           </StackPanel>
          </StackPanel>
        </StackPanel>

        <!-- ============ CODEX SECTION ============ -->
        <StackPanel x:Name="codexSection" Margin="0,0,0,4">
          <Border x:Name="codexHeader" Background="#11FFFFFF" CornerRadius="6"
                  Padding="7,5" Margin="0,0,0,6" Cursor="Hand">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="codexChevron" Grid.Column="0" Text="v"
                         Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Grid.Column="1" Text="CODEX" Foreground="#E2E8F0"
                         FontSize="12" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="codexHeaderDetail" Grid.Column="2" Text="" Foreground="#7B9EC4"
                         FontSize="10" FontFamily="Consolas" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
          </Border>

          <StackPanel x:Name="codexBody">
           <StackPanel x:Name="codexFull">
            <!-- Auth trouble the user must act on (expired login). Collapsed when healthy. -->
            <TextBlock x:Name="codexErrText" Text="" Foreground="#F87171"
                       FontSize="11" FontFamily="Bahnschrift SemiBold"
                       TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
            <!-- 5-HOUR metric (hidden unless FiveHourPct is present) -->
            <StackPanel x:Name="codexFivehRow" Margin="0,0,0,10" Visibility="Collapsed">
              <Grid Margin="0,0,0,3">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="codexFivehLabel" Grid.Column="0" Text="5-HOUR"
                           Foreground="#38BDF8" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="codexFivehPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="codexFivehReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="codexFivehBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                </Border>
              </Border>
              <TextBlock x:Name="codexFivehSub" Text="used" Foreground="#5C7A96"
                         FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
              <StackPanel x:Name="codexFivehSparkRow" Visibility="Collapsed" Margin="0,2,0,0">
                <Canvas x:Name="codexFivehSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                  <Polyline x:Name="codexFivehSpark" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                </Canvas>
              </StackPanel>
            </StackPanel>
            <!-- Weekly metric (Codex now exposes a single weekly limit) -->
            <StackPanel Margin="0,0,0,10">
              <Grid Margin="0,0,0,3">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="codexWeekLabel" Grid.Column="0" Text="WEEKLY"
                           Foreground="#FB923C" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="codexWeekPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="codexWeekReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="codexWeekBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                </Border>
              </Border>
              <TextBlock x:Name="codexWeekSub" Text="used" Foreground="#5C7A96"
                         FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
              <StackPanel x:Name="codexWeekSparkRow" Visibility="Collapsed" Margin="0,2,0,0">
                <Canvas x:Name="codexWeekSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                  <Polyline x:Name="codexWeekSpark" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                </Canvas>
              </StackPanel>
            </StackPanel>

            <Grid x:Name="codexResetsRow" Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="RESETS" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexResetsText" Text="--" Foreground="#4ADE80" FontSize="12" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="EST. COST" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexValText" Text="--" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="TOKENS" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexTokText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="TODAY" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexTodayText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="AFTER HRS" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexAfterHoursText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="LIFETIME" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="codexSessText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
           </StackPanel>
           <!-- ===== CODEX compact (single-line) ===== -->
           <StackPanel x:Name="codexCompact" Visibility="Collapsed">
            <StackPanel x:Name="codexFivehRowC" Visibility="Collapsed">
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="codexFivehLabelC" Text="5-HOUR" Foreground="#38BDF8" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="codexFivehBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="codexFivehPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="codexFivehSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="codexFivehSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="codexFivehSparkC" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            </StackPanel>
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="codexWeekLabelC" Text="WEEKLY" Foreground="#FB923C" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="codexWeekBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="codexWeekPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="codexWeekSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="codexWeekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="codexWeekSparkC" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
        </StackPanel>

        <!-- ============ CURSOR SECTION ============ -->
        <StackPanel x:Name="cursorSection" Margin="0,0,0,4">
          <Border x:Name="cursorHeader" Background="#11FFFFFF" CornerRadius="6"
                  Padding="7,5" Margin="0,0,0,6" Cursor="Hand">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="cursorChevron" Grid.Column="0" Text="v"
                         Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Grid.Column="1" Text="CURSOR" Foreground="#E2E8F0"
                         FontSize="12" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="cursorHeaderDetail" Grid.Column="2" Text="" Foreground="#7B9EC4"
                         FontSize="10" FontFamily="Consolas" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
          </Border>

          <StackPanel x:Name="cursorBody">
           <StackPanel x:Name="cursorFull">

            <!-- Cursor Models (plan %) — primary, Codex-style -->
            <StackPanel Margin="0,0,0,10">
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="reqLabel" Grid.Column="0" Text="CURSOR MODELS"
                           Foreground="#34D399" FontSize="11" FontFamily="Bahnschrift SemiBold"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Border x:Name="overPill" Grid.Column="1" Background="#1F1800"
                        BorderBrush="#FBBF24" BorderThickness="1" CornerRadius="3"
                        Padding="3,1,3,1" VerticalAlignment="Center" HorizontalAlignment="Left" Visibility="Collapsed">
                  <TextBlock Text="over" Foreground="#FBBF24" FontSize="9" FontFamily="Bahnschrift SemiBold"/>
                </Border>
                <TextBlock x:Name="reqReset" Grid.Column="2" Text=""
                           Foreground="#7EC4A6" FontSize="10" FontFamily="Consolas" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="reqCountLabel" Grid.Column="0" Text="Plan"
                           Foreground="#7EC4A6" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                <TextBlock x:Name="reqCount" Grid.Column="1" Text="-- / --"
                           Foreground="#6EE7B7" FontSize="12" FontFamily="Bahnschrift Bold" VerticalAlignment="Center"/>
              </Grid>
              <Border x:Name="barTrack" Height="6" CornerRadius="3" Background="#0E2018" Width="250" HorizontalAlignment="Left">
                <Border x:Name="reqBar" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#065F46" Offset="0"/><GradientStop Color="#34D399" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                </Border>
              </Border>
              <StackPanel x:Name="cursorReqSparkRow" Visibility="Collapsed" Margin="0,4,0,0">
                <Canvas x:Name="cursorReqSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                  <Polyline x:Name="cursorReqSpark" Stroke="#34D399" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                </Canvas>
              </StackPanel>
            </StackPanel>

            <!-- Other Models (API / named) from usage-summary -->
            <StackPanel x:Name="otherModelsRow" Margin="0,0,0,10">
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="otherModelsLabel" Grid.Column="0" Text="OTHER MODELS"
                           Foreground="#34D399" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock x:Name="otherModelsText" Grid.Column="1" Text="--"
                           Foreground="#6EE7B7" FontSize="12" FontFamily="Bahnschrift Bold" VerticalAlignment="Center"/>
              </Grid>
            </StackPanel>

            <!-- Local analytics (hidden when get-user-analytics / LocalData is null) -->

            <!-- On-demand secondary (Off / $) — not the hero when plan matters -->
            <StackPanel x:Name="onDemandRow" Margin="0,0,0,10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="onDemandLabel" Grid.Column="0" Text="ON-DEMAND"
                           Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
                <TextBlock x:Name="onDemandText" Grid.Column="1" Text="--"
                           Foreground="#5B9A80" FontSize="12" FontFamily="Bahnschrift Bold" VerticalAlignment="Center"/>
              </Grid>
            </StackPanel>

            <StackPanel x:Name="cursorAnalyticsBlock" Visibility="Collapsed">
            <Grid Margin="0,0,0,5">
              <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="editsLabel" Grid.Column="0" Text="AGENT EDITS"
                         Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="editsText" Grid.Column="1" Text="--" Foreground="#6EE7B7" FontSize="14" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,5">
              <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="cursorTodayLabel" Grid.Column="0" Text="TODAY"
                         Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="cursorTodayText" Grid.Column="1" Text="--" Foreground="#6EE7B7" FontSize="14" FontFamily="Consolas"/>
            </Grid>
            <Grid Margin="0,0,0,5">
              <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="cursorModelLabel" Grid.Column="0" Text="TOP MODEL"
                         Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="cursorModelText" Grid.Column="1" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="cursorSessLabel" Grid.Column="0" Text="AI LINES"
                         Foreground="#7EC4A6" FontSize="11" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="cursorSessText" Grid.Column="1" Text="--" Foreground="#94A3B8" FontSize="14" FontFamily="Consolas"/>
            </Grid>
            </StackPanel>
           </StackPanel>
           <!-- ===== CURSOR compact (single-line) ===== -->
           <StackPanel x:Name="cursorCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="reqLabelC" Text="MODELS" Foreground="#34D399" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#0E2018" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="reqBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#065F46" Offset="0"/><GradientStop Color="#34D399" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="reqCountC" Text="--" Foreground="#6EE7B7" FontSize="12" FontFamily="Bahnschrift Bold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="otherModelsLabelC" Text="OTHER" Foreground="#34D399" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="otherModelsTextC" Text="--" Foreground="#6EE7B7" FontSize="12" FontFamily="Bahnschrift Bold" VerticalAlignment="Center" HorizontalAlignment="Right"/>
            </Grid>
            <StackPanel x:Name="cursorReqSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="cursorReqSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="cursorReqSparkC" Stroke="#34D399" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
        </StackPanel>


        <!-- ============ GROK SECTION ============ -->
        <StackPanel x:Name="grokSection" Margin="0,0,0,4">
          <Border x:Name="grokHeader" Background="#11FFFFFF" CornerRadius="6"
                  Padding="7,5" Margin="0,0,0,6" Cursor="Hand">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="grokChevron" Grid.Column="0" Text="v"
                         Foreground="#7B9EC4" FontSize="11" FontFamily="Consolas"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Grid.Column="1" Text="GROK" Foreground="#E2E8F0"
                         FontSize="12" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="grokHeaderDetail" Grid.Column="2" Text="" Foreground="#7B9EC4"
                         FontSize="10" FontFamily="Consolas" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
          </Border>

          <StackPanel x:Name="grokBody">
           <StackPanel x:Name="grokFull">
            <TextBlock x:Name="grokErrText" Text="" Foreground="#F87171"
                       FontSize="11" FontFamily="Bahnschrift SemiBold"
                       TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
            <StackPanel Margin="0,0,0,10">
              <Grid Margin="0,0,0,3">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="grokWeekLabel" Grid.Column="0" Text="WEEKLY"
                           Foreground="#FDE68A" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Bottom"/>
                <TextBlock Grid.Column="1" x:Name="grokWeekPct" Text="--" Foreground="#F1F5F9"
                           FontSize="20" FontFamily="Bahnschrift Bold" VerticalAlignment="Bottom" Margin="0,0,4,0"/>
                <TextBlock Grid.Column="2" x:Name="grokWeekReset" Text=""
                           Foreground="#7BA8C8" FontSize="10" FontFamily="Consolas" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
              </Grid>
              <Border Height="7" CornerRadius="3.5" Background="#131F33" Width="250" HorizontalAlignment="Left">
                <Border x:Name="grokWeekBar" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="250">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#A16207" Offset="0"/><GradientStop Color="#FDE68A" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                </Border>
              </Border>
              <TextBlock x:Name="grokWeekSub" Text="used" Foreground="#5C7A96"
                         FontSize="9" FontFamily="Bahnschrift SemiBold" Margin="0,1,0,0"/>
              <StackPanel x:Name="grokWeekSparkRow" Visibility="Collapsed" Margin="0,2,0,0">
                <Canvas x:Name="grokWeekSparkCanvas" Width="250" Height="14" HorizontalAlignment="Left">
                  <Polyline x:Name="grokWeekSpark" Stroke="#FDE68A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                </Canvas>
              </StackPanel>
            </StackPanel>
            <Grid Margin="0,0,0,2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="USAGE" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="grokPlanText" Text="--" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas" TextWrapping="Wrap"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="PREPAID" Foreground="#7BA8C8"
                         FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="grokPrepaidText" Text="--" Foreground="#94A3B8" FontSize="12" FontFamily="Consolas"/>
            </Grid>
           </StackPanel>
           <StackPanel x:Name="grokCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,7">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="50"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="grokWeekLabelC" Text="WEEKLY" Foreground="#FDE68A" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="7" CornerRadius="3.5" Background="#131F33" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="grokWeekBarC" Height="7" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#A16207" Offset="0"/><GradientStop Color="#FDE68A" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="grokWeekPctC" Text="--" Foreground="#F1F5F9" FontSize="13" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="grokWeekSparkRowC" Visibility="Collapsed" Margin="0,0,0,7">
              <Canvas x:Name="grokWeekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="50,0,0,0">
                <Polyline x:Name="grokWeekSparkC" Stroke="#FDE68A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
        </StackPanel>

        <!-- Footer divider -->
        <Border Height="1" Background="{StaticResource Divider}" Margin="0,6,0,8"/>

        <!-- TravOS footer -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid Width="18" Height="18" Margin="0,0,7,0" VerticalAlignment="Center">
            <Viewbox x:Name="brandMarkBox" Stretch="Uniform">
              <Canvas Width="32" Height="32">
                <Path x:Name="brandPath" Fill="#5C8AAA"
                      Data="M6,6 H26 V10 H18 V26 H14 V10 H6 Z"/>
              </Canvas>
            </Viewbox>
            <Image x:Name="brandMarkImage" Stretch="Uniform" Visibility="Collapsed"/>
          </Grid>
          <TextBlock x:Name="brandLabel" Grid.Column="1" Text="TravOS"
                     Foreground="#5C8AAA" FontSize="10" FontFamily="Bahnschrift SemiBold" VerticalAlignment="Center"/>
        </Grid>

      </StackPanel>
    </DockPanel>
  </Border>
  </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Set-SectionBar - local copy of Ui.ps1 Set-Bar so Claude bars render without
# depending on Ui.ps1 (Leg E does not dot-source Ui.ps1). Shows REMAINING/used %.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Set-BarWidth - eases a progress bar to a new Width instead of snapping.
# Mirrors the Toggle-Section height-animation contract: any in-flight animation
# is cleared (BeginAnimation $null) before we touch Width, and on Completed the
# held value is handed back to the real DP - otherwise FillBehavior=HoldEnd pins
# Width and silently swallows every later refresh's assignment (bars freeze).
# Animates from the current ON-SCREEN width (ActualWidth) so mid-tween refreshes
# hand off smoothly; sub-pixel deltas skip the tween to avoid per-refresh churn.
# ---------------------------------------------------------------------------
function Set-BarWidth($b, [double]$target) {
    if (-not $b) { return }
    $wp  = [System.Windows.FrameworkElement]::WidthProperty
    # Hidden bars (collapsed section, or the inactive full/compact layout) skip the
    # tween: their ActualWidth is 0, so every refresh would re-animate 0->target for
    # nothing. Set the value directly so it's correct the moment they become visible.
    if (-not $b.IsVisible) { $b.BeginAnimation($wp, $null); $b.Width = $target; return }
    $cur = $b.ActualWidth
    if ([double]::IsNaN($cur) -or $cur -lt 0) { $cur = 0 }
    $b.BeginAnimation($wp, $null)
    if ([math]::Abs($target - $cur) -lt 1) { $b.Width = $target; return }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From     = $cur
    $anim.To       = $target
    $anim.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(220))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease
    $bb = $b; $t = $target
    $anim.Add_Completed({
        $bb.BeginAnimation($wp, $null)
        $bb.Width = $t
    }.GetNewClosure())
    $b.BeginAnimation($wp, $anim)
}

function Set-SectionBar([string]$bar, [string]$pct, [string]$sub, [string]$reset, $util, $resetsAt) {
    $b  = $script:window.FindName($bar)
    $p  = $script:window.FindName($pct)
    $sb = if ($sub)   { $script:window.FindName($sub)   } else { $null }
    $r  = if ($reset) { $script:window.FindName($reset) } else { $null }
    if (-not $b -or -not $p) { return }
    if ($null -eq $util) {
        Set-BarWidth $b 0; $p.Text = '--'; $p.Foreground = NewBrush '#F1F5F9'
        if ($sb) { $sb.Text = 'used' }
        if ($r)  { $r.Text  = '' }
        return
    }
    $u        = [double]$util
    Set-BarWidth $b ([math]::Max(0, [math]::Min($script:BarTrackWidth, [math]::Round($u / 100.0 * $script:BarTrackWidth))))
    $p.Text   = ('{0:0}%' -f $u)
    $fg = if ($u -ge $script:CritPct) { '#F87171' } elseif ($u -ge $script:WarnPct) { '#FBBF24' } else { '#F1F5F9' }
    $p.Foreground = NewBrush $fg
    if ($sb) { $sb.Text = if ($u -ge $script:CritPct) { 'critical!' } elseif ($u -ge $script:WarnPct) { 'high' } else { 'used' } }
    if ($r)  { $r.Text  = Format-Reset $resetsAt }
}

# ---------------------------------------------------------------------------
# Set-CompactBar - single-line compact row: fills the narrow bar and sets the %
# text (same warn/crit foreground as the full view). Safe no-op until the
# compact XAML exists (FindName returns null for missing elements).
# ---------------------------------------------------------------------------
function Set-CompactBar([string]$bar, [string]$pct, $util) {
    $b = $script:window.FindName($bar)
    $p = $script:window.FindName($pct)
    if (-not $b -or -not $p) { return }
    if ($null -eq $util) {
        Set-BarWidth $b 0; $p.Text = '--'; $p.Foreground = NewBrush '#F1F5F9'
        return
    }
    $u = [double]$util
    Set-BarWidth $b ([math]::Max(0, [math]::Min($script:CompactBarWidth, [math]::Round($u / 100.0 * $script:CompactBarWidth))))
    $p.Text = ('{0:0}%' -f $u)
    $fg = if ($u -ge $script:CritPct) { '#F87171' } elseif ($u -ge $script:WarnPct) { '#FBBF24' } else { '#F1F5F9' }
    $p.Foreground = NewBrush $fg
}

# ---------------------------------------------------------------------------
# Set-Spark - renders a sparkline polyline onto a named Canvas
# ---------------------------------------------------------------------------
function Set-Spark([string]$sparkName, [string]$canvasName, [string]$metricKey, [string]$rowName = $null) {
    $spark  = $script:window.FindName($sparkName)
    $canvas = $script:window.FindName($canvasName)
    $row    = if ($rowName) { $script:window.FindName($rowName) } else { $null }
    $hide = {
        if ($row) { $row.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    if (-not $spark -or -not $canvas) { & $hide; return }
    $spark.Points.Clear()

    $showGraph = $script:Cfg -and [bool]$script:Cfg.ShowGraph
    $samples = $script:History
    if (-not $showGraph -or $null -eq $samples -or $samples.Count -lt 2) { & $hide; return }

    $valid = @($samples | Where-Object { $null -ne $_.$metricKey })
    if ($valid.Count -lt 2) { & $hide; return }
    if ($row) { $row.Visibility = [System.Windows.Visibility]::Visible }

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
        $y = $h - ([math]::Max(0, [math]::Min(100, [double]($s.$metricKey))) / 100.0 * $h)
        [void]$spark.Points.Add([System.Windows.Point]::new($x, $y))
    }
}

# ---------------------------------------------------------------------------
# Apply-UnifiedTheme - applies $script:Themes[$name] across the chrome and all
# three sections. Mirrors Ui.ps1 Apply-Theme; extends to codex/cursor. Greyscale-safe.
# ---------------------------------------------------------------------------
function Get-OverlayBrandPngPath {
    Join-Path $env:LOCALAPPDATA 'AIUsageOverlay\brand.png'
}

function Apply-FooterBrandMark {
    $img = $script:window.FindName('brandMarkImage')
    $box = $script:window.FindName('brandMarkBox')
    if (-not $img -or -not $box) { return }

    $path = Get-OverlayBrandPngPath
    $ok = $false
    if (Test-Path -LiteralPath $path) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $stream = [System.IO.File]::OpenRead($path)
            try {
                $bmp.StreamSource = $stream
                $bmp.EndInit()
            } finally {
                $stream.Dispose()
            }
            if ($bmp.CanFreeze) { $bmp.Freeze() }
            $img.Source = $bmp
            $ok = $true
        } catch {
            $img.Source = $null
        }
    }

    if ($ok) {
        $img.Visibility = [System.Windows.Visibility]::Visible
        $box.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $img.Source = $null
        $img.Visibility = [System.Windows.Visibility]::Collapsed
        $box.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Invoke-SetFooterBrand {
    # Tray-discoverable: pick a PNG into the documented drop path, then repaint.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png|All files (*.*)|*.*'
    $dlg.Title = 'Choose footer brand PNG'
    $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $dest = Get-OverlayBrandPngPath
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    try {
        Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Set footer brand failed: $($_.Exception.Message)"
        }
        return
    }
    Apply-FooterBrandMark
}

function Invoke-ResetFooterBrand {
    $path = Get-OverlayBrandPngPath
    if (Test-Path -LiteralPath $path) {
        try { Remove-Item -LiteralPath $path -Force } catch { }
    }
    Apply-FooterBrandMark
}

function Apply-UnifiedTheme([string]$name) {
    $t = $script:Themes[$name]
    if (-not $t) { return }

    # Main panel background and border
    $mb = $script:window.FindName('mainBorder')
    if ($mb -and $t.BgC1) {
        $mb.Background  = New-GradientBrush2 $t.BgC1 $t.BgC2
        $mb.BorderBrush = NewBrush $t.BorderC1
    }

    $brand = $script:window.FindName('brandLabel')
    if ($brand -and $t.BrandLabelFg) { $brand.Foreground = NewBrush $t.BrandLabelFg }
    $bp = $script:window.FindName('brandPath')
    if ($bp -and $t.BrandLabelFg) { $bp.Fill = NewBrush $t.BrandLabelFg }
    Apply-FooterBrandMark

    # Claude/Codex bars/labels/subs
    $bars   = @('fivehBar','weekBar','fabBar','opusBar','codexWeekBar','fivehBarC','weekBarC','fabBarC','opusBarC','codexWeekBarC')
    $labels = @('fivehLabel','weekLabel','fabLabel','opusLabel','codexWeekLabel','fivehLabelC','weekLabelC','fabLabelC','opusLabelC','codexWeekLabelC')
    $subs   = @('fivehSub','weekSub','fabSub','opusSub','codexWeekSub','','','','','')
    $fgKeys = @('FivehFg','WeekFg','FabFg','OpusFg','WeekFg','FivehFg','WeekFg','FabFg','OpusFg','WeekFg')
    $bgKeys = @('FivehColors','WeekColors','FabColors','OpusColors','WeekColors','FivehColors','WeekColors','FabColors','OpusColors','WeekColors')
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $b = $script:window.FindName($bars[$i])
        if ($b -and $t[$bgKeys[$i]]) { $b.Background = New-GradientBrush $t[$bgKeys[$i]][0] $t[$bgKeys[$i]][1] }
        $l = $script:window.FindName($labels[$i])
        if ($l -and $t[$fgKeys[$i]]) { $l.Foreground = NewBrush $t[$fgKeys[$i]] }
        $s = $script:window.FindName($subs[$i])
        if ($s -and $t[$fgKeys[$i]]) { $s.Foreground = NewBrush ($t[$fgKeys[$i]] + '55') }
    }

    # Cursor bar/label (per-theme CursorColors; the bar is repainted every refresh in
    # Update-CursorSection, so we stash the theme colors for it to reuse).
    $cc  = if ($t.CursorColors) { $t.CursorColors } elseif ($t.FivehColors) { $t.FivehColors } else { @('#065F46','#34D399') }
    $cfg = if ($t.CursorFg)     { $t.CursorFg }     elseif ($t.FivehFg)     { $t.FivehFg }     else { '#34D399' }
    $script:CursorColorsCur = $cc
    $gc  = if ($t.GrokColors) { $t.GrokColors } elseif ($t.OpusColors) { $t.OpusColors } else { @('#A16207','#FDE68A') }
    $gfg = if ($t.GrokFg)     { $t.GrokFg }     elseif ($t.OpusFg)     { $t.OpusFg }     else { '#FDE68A' }
    $script:GrokColorsCur = $gc
    foreach ($bn in @('grokWeekBar','grokWeekBarC')) {
        $gb = $script:window.FindName($bn)
        if ($gb) { $gb.Background = New-GradientBrush $gc[0] $gc[1] }
    }
    foreach ($ln in @('grokWeekLabel','grokWeekLabelC')) {
        $gl = $script:window.FindName($ln)
        if ($gl) { $gl.Foreground = NewBrush $gfg }
    }
    $gs = $script:window.FindName('grokWeekSub')
    if ($gs) { $gs.Foreground = NewBrush ($gfg + '55') }
    foreach ($bn in @('reqBar','reqBarC')) {
        $rb = $script:window.FindName($bn)
        if ($rb) { $rb.Background = New-GradientBrush $cc[0] $cc[1] }
    }
    foreach ($ln in @('reqLabel','reqLabelC')) {
        $rl = $script:window.FindName($ln)
        if ($rl) { $rl.Foreground = NewBrush $cfg }
    }

    # Sparkline strokes
    $fivehSpark = $script:window.FindName('fivehSpark')
    if ($fivehSpark -and $t.FivehFg) { $fivehSpark.Stroke = NewBrush $t.FivehFg }
    $weekSpark = $script:window.FindName('weekSpark')
    if ($weekSpark -and $t.WeekFg) { $weekSpark.Stroke = NewBrush $t.WeekFg }

    # Accent stripe
    $stripe = $script:window.FindName('accentStripe')
    if ($stripe -and $t.Stripe) {
        $gb = New-Object System.Windows.Media.LinearGradientBrush
        $gb.StartPoint = [System.Windows.Point]::new(0,0)
        $gb.EndPoint   = [System.Windows.Point]::new(1,0)
        $offsets = @(0, 0.33, 0.66, 1)
        for ($i = 0; $i -lt 4; $i++) {
            $gsp = New-Object System.Windows.Media.GradientStop
            $gsp.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString($t.Stripe[$i])
            $gsp.Offset = $offsets[$i]
            [void]$gb.GradientStops.Add($gsp)
        }
        $stripe.Background = $gb
    }

    # Sync theme menu checkmarks if the tray built them (WinForms .Checked)
    if ($script:themeItems) {
        foreach ($kv in $script:themeItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $name) }
    }
}

# ---------------------------------------------------------------------------
# Set-Section - non-animated visibility/chevron set (startup restore).
# ---------------------------------------------------------------------------
function Set-Section([string]$key, [bool]$expanded) {
    $body = $script:window.FindName($key + 'Body')
    $chev = $script:window.FindName($key + 'Chevron')
    if (-not $body) { return }
    $body.Visibility = if ($expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if ($chev) { $chev.Text = if ($expanded) { 'v' } else { '>' } }
}

# ---------------------------------------------------------------------------
# Set-SectionVisible - whole-section visibility for tray Show/Hide.
# Keeps the accordion body state independent; hiding a wrapper hides header+body.
# ---------------------------------------------------------------------------
function Set-SectionVisible([string]$key, [bool]$visible) {
    if (-not $script:window) { return }
    $section = $script:window.FindName($key + 'Section')
    if (-not $section) { return }
    $section.Visibility = if ($visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    Resize-ToContent
}

# ---------------------------------------------------------------------------
# Measure-ContentHeight - forces a layout pass and returns the window's desired
# size (the size the content wants). SizeToContent is Manual, so the window
# height is owned by code (animation or direct set), and this is how we learn
# the target. Width is intrinsic (fixed inner panel) and returned too.
# ---------------------------------------------------------------------------
function Measure-ContentHeight([switch]$SkipArrange) {
    $root = $script:window
    $content = $root.Content
    if ($content) {
        $content.InvalidateMeasure()
        $content.InvalidateArrange()
        $content.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $size = $content.DesiredSize
        if ($size.Width -gt 0 -and $size.Height -gt 0) {
            if (-not $SkipArrange) {
                $content.Arrange([System.Windows.Rect]::new(0, 0, $size.Width, $size.Height))
                $root.UpdateLayout()
            }
            return $size
        }
    }

    $root.UpdateLayout()
    $root.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    return $root.DesiredSize
}

# ---------------------------------------------------------------------------
# Resize-ToContent - non-animated: snap Window.Width/Height to the measured
# content size. Called after content-changing refreshes (opus row appears,
# error text) so the box keeps fitting even though SizeToContent is Manual.
# ---------------------------------------------------------------------------
function Resize-ToContent([switch]$SkipDeferred) {
    $root = $script:window
    # The quake strip is monitor-wide by definition, so content-driven sizing
    # would shrink it. Every existing caller (poll completion, section toggle)
    # funnels through here, so this is the one place that has to know.
    if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) {
        Resize-QuakeToContent
        return
    }
    $size = Measure-ContentHeight
    if ($size.Width  -gt 0) { $root.Width  = $size.Width }
    if ($size.Height -gt 0) { $root.Height = $size.Height }
    $root.UpdateLayout()

    if (-not $SkipDeferred -and $root.Dispatcher -and -not $script:ResizeToContentDeferred) {
        $script:ResizeToContentDeferred = $true
        [void]$root.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [Action]{
                $script:ResizeToContentDeferred = $false
                Resize-ToContent -SkipDeferred
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Toggle-Section - flips a section body, swaps chevron, persists, and animates
# the window height smoothly (DoubleAnimation on Window.HeightProperty).
# SizeToContent is Manual so the animation fully OWNS the height; on Completed
# we clear the animation and write a real Height value so later non-animated
# resizes (Resize-ToContent) can change it.
# ---------------------------------------------------------------------------
function Toggle-Section([string]$key) {
    $body = $script:window.FindName($key + 'Body')
    if (-not $body) { return }
    $root = $script:window

    # Target state = opposite of current visibility.
    $expanded = ($body.Visibility -ne [System.Windows.Visibility]::Visible)

    # Start the animation from the height we currently occupy.
    $from = $root.ActualHeight
    if ($from -le 0) { $from = $root.Height }
    if ($from -gt 0) {
        $root.BeginAnimation([System.Windows.Window]::HeightProperty, $null)
        $root.Height = $from
    }

    # Apply the visibility/chevron change, then measure the new desired size
    # without arranging the final layout before the animation starts.
    Set-Section $key $expanded
    $size = Measure-ContentHeight -SkipArrange
    $to = $size.Height
    if ($to -le 0) { $to = $root.ActualHeight }
    # Width is intrinsic; pin it now (SizeToContent is Manual).
    if ($size.Width -gt 0) { $root.Width = $size.Width }

    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From     = $from
    $anim.To       = $to
    $anim.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(180))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease

    # On completion, hand the held value back to the real DP so future sets work:
    # clear the animation (BeginAnimation $null) then set Height to the target.
    # FillBehavior=HoldEnd would otherwise pin Height to $to as an animated
    # value and silently swallow later $root.Height = ... assignments.
    $anim.Add_Completed({
        $root.BeginAnimation([System.Windows.Window]::HeightProperty, $null)
        $root.Height = $to
        Resize-ToContent -SkipDeferred
    }.GetNewClosure())

    $root.BeginAnimation([System.Windows.Window]::HeightProperty, $anim)

    if (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue) { Save-UnifiedState }
}

# ---------------------------------------------------------------------------
# Update-ClaudeSection - ports Ui.ps1 Update-UI body (bars, stats, sparklines),
# minus the chrome dot/time (now global). Reads $script:State/$script:Stats.
# ---------------------------------------------------------------------------
function Update-ClaudeSection {
    $identityText = $script:window.FindName('claudeIdentityText')
    if ($identityText) {
        $identityText.Text = if ($script:ClaudeIdentity -and $script:ClaudeIdentity.Display) { [string]$script:ClaudeIdentity.Display } else { '--' }
    }

    $s = $script:Stats
    if ($s) {
        $script:window.FindName('valText').Text   = ('~{0} all-time' -f (Fmt-Money $s.ValueUSD))
        $script:window.FindName('tokText').Text   = ('{0} in / {1} out' -f (Fmt-Tok $s.InTokens), (Fmt-Tok $s.OutTokens))
        $script:window.FindName('todayText').Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayTok), $s.TodayMsg)
        $afterHoursText = $script:window.FindName('afterHoursText')
        if ($afterHoursText) { $afterHoursText.Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayAfterHoursTok), $s.TodayAfterHoursMsg) }
        $script:window.FindName('lifeText').Text  = ('{0} sessions  {1} msgs' -f $s.Sessions, (Fmt-Tok $s.Messages))
    }

    $d = if ($script:State) { $script:State.Data } else { $null }
    if ($null -eq $d) {
        Set-SectionBar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $null $null
        Set-SectionBar 'weekBar'  'weekPct'  'weekSub'  'weekReset'  $null $null
        Set-SectionBar 'fabBar'   'fabPct'   'fabSub'   'fabReset'   $null $null
        Set-CompactBar 'fivehBarC' 'fivehPctC' $null
        Set-CompactBar 'weekBarC'  'weekPctC'  $null
        Set-CompactBar 'fabBarC'   'fabPctC'   $null
        $hd = $script:window.FindName('claudeHeaderDetail'); if ($hd) { $hd.Text = '' }
        return
    }

    $hasAlert = [bool](Get-Command Check-Alert -ErrorAction SilentlyContinue)

    $hd = $script:window.FindName('claudeHeaderDetail'); if ($hd) { $hd.Text = Format-Reset $d.five_hour.resets_at }

    Set-SectionBar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $d.five_hour.utilization $d.five_hour.resets_at
    Set-CompactBar 'fivehBarC' 'fivehPctC' $d.five_hour.utilization
    Set-Spark 'fivehSpark' 'fivehSparkCanvas' 'five_hour' 'fivehSparkRow'
    Set-Spark 'fivehSparkC' 'fivehSparkCanvasC' 'five_hour' 'fivehSparkRowC'
    if ($hasAlert) { Check-Alert 'five_hour' $d.five_hour.utilization }

    Set-SectionBar 'weekBar' 'weekPct' 'weekSub' 'weekReset' $d.seven_day.utilization $d.seven_day.resets_at
    Set-CompactBar 'weekBarC' 'weekPctC' $d.seven_day.utilization
    Set-Spark 'weekSpark' 'weekSparkCanvas' 'seven_day' 'weekSparkRow'
    Set-Spark 'weekSparkC' 'weekSparkCanvasC' 'seven_day' 'weekSparkRowC'
    if ($hasAlert) { Check-Alert 'seven_day' $d.seven_day.utilization }

    Set-SectionBar 'fabBar' 'fabPct' 'fabSub' 'fabReset' $d.seven_day_fable.utilization $d.seven_day_fable.resets_at
    Set-CompactBar 'fabBarC' 'fabPctC' $d.seven_day_fable.utilization
    if ($hasAlert) { Check-Alert 'seven_day_fable' $d.seven_day_fable.utilization }

    if ($d.seven_day_opus) {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Visible
        $oc = $script:window.FindName('opusRowC'); if ($oc) { $oc.Visibility = [System.Windows.Visibility]::Visible }
        Set-SectionBar 'opusBar' 'opusPct' 'opusSub' 'opusReset' $d.seven_day_opus.utilization $d.seven_day_opus.resets_at
        Set-CompactBar 'opusBarC' 'opusPctC' $d.seven_day_opus.utilization
        if ($hasAlert) { Check-Alert 'seven_day_opus' $d.seven_day_opus.utilization }
    } else {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Collapsed
        $oc = $script:window.FindName('opusRowC'); if ($oc) { $oc.Visibility = [System.Windows.Visibility]::Collapsed }
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
}

# ---------------------------------------------------------------------------
# Update-CodexSection - reads $script:CodexStats; fills codex* elements.
# ---------------------------------------------------------------------------
# Shared auth-error line renderer. Codex uses a dedicated TextBlock; Cursor
# overloads its on-demand hero slot (see Update-CursorSection). Both decide via
# Test-ProviderAuthFailed so "broken" means exactly one thing across providers.
function Set-SectionAuthError {
    param([string]$Name, [string]$AuthState, [string]$Message)

    $el = $script:window.FindName($Name)
    if (-not $el) { return $false }

    if (Test-ProviderAuthFailed $AuthState) {
        $el.Text = if ($Message) { $Message } else { 'Login required' }
        $el.Visibility = [System.Windows.Visibility]::Visible
        return $true
    }

    $el.Text = ''
    $el.Visibility = [System.Windows.Visibility]::Collapsed
    return $false
}

function Get-OverlayStatNote {
    # Hashtable and PSCustomObject note reader; keeps 0% distinct from missing.
    param($Obj, [string]$Name)
    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $null
}

function Update-CodexSection {
    Set-SectionAuthError 'codexErrText' $script:CodexAuthState $script:CodexErrMsg | Out-Null

    $s = $script:CodexStats
    if (-not $s) {
        foreach ($n in @('codexFivehRow','codexFivehRowC','codexFivehSparkRow','codexFivehSparkRowC')) {
            $el = $script:window.FindName($n); if ($el) { $el.Visibility = [System.Windows.Visibility]::Collapsed }
        }
        Set-SectionBar 'codexWeekBar' 'codexWeekPct' 'codexWeekSub' 'codexWeekReset' $null $null
        Set-CompactBar 'codexWeekBarC' 'codexWeekPctC' $null
        Set-Spark 'codexWeekSpark' 'codexWeekSparkCanvas' 'codex_seven_day' 'codexWeekSparkRow'
        Set-Spark 'codexWeekSparkC' 'codexWeekSparkCanvasC' 'codex_seven_day' 'codexWeekSparkRowC'
        $cr = $script:window.FindName('codexResetsText'); if ($cr) { $cr.Text = '--' }
        $tt = $script:window.FindName('codexTokText'); if ($tt) { $tt.Text = '--' }
        $cv = $script:window.FindName('codexValText'); if ($cv) { $cv.Text = '--' }
        $ct = $script:window.FindName('codexTodayText'); if ($ct) { $ct.Text = '--' }
        $ca = $script:window.FindName('codexAfterHoursText'); if ($ca) { $ca.Text = '--' }
        $cs = $script:window.FindName('codexSessText'); if ($cs) { $cs.Text = '--' }
        $chd = $script:window.FindName('codexHeaderDetail'); if ($chd) { $chd.Text = '' }
        return
    }
    $fiveHourPct = Get-OverlayStatNote $s 'FiveHourPct'
    $fiveHourResetsAt = Get-OverlayStatNote $s 'FiveHourResetsAt'
    $weekPct = Get-OverlayStatNote $s 'WeekPct'
    $weekResetsAt = Get-OverlayStatNote $s 'WeekResetsAt'
    $fivehVis = if ($null -ne $fiveHourPct) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($n in @('codexFivehRow','codexFivehRowC')) {
        $el = $script:window.FindName($n); if ($el) { $el.Visibility = $fivehVis }
    }
    if ($null -ne $fiveHourPct) {
        Set-SectionBar 'codexFivehBar' 'codexFivehPct' 'codexFivehSub' 'codexFivehReset' $fiveHourPct $fiveHourResetsAt
        Set-CompactBar 'codexFivehBarC' 'codexFivehPctC' $fiveHourPct
        Set-Spark 'codexFivehSpark' 'codexFivehSparkCanvas' 'codex_five_hour' 'codexFivehSparkRow'
        Set-Spark 'codexFivehSparkC' 'codexFivehSparkCanvasC' 'codex_five_hour' 'codexFivehSparkRowC'
    } else {
        # No live 5h window: hide spark rows even if history still has samples.
        foreach ($n in @('codexFivehSparkRow','codexFivehSparkRowC')) {
            $el = $script:window.FindName($n); if ($el) { $el.Visibility = [System.Windows.Visibility]::Collapsed }
        }
    }
    Set-SectionBar 'codexWeekBar' 'codexWeekPct' 'codexWeekSub' 'codexWeekReset' $weekPct $weekResetsAt
    Set-CompactBar 'codexWeekBarC' 'codexWeekPctC' $weekPct
    Set-Spark 'codexWeekSpark' 'codexWeekSparkCanvas' 'codex_seven_day' 'codexWeekSparkRow'
    Set-Spark 'codexWeekSparkC' 'codexWeekSparkCanvasC' 'codex_seven_day' 'codexWeekSparkRowC'
    $chd = $script:window.FindName('codexHeaderDetail'); if ($chd) { $chd.Text = Format-Reset $weekResetsAt }
    $codexResetsText = $script:window.FindName('codexResetsText')
    if ($codexResetsText) {
        if ($null -ne $s.ResetsAvailable) {
            $codexResetsText.Text = ('{0} available' -f [int]$s.ResetsAvailable)
        } else {
            $codexResetsText.Text = '--'
        }
    }
    $script:window.FindName('codexValText').Text   = ('~{0} all-time' -f (Fmt-Money $s.ValueUSD))
    $script:window.FindName('codexTokText').Text   = ('{0} in / {1} out' -f (Fmt-Tok $s.InTokens), (Fmt-Tok $s.OutTokens))
    $script:window.FindName('codexTodayText').Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayTok), $s.TodayMsg)
    $codexAfterHoursText = $script:window.FindName('codexAfterHoursText')
    if ($codexAfterHoursText) { $codexAfterHoursText.Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayAfterHoursTok), $s.TodayAfterHoursMsg) }
    $script:window.FindName('codexSessText').Text  = ('{0} sessions  {1} msgs' -f $s.Sessions, (Fmt-Tok $s.Messages))
}

# ---------------------------------------------------------------------------
# Update-CursorSection - ports cursor-overlay.ps1 Update-UI body (minus chrome
# dot/time), renamed dup elements + namespaced error/fetch vars.
# ---------------------------------------------------------------------------
function Update-GrokSection {
    Set-SectionAuthError 'grokErrText' $script:GrokAuthState $script:GrokErrMsg | Out-Null

    $s = $script:GrokUsage
    if (-not $s) {
        Set-SectionBar 'grokWeekBar' 'grokWeekPct' 'grokWeekSub' 'grokWeekReset' $null $null
        Set-CompactBar 'grokWeekBarC' 'grokWeekPctC' $null
        Set-Spark 'grokWeekSpark' 'grokWeekSparkCanvas' 'grok_seven_day' 'grokWeekSparkRow'
        Set-Spark 'grokWeekSparkC' 'grokWeekSparkCanvasC' 'grok_seven_day' 'grokWeekSparkRowC'
        $pt = $script:window.FindName('grokPlanText'); if ($pt) { $pt.Text = '--' }
        $pp = $script:window.FindName('grokPrepaidText'); if ($pp) { $pp.Text = '--' }
        $hd = $script:window.FindName('grokHeaderDetail'); if ($hd) { $hd.Text = '' }
        return
    }
    $weekPct = Get-OverlayStatNote $s 'WeekPct'
    $weekResetsAt = Get-OverlayStatNote $s 'WeekResetsAt'
    $prepaid = Get-OverlayStatNote $s 'PrepaidBalance'
    $productText = Get-OverlayStatNote $s 'ProductUsageText'
    $planType = Get-OverlayStatNote $s 'PlanType'
    Set-SectionBar 'grokWeekBar' 'grokWeekPct' 'grokWeekSub' 'grokWeekReset' $weekPct $weekResetsAt
    Set-CompactBar 'grokWeekBarC' 'grokWeekPctC' $weekPct
    Set-Spark 'grokWeekSpark' 'grokWeekSparkCanvas' 'grok_seven_day' 'grokWeekSparkRow'
    Set-Spark 'grokWeekSparkC' 'grokWeekSparkCanvasC' 'grok_seven_day' 'grokWeekSparkRowC'
    $hd = $script:window.FindName('grokHeaderDetail')
    if ($hd) { $hd.Text = Format-Reset $weekResetsAt }
    $pt = $script:window.FindName('grokPlanText')
    if ($pt) {
        if ($productText) { $pt.Text = [string]$productText }
        elseif ($planType) { $pt.Text = [string]$planType }
        else { $pt.Text = '--' }
    }
    $pp = $script:window.FindName('grokPrepaidText')
    if ($pp) {
        # Show 0.00 prepaid; only blank when the field is absent.
        $pp.Text = if ($null -ne $prepaid -and [string]$prepaid -ne '') { [string]$prepaid } else { '--' }
    }
}

function Update-CursorSection {
    # Cursor Models / Other Models / on-demand from usage-summary (Plan & Usage).
    # Do not paint from legacy usage.gpt-4 numRequests/maxRequestUsage (null → 0/0).
    $plan = Get-CursorPlanUsageFromSummary $script:SummaryData
    $hasBar = ($null -ne $plan.BarPercent)
    $pct = if ($hasBar) { [math]::Min(100, [math]::Round([double]$plan.BarPercent)) } else { 0 }
    # Prefer bar % for overage so a mismatched used/limit (e.g. 2000/2000) does not flash "over".
    $over = $false
    if ($hasBar) {
        $over = [double]$plan.BarPercent -gt 100
    } elseif (($null -ne $plan.Used) -and ($null -ne $plan.Limit) -and ([double]$plan.Limit -gt 0)) {
        $over = [double]$plan.Used -gt [double]$plan.Limit
    }

    $bar = $script:window.FindName('reqBar')
    $barC = $script:window.FindName('reqBarC')
    if ($hasBar) {
        Set-BarWidth $bar ([math]::Min($script:BarTrackWidth, [math]::Round($pct / 100.0 * $script:BarTrackWidth)))
        Set-BarWidth $barC ([math]::Min($script:CompactBarWidth, [math]::Round($pct / 100.0 * $script:CompactBarWidth)))
    } else {
        Set-BarWidth $bar 0
        Set-BarWidth $barC 0
    }

    $pill = $script:window.FindName('overPill')
    if ($hasBar -and $over) {
        if ($bar) { $bar.Background = New-GradientBrush '#78350F' '#FBBF24' }
        if ($barC) { $barC.Background = New-GradientBrush '#78350F' '#FBBF24' }
        if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Visible }
    } else {
        $cc = if ($script:CursorColorsCur) { $script:CursorColorsCur } else { @('#065F46','#34D399') }
        if ($bar) { $bar.Background = New-GradientBrush $cc[0] $cc[1] }
        if ($barC) { $barC.Background = New-GradientBrush $cc[0] $cc[1] }
        if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    $countText = Format-CursorPlanCountText $plan
    $script:window.FindName('reqCount').Text = $countText
    $rcc = $script:window.FindName('reqCountC'); if ($rcc) { $rcc.Text = $countText }
    $rr = $script:window.FindName('reqReset')
    if ($rr) {
        $rr.Text = if ($plan.BillingCycleEnd) { Format-Reset $plan.BillingCycleEnd } else { '' }
    }

    $otherText = '--'
    if ($null -ne $plan.ApiPercent) {
        $otherText = ('{0:0}%' -f [double]$plan.ApiPercent)
    }
    foreach ($n in @('otherModelsText','otherModelsTextC')) {
        $el = $script:window.FindName($n)
        if ($el) { $el.Text = $otherText }
    }

    # On-demand from usage-summary (enabled + used)
    $od = $script:window.FindName('onDemandText')
    if ($od) {
        if (Test-ProviderAuthFailed $script:AuthState) {
            $od.FontSize = 11
            $od.Text = $script:CursorErrMsg
            $od.Foreground = NewBrush '#F87171'
        } else {
            $od.FontSize = 12
            if (($null -ne $plan.OnDemandEnabled) -and (-not $plan.OnDemandEnabled)) {
                $od.Text = 'Off'
                $od.Foreground = NewBrush '#5B9A80'
            } elseif ($null -ne $plan.OnDemandUsedCents) {
                $dollars = [double]$plan.OnDemandUsedCents / 100.0
                $od.Text = ('${0:N2}' -f $dollars)
                $od.Foreground = if ($dollars -gt 0) { NewBrush '#FBBF24' } else { NewBrush '#5B9A80' }
            } else {
                $od.Text = '--'
                $od.Foreground = NewBrush '#5B9A80'
            }
        }
    }

    # Edit/model stats from the Cursor analytics API (30-day rolling window).
    # When LocalData is null (405/403), hide the whole block so compact/full
    # are not a wall of "--".
    $l = $script:LocalData
    $analytics = $script:window.FindName('cursorAnalyticsBlock')
    if ($l) {
        if ($analytics) { $analytics.Visibility = [System.Windows.Visibility]::Visible }
        $et = $script:window.FindName('editsText'); if ($et) { $et.Text = ('{0} (30d)' -f (Fmt-Num $l.edits30d)) }
        $ct = $script:window.FindName('cursorTodayText'); if ($ct) { $ct.Text = ('{0} edits' -f (Fmt-Num $l.editsToday)) }
        $cm = $script:window.FindName('cursorModelText')
        if ($cm) {
            if ($l.topModel) {
                $mn = $l.topModel -replace 'claude-','cl-' -replace 'composer-','cmp-' -replace '-latest',''
                $cm.Text = "$mn ($($l.topPct)%)"
            } else {
                $cm.Text = '--'
            }
        }
        $cs = $script:window.FindName('cursorSessText'); if ($cs) { $cs.Text = ('{0} lines' -f (Fmt-Num $l.linesAccepted)) }
    } else {
        if ($analytics) { $analytics.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    # Compact header detail: on-demand cost takes over (amber) the moment Cursor
    # reports any on-demand spend - that's the number you want when you're paying.
    # Below that threshold it shows the billing-cycle reset instead.
    $uhd = $script:window.FindName('cursorHeaderDetail')
    if ($uhd) {
        $sum = $script:SummaryData
        $odDollars = 0.0
        $odOn = $true
        if ($null -ne $plan.OnDemandEnabled) { $odOn = [bool]$plan.OnDemandEnabled }
        if ($odOn -and ($null -ne $plan.OnDemandUsedCents)) {
            $odDollars = [double]$plan.OnDemandUsedCents / 100.0
        }
        if ($odOn -and $odDollars -gt 0) {
            $uhd.Text = ('${0:N2}' -f $odDollars); $uhd.Foreground = NewBrush '#FBBF24'
        } elseif ($sum -and $sum.billingCycleEnd) {
            $uhd.Text = Format-Reset $sum.billingCycleEnd; $uhd.Foreground = NewBrush '#7B9EC4'
        } else {
            $uhd.Text = ''
        }
    }

    Set-Spark 'cursorReqSpark' 'cursorReqSparkCanvas' 'cursor_requests' 'cursorReqSparkRow'
    Set-Spark 'cursorReqSparkC' 'cursorReqSparkCanvasC' 'cursor_requests' 'cursorReqSparkRowC'
}

# ---------------------------------------------------------------------------
# Update-AllSections - chrome dot/time + the three section renderers + tray text.
# ---------------------------------------------------------------------------
function Test-ClaudeSectionVisible {
    # Show/Hide Claude: Cfg.Sections['claude'] false means Claude chrome must stay quiet.
    if (-not $script:Cfg -or -not $script:Cfg.Sections) { return $true }
    $sections = $script:Cfg.Sections
    if ($sections -is [System.Collections.IDictionary]) {
        if ($sections.Contains('claude')) { return [bool]$sections['claude'] }
        return $true
    }
    $prop = $sections.PSObject.Properties['claude']
    if ($prop) { return [bool]$prop.Value }
    return $true
}

function Update-AllSections {
    $dot  = $script:window.FindName('statusDot')
    $time = $script:window.FindName('timeText')
    $status = if ($script:State) { $script:State.Status } else { 'init' }
    $claudeShown = Test-ClaudeSectionVisible
    # When Claude is hidden, do not surface Claude auth/stale/error in top chrome.
    $chromeStatus = $status
    if (-not $claudeShown -and $status -in @('auth', 'error', 'stale')) {
        $chromeStatus = 'ok'
    }
    if ($dot) {
        switch ($chromeStatus) {
            'ok'    { $dot.Fill = NewBrush '#4ADE80' }
            'stale' { $dot.Fill = NewBrush '#FBBF24' }
            'auth'  { $dot.Fill = NewBrush '#F87171' }
            'error' { $dot.Fill = NewBrush '#F87171' }
            default { $dot.Fill = NewBrush '#4B6A8A' }
        }
    }
    if ($time -and $script:State) {
        if ($script:State.Status -eq 'ok') {
            $time.Text = $script:State.LastFetch
        } elseif ($claudeShown) {
            $time.Text = $script:State.Message
        } else {
            $time.Text = ''
        }
    }

    Update-ClaudeSection
    Update-CodexSection
    Update-CursorSection
    Update-GrokSection

    if (Get-Command Sync-CompactModeBodies -ErrorAction SilentlyContinue) { Sync-CompactModeBodies }

    # NOTE: Resize-ToContent is deliberately NOT called here. This runs on the
    # 30s tick timer, and a full-tree Measure every 30s is wasted work (content
    # height only changes on the 180s data poll or a section toggle). Callers
    # that change content size (poll-completion handler, startup restore) invoke
    # Resize-ToContent explicitly; Toggle-Section resizes via its animation.

    if ($script:notify -and $script:State -and $script:State.Data) {
        $cd = $script:State.Data
        $identity = if ($script:ClaudeIdentity -and $script:ClaudeIdentity.Email) { [string]$script:ClaudeIdentity.Email } else { 'Claude' }
        $text = ('AI  {0}  5h {1:0}%  Wk {2:0}%' -f $identity, [double]$cd.five_hour.utilization, [double]$cd.seven_day.utilization)
        if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
        $script:notify.Text = $text
    }

    if (Get-Command Update-QuakeView -ErrorAction SilentlyContinue) { Update-QuakeView }
}
