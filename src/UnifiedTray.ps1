# UnifiedTray.ps1 - unified system tray icon and dark context menu

# ---------------------------------------------------------------------------
# Window events - wired per window instance (called by Build-And-Show on each build)
# ---------------------------------------------------------------------------
function Wire-UnifiedWindowEvents {
    $script:window.Add_MouseLeftButtonDown({
        # In dropdown mode the panel is anchored to a monitor edge; dragging it
        # would both fight the slide animation and overwrite the pinned position.
        if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) { return }
        try {
            $script:window.DragMove()
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "DragMove error: $($_.Exception.Message)"
            }
        }
        Save-UnifiedState
    })

    # Quake-style dismissal: Esc, or focus moving to another app. The context
    # menu is a WinForms strip, so showing it deactivates this window - without
    # that guard, right-clicking the panel would slide it away.
    $script:window.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape -and (Test-DropdownMode)) {
            Hide-Dropdown
            $e.Handled = $true
        }
    })
    # Off by default: a real quake console stays up until you dismiss it, and a
    # usage readout you want to glance at while working in another window is
    # exactly the case where hiding on focus loss is wrong.
    $script:window.Add_Deactivated({
        if (-not (Test-DropdownMode)) { return }
        if (-not [bool]$script:Cfg['DropdownHideOnFocusLoss']) { return }
        if ($script:ctxStrip -and $script:ctxStrip.Visible) { return }
        Hide-Dropdown
    })
    $script:window.Add_Loaded({ Resize-ToContent; Position-Window })
    $script:window.Add_Closing({ param($s, $e) if (-not $script:ReallyQuit) { $e.Cancel = $true; $script:window.Hide() } })
    $script:window.Add_MouseRightButtonUp({
        param($s, $e)
        Show-ContextMenuAtWpfPointer $e
    })

    foreach ($pair in @(@('claudeHeader','claude'), @('codexHeader','codex'), @('cursorHeader','cursor'))) {
        $headerName = $pair[0]
        $sectionKey = $pair[1]
        $header = $script:window.FindName($headerName)
        if ($header) {
            # Mark mouse-down handled so the window-level DragMove handler does not
            # start a drag (which would otherwise swallow the header's mouse-up).
            $header.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
            $header.Add_MouseLeftButtonUp([scriptblock]::Create("Toggle-Section '$sectionKey'; Sync-SectionMenuItems"))
        }
    }
}

function Toggle-PinnedWindow {
    if ($script:window.IsVisible) { $script:window.Hide() }
    else { $script:window.Show(); $script:window.Activate(); $script:window.Topmost = $true }
}

# Tray-click entry point. Kept separate from Toggle-PinnedWindow so the dropdown
# path and the pinned path cannot call back into each other.
function Toggle-Window {
    if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) {
        Toggle-Dropdown
        return
    }
    Toggle-PinnedWindow
}

function Show-ContextMenuAtWpfPointer {
    param($EventArgs)

    try {
        $localPoint = $EventArgs.GetPosition($script:window)
        $screenPoint = $script:window.PointToScreen($localPoint)
        $script:ctxStrip.Show([int][math]::Round($screenPoint.X), [int][math]::Round($screenPoint.Y))
        $EventArgs.Handled = $true
    } catch {
        $pt = [System.Windows.Forms.Control]::MousePosition
        $script:ctxStrip.Show($pt.X, $pt.Y)
    }
}

function Quit-App {
    $script:ReallyQuit = $true
    if ($script:pollTimer) { $script:pollTimer.Stop() }
    if ($script:tickTimer) { $script:tickTimer.Stop() }
    if ($script:jobTimer)  { $script:jobTimer.Stop() }
    if ($script:updateAutoTimer) { $script:updateAutoTimer.Stop() }
    if ($script:updateStartupTimer) { $script:updateStartupTimer.Stop() }
    if ($script:updateJobTimer) { $script:updateJobTimer.Stop() }
    if ($script:pollJobs) {
        foreach ($job in @($script:pollJobs.Values)) {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        $script:pollJobs.Clear()
    }
    if ($script:updateJobs) {
        foreach ($job in @($script:updateJobs.Values)) {
            if ($job -is [System.Management.Automation.Job]) {
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }
        $script:updateJobs.Clear()
    }
    if (Get-Command Dispose-DropdownHotkey -ErrorAction SilentlyContinue) { Dispose-DropdownHotkey }
    if ($script:notify)    { $script:notify.Visible = $false; $script:notify.Dispose() }
    $script:window.Close()
    $script:window.Dispatcher.InvokeShutdown()
}

function Invoke-ManualRefresh {
    if ($script:State) {
        $script:State.Status = 'refreshing'
        $script:State.Message = 'refreshing...'
    }

    Start-AllRefreshJobs -Force

    if ($script:jobTimer -and -not $script:jobTimer.IsEnabled) {
        $script:jobTimer.Start()
    }

    Update-AllSections
}

# ---------------------------------------------------------------------------
# Right-click context menu - dark-themed WinForms ContextMenuStrip shown
# from the WPF panel's MouseRightButtonUp event.
# ---------------------------------------------------------------------------
$script:themeItems   = @{}
$script:opacityItems = @{}
$script:sectionItems = @{}
$script:updateItems  = @{}
$script:updateJobs   = @{}

# Dark colour table for the strip renderer
# Resolve already-loaded assembly paths so Add-Type can find them under .NET 6+
$_sdPath  = [System.Drawing.Color].Assembly.Location
$_swfPath = [System.Windows.Forms.Form].Assembly.Location
$_gfxPath = [System.Drawing.Graphics].Assembly.Location   # Graphics/SolidBrush/Pen live in a separate assembly from Color
Add-Type -ReferencedAssemblies $_sdPath, $_swfPath, $_gfxPath -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class DarkColorTable : ProfessionalColorTable {
    public override Color MenuItemSelected              { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color MenuItemBorder                { get { return Color.FromArgb(56, 130, 180); } }
    public override Color MenuBorder                    { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color ToolStripDropDownBackground   { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color ImageMarginGradientBegin      { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color ImageMarginGradientMiddle     { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color ImageMarginGradientEnd        { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color CheckBackground               { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color CheckSelectedBackground       { get { return Color.FromArgb(56, 130, 180); } }
    public override Color SeparatorDark                 { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color SeparatorLight                { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color MenuItemSelectedGradientEnd   { get { return Color.FromArgb(30,  58, 95);  } }
    public override Color MenuItemPressedGradientBegin  { get { return Color.FromArgb(56, 130, 180); } }
    public override Color MenuItemPressedGradientEnd    { get { return Color.FromArgb(56, 130, 180); } }
    public override Color MenuStripGradientBegin        { get { return Color.FromArgb(13,  20, 40);  } }
    public override Color MenuStripGradientEnd          { get { return Color.FromArgb(13,  20, 40);  } }
}
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    public DarkMenuRenderer() : base(new DarkColorTable()) { RoundedEdges = false; }
    // ToolStripProfessionalRenderer ignores the color table's MenuItemSelected for the
    // selected fill when visual styles are on - it draws a light system highlight, which
    // renders our light-grey item text unreadable. Paint the fill ourselves so the
    // highlight stays dark and the text remains legible.
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle bounds = new Rectangle(Point.Empty, e.Item.Size);
        if (e.Item.Selected || e.Item.Pressed) {
            using (var b = new SolidBrush(Color.FromArgb(30,  58, 95)))  g.FillRectangle(b, bounds);
            using (var p = new Pen(Color.FromArgb(56, 130, 180)))        g.DrawRectangle(p, 0, 0, bounds.Width - 1, bounds.Height - 1);
        } else {
            using (var b = new SolidBrush(Color.FromArgb(13, 20, 40)))   g.FillRectangle(b, bounds);
        }
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle r = e.ImageRectangle;
        if (r.IsEmpty) return;
        using (var b = new SolidBrush(Color.FromArgb(30, 58, 95)))
            g.FillRectangle(b, r);
        var prevMode = g.SmoothingMode;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (var pen = new Pen(Color.FromArgb(147, 197, 253), 1.5f)) {
            int x1 = r.Left + 3,            y1 = r.Top + r.Height / 2;
            int x2 = r.Left + r.Width/2 - 1, y2 = r.Bottom - 4;
            int x3 = r.Right - 3,           y3 = r.Top + 4;
            g.DrawLine(pen, x1, y1, x2, y2);
            g.DrawLine(pen, x2, y2, x3, y3);
        }
        g.SmoothingMode = prevMode;
    }
}
'@

$darkFg   = [System.Drawing.Color]::FromArgb(203, 213, 225)
$darkBg   = [System.Drawing.Color]::FromArgb(13, 20, 40)
$menuFont = New-Object System.Drawing.Font('Segoe UI', 9.5)

function New-StripItem([string]$text, [scriptblock]$onClick) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.ForeColor = $darkFg
    $mi.BackColor = $darkBg
    $mi.Font      = $menuFont
    if ($onClick) { $mi.add_Click($onClick) }
    return $mi
}

function Get-SectionVisible([string]$key) {
    if (-not $script:Cfg -or -not $script:Cfg.Sections) { return $true }

    $sections = $script:Cfg.Sections
    if ($sections -is [System.Collections.IDictionary] -and $sections.Contains($key)) {
        return [bool]$sections[$key]
    }
    if ($sections.PSObject.Properties.Name -contains $key) {
        return [bool]$sections.$key
    }
    return $true
}

function Get-SectionExpanded([string]$key) {
    return Get-SectionVisible $key
}

function Sync-SectionMenuItems {
    foreach ($key in @('claude','codex','cursor')) {
        if ($script:sectionItems.ContainsKey($key)) {
            $script:sectionItems[$key].Checked = Get-SectionVisible $key
        }
    }
}

$script:ctxStrip = New-Object System.Windows.Forms.ContextMenuStrip
$script:darkRenderer = New-Object DarkMenuRenderer
$script:ctxStrip.Renderer  = $script:darkRenderer
# Submenu dropdowns render via the global manager renderer, not the strip's own,
# so set it too - otherwise nested menu items keep the unreadable light highlight.
[System.Windows.Forms.ToolStripManager]::Renderer = $script:darkRenderer
$script:ctxStrip.BackColor = $darkBg
$script:ctxStrip.ForeColor = $darkFg
$script:ctxStrip.Font      = $menuFont
$script:ctxStrip.ShowImageMargin = $true

function Add-Separator {
    $sep = New-Object System.Windows.Forms.ToolStripSeparator
    $sep.BackColor = $darkBg; $sep.ForeColor = $darkFg
    [void]$script:ctxStrip.Items.Add($sep)
}

function Show-AppUpdateMessage {
    param(
        [string]$Title,
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )

    if ($script:notify) {
        $script:notify.ShowBalloonTip(5000, $Title, $Message, $Icon)
        return
    }

    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title)
}

$script:AppUpdateCheckScript = {
    param([string]$AppDir, [string]$ErrLog)

    $script:AppDir = $AppDir
    $script:ErrLog = $ErrLog

    . (Join-Path $AppDir 'src\Config.ps1')
    . (Join-Path $AppDir 'src\Update.ps1')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Test-AppUpdateAvailable
}

function Test-AppUpdateCheckJobRunning {
    if (-not $script:updateJobs -or -not $script:updateJobs.ContainsKey('UpdateCheck')) { return $false }

    $job = $script:updateJobs['UpdateCheck']
    return ($job.State -eq 'Running' -or $job.State -eq 'NotStarted')
}

function Sync-UpdateMenuItems {
    if (-not $script:updateItems -or -not $script:updateItems.ContainsKey('install')) { return }

    $state = $script:UpdateState
    $checking = Test-AppUpdateCheckJobRunning
    if ($script:updateItems.ContainsKey('check')) {
        $script:updateItems['check'].Enabled = -not $checking
        $script:updateItems['check'].Text = if ($checking) { 'Checking for updates...' } else { 'Check for updates' }
    }

    if ($script:updateItems.ContainsKey('auto')) {
        $script:updateItems['auto'].Checked = [bool]$script:Cfg.AutoCheckUpdates
    }

    $script:updateItems['install'].Enabled = ($state.Status -eq 'available' -and [bool]$state.DownloadUrl)
    if ($state.Status -eq 'available' -and $state.LatestVersion) {
        $script:updateItems['install'].Text = "Install update $($state.LatestVersion)"
    } else {
        $script:updateItems['install'].Text = 'Install update'
    }

    if ($script:updateItems.ContainsKey('status')) {
        $script:updateItems['status'].Text = "Update status: $($state.Status)"
    }
}

function Start-AppUpdateBackgroundCheck {
    param([switch]$Automatic)

    if ($Automatic -and -not [bool]$script:Cfg.AutoCheckUpdates) { return $false }
    if (Test-AppUpdateCheckJobRunning) { return $false }

    if ($script:updateJobs.ContainsKey('UpdateCheck')) {
        Remove-Job $script:updateJobs['UpdateCheck'] -Force -ErrorAction SilentlyContinue
        $script:updateJobs.Remove('UpdateCheck')
    }

    $script:UpdateState.Status = 'checking'
    $script:UpdateState.Message = 'Checking for updates...'
    $script:updateJobs['UpdateCheckAutomatic'] = [bool]$Automatic
    $script:updateJobs['UpdateCheck'] = Start-OverlayBackgroundJob -ScriptBlock $script:AppUpdateCheckScript -ArgumentList @($script:AppDir, $script:ErrLog)
    Sync-UpdateMenuItems

    if ($script:updateJobTimer -and -not $script:updateJobTimer.IsEnabled) {
        $script:updateJobTimer.Start()
    }

    return $true
}

function Invoke-AutomaticUpdateCheck {
    if (-not (Test-AppUpdateAutoCheckDue -Enabled ([bool]$script:Cfg.AutoCheckUpdates) -LastCheckedAt $script:UpdateState.CheckedAt)) {
        return $false
    }

    return Start-AppUpdateBackgroundCheck -Automatic
}

function Complete-AppUpdateCheckJobs {
    if (-not $script:updateJobs -or -not $script:updateJobs.ContainsKey('UpdateCheck')) { return $false }

    $job = $script:updateJobs['UpdateCheck']
    if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') { return $false }

    $automatic = [bool]$script:updateJobs['UpdateCheckAutomatic']
    $completed = $false

    try {
        $results = @(Receive-Job $job -ErrorAction SilentlyContinue)
        $info = $results | Where-Object { $_ -and $_.PSObject.Properties['Status'] } | Select-Object -Last 1
        if (-not $info) {
            $info = New-AppUpdateInfo -Status 'error' -Message 'Update check failed: no result returned.' -CurrentVersion $script:AppVersion
        }

        Set-AppUpdateState $info
        $script:Cfg.LastUpdateCheckAt = $script:UpdateState.CheckedAt
        Save-UnifiedState
        Sync-UpdateMenuItems

        if ($automatic) {
            if ($info.Status -eq 'available' -and (Test-AppUpdateNotificationDue -Info $info -LastNotifiedVersion $script:Cfg.LastNotifiedUpdateVersion)) {
                Show-AppUpdateMessage 'AI Usage Overlay Updates' $info.Message ([System.Windows.Forms.ToolTipIcon]::Info)
                $script:Cfg.LastNotifiedUpdateVersion = Get-AppUpdateVersionKey $info
                Save-UnifiedState
            } elseif ($info.Status -eq 'error') {
                try { Write-Log $info.Message } catch { }
            }
        } else {
            $icon = if ($info.Status -eq 'error') { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
            Show-AppUpdateMessage 'AI Usage Overlay Updates' $info.Message $icon
        }

        $completed = $true
    } catch {
        $info = New-AppUpdateInfo -Status 'error' -Message "Update check failed: $($_.Exception.Message)" -CurrentVersion $script:AppVersion
        Set-AppUpdateState $info
        $script:Cfg.LastUpdateCheckAt = $script:UpdateState.CheckedAt
        Save-UnifiedState
        Sync-UpdateMenuItems
        if ($automatic) {
            try { Write-Log $info.Message } catch { }
        } else {
            Show-AppUpdateMessage 'AI Usage Overlay Updates' $info.Message ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
        $completed = $true
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        $script:updateJobs.Remove('UpdateCheck')
        $script:updateJobs.Remove('UpdateCheckAutomatic')
        Sync-UpdateMenuItems
        if ($script:updateJobTimer -and -not (Test-AppUpdateCheckJobRunning)) {
            $script:updateJobTimer.Stop()
        }
    }

    return $completed
}

function Start-AutoUpdateChecks {
    Sync-UpdateMenuItems

    if (-not $script:updateJobTimer) {
        $script:updateJobTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateJobTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:updateJobTimer.add_Tick({ [void](Complete-AppUpdateCheckJobs) })
    }

    if (-not $script:updateStartupTimer) {
        $script:updateStartupTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateStartupTimer.Interval = [TimeSpan]::FromSeconds(20)
        $script:updateStartupTimer.add_Tick({
            $script:updateStartupTimer.Stop()
            [void](Invoke-AutomaticUpdateCheck)
        })
    }

    if (-not $script:updateAutoTimer) {
        $script:updateAutoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateAutoTimer.Interval = [TimeSpan]::FromMinutes(15)
        $script:updateAutoTimer.add_Tick({ [void](Invoke-AutomaticUpdateCheck) })
    }

    if ([bool]$script:Cfg.AutoCheckUpdates) {
        $script:updateStartupTimer.Start()
        $script:updateAutoTimer.Start()
    }
}

function Invoke-ManualUpdateCheck {
    [void](Start-AppUpdateBackgroundCheck)
}

function Invoke-InstallCheckedUpdate {
    if ($script:updateItems.ContainsKey('install')) { $script:updateItems['install'].Enabled = $false }

    $info = [pscustomobject]$script:UpdateState
    $result = Install-AppUpdate -Info $info
    Set-AppUpdateState $result
    Sync-UpdateMenuItems

    $icon = if ($result.Status -eq 'error') { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
    Show-AppUpdateMessage 'AI Usage Overlay Updates' $result.Message $icon
}

# ---------------------------------------------------------------------------
# Threshold alert system
# ---------------------------------------------------------------------------
$script:AlertKeys = @('five_hour', 'seven_day', 'seven_day_fable', 'seven_day_opus')
$script:Notified = @{}
foreach ($alertKey in $script:AlertKeys) {
    $script:Notified[$alertKey] = @{ Level = 0; Reset = $null }
}

function ConvertTo-AlertStateMap($value) {
    $map = @{}
    foreach ($alertKey in $script:AlertKeys) {
        $map[$alertKey] = @{ Level = 0; Reset = $null }
    }

    if ($null -eq $value) { return $map }

    foreach ($alertKey in $script:AlertKeys) {
        $entry = $null
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($alertKey)) { continue }
            $entry = $value[$alertKey]
        } else {
            $prop = $value.PSObject.Properties[$alertKey]
            if (-not $prop) { continue }
            $entry = $prop.Value
        }

        if ($null -eq $entry) { continue }

        if ($entry -is [System.Collections.IDictionary]) {
            $map[$alertKey] = @{
                Level = if ($entry.Contains('Level') -and $null -ne $entry['Level']) { [int]$entry['Level'] } else { 0 }
                Reset = if ($entry.Contains('Reset')) { $entry['Reset'] } else { $null }
            }
            continue
        }

        $levelProp = $entry.PSObject.Properties['Level']
        $resetProp = $entry.PSObject.Properties['Reset']
        if ($levelProp -or $resetProp) {
            $map[$alertKey] = @{
                Level = if ($levelProp -and $null -ne $levelProp.Value) { [int]$levelProp.Value } else { 0 }
                Reset = if ($resetProp) { $resetProp.Value } else { $null }
            }
            continue
        }

        $map[$alertKey] = @{ Level = [int]$entry; Reset = $null }
    }

    return $map
}

function Export-AlertStateToConfig {
    if (-not $script:Cfg) { return }
    $script:Cfg['AlertState'] = ConvertTo-AlertStateMap $script:Notified
}

function Import-AlertStateFromConfig {
    if (-not $script:Cfg) { return }
    $script:Notified = ConvertTo-AlertStateMap $script:Cfg.AlertState
    Export-AlertStateToConfig
}

Import-AlertStateFromConfig

function Get-AlertLabel([string]$key) {
    switch ($key) {
        'five_hour'        { '5-hour session' }
        'seven_day'        { 'Weekly limit' }
        'seven_day_fable'  { 'Fable weekly' }
        'seven_day_opus'   { 'Opus weekly' }
        default            { $key }
    }
}

function Get-AlertResetWindow([string]$key, $resetAt = $null) {
    if ($null -eq $resetAt -and $script:State -and $script:State.Data) {
        $quota = $script:State.Data.PSObject.Properties[$key]
        if ($quota -and $quota.Value) {
            $resetProp = $quota.Value.PSObject.Properties['resets_at']
            if ($resetProp) { $resetAt = $resetProp.Value }
        }
    }

    if ($null -eq $resetAt) { return $null }
    return [string]$resetAt
}

function Get-AlertState([string]$key, $resetWindow = $null) {
    if (-not $script:Notified) { $script:Notified = @{} }
    if (-not $script:Notified.ContainsKey($key)) {
        $script:Notified[$key] = @{ Level = 0; Reset = $resetWindow }
    }

    $state = $script:Notified[$key]
    if ($state -isnot [System.Collections.IDictionary]) {
        $state = @{ Level = [int]$state; Reset = $resetWindow }
        $script:Notified[$key] = $state
    } elseif ($resetWindow -and $state['Reset'] -and $state['Reset'] -ne $resetWindow) {
        $state['Level'] = 0
        $state['Reset'] = $resetWindow
    } elseif ($resetWindow -and -not $state['Reset']) {
        $state['Reset'] = $resetWindow
    }

    return $state
}

function Set-AlertState([string]$key, [int]$level, $resetWindow = $null) {
    $state = Get-AlertState $key $resetWindow
    $oldLevel = [int]$state['Level']
    $oldReset = $state['Reset']
    $state['Level'] = $level
    $state['Reset'] = $resetWindow
    Export-AlertStateToConfig
    if (($oldLevel -ne $level -or $oldReset -ne $resetWindow) -and (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue)) {
        Save-UnifiedState
    }
}

function Get-AlertLevel($util) {
    if ($null -eq $util) { return 0 }
    $u = [double]$util
    if ($u -ge $script:CritPct) { return [int]$script:CritPct }
    if ($u -ge $script:WarnPct) { return [int]$script:WarnPct }
    return 0
}

function Invoke-TestAlert {
    if (-not $script:notify) { return }
    $script:notify.ShowBalloonTip(
        4000,
        'AI Usage Overlay Test',
        'Threshold alerts are working.',
        [System.Windows.Forms.ToolTipIcon]::Info
    )
}

function Dismiss-CurrentAlerts {
    if (-not $script:State -or -not $script:State.Data) { return }

    foreach ($key in $script:AlertKeys) {
        $quota = $script:State.Data.PSObject.Properties[$key]
        if (-not $quota -or -not $quota.Value) { continue }

        $utilProp = $quota.Value.PSObject.Properties['utilization']
        if (-not $utilProp) { continue }

        $level = Get-AlertLevel $utilProp.Value
        if ($level -le 0) { continue }

        $resetProp = $quota.Value.PSObject.Properties['resets_at']
        $resetWindow = if ($resetProp) { Get-AlertResetWindow $key $resetProp.Value } else { Get-AlertResetWindow $key }
        Set-AlertState $key $level $resetWindow
    }
}

function Check-Alert([string]$key, $util, $resetAt = $null) {
    if (-not [bool]$script:Cfg.ShowAlerts) { return }
    if (-not $script:notify) { return }
    if ($null -eq $util) { return }

    $u = [double]$util
    $resetWindow = Get-AlertResetWindow $key $resetAt
    $state = Get-AlertState $key $resetWindow
    $last = [int]$state['Level']

    # Reset when usage drops back below warn threshold
    if ($u -lt $script:WarnPct) {
        Set-AlertState $key 0 $resetWindow
        return
    }

    # Fire CRITICAL alert (crosses into CritPct band)
    if ($u -ge $script:CritPct -and $last -lt $script:CritPct) {
        $label = Get-AlertLabel $key
        $eta = ''
        if ($script:History -and $script:History.Count -gt 2) {
            $mins = Get-Eta $script:History $key
            if ($null -ne $mins) { $eta = " (~$mins min to limit)" }
        }
        $script:notify.ShowBalloonTip(5000, 'Claude Usage Critical', "$label at $([int]$u)%$eta", [System.Windows.Forms.ToolTipIcon]::Warning)
        Set-AlertState $key ([int]$script:CritPct) $resetWindow
        return
    }

    # Fire WARN alert (crosses into WarnPct band)
    if ($u -ge $script:WarnPct -and $last -lt $script:WarnPct) {
        $label = Get-AlertLabel $key
        $script:notify.ShowBalloonTip(4000, 'Claude Usage Warning', "$label at $([int]$u)%", [System.Windows.Forms.ToolTipIcon]::Info)
        Set-AlertState $key ([int]$script:WarnPct) $resetWindow
        return
    }
}

# ---------------------------------------------------------------------------
# Context menu items
# ---------------------------------------------------------------------------

# Actions
[void]$script:ctxStrip.Items.Add((New-StripItem 'Refresh now' { Invoke-ManualRefresh }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Test alert' { Invoke-TestAlert }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Dismiss current alert' { Dismiss-CurrentAlerts }))
Add-Separator
[void]$script:ctxStrip.Items.Add((New-StripItem 'Copy stats to clipboard' { Copy-Stats }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Open claude.ai/usage' { Start-Process 'https://claude.ai/settings/usage' }))
Add-Separator

# Updates
$miAutoUpdate = New-StripItem 'Automatically check for updates' {
    $script:Cfg.AutoCheckUpdates = -not [bool]$script:Cfg.AutoCheckUpdates
    $miAutoUpdate.Checked = [bool]$script:Cfg.AutoCheckUpdates
    Save-UnifiedState

    if ([bool]$script:Cfg.AutoCheckUpdates) {
        if ($script:updateAutoTimer) { $script:updateAutoTimer.Start() }
        if ($script:updateStartupTimer -and -not $script:UpdateState.CheckedAt) { $script:updateStartupTimer.Start() }
        [void](Invoke-AutomaticUpdateCheck)
    } else {
        if ($script:updateAutoTimer) { $script:updateAutoTimer.Stop() }
        if ($script:updateStartupTimer) { $script:updateStartupTimer.Stop() }
    }

    Sync-UpdateMenuItems
}
$miAutoUpdate.CheckOnClick = $false
$miAutoUpdate.Checked = [bool]$script:Cfg.AutoCheckUpdates
$script:updateItems['auto'] = $miAutoUpdate
[void]$script:ctxStrip.Items.Add($miAutoUpdate)

$miCheckUpdate = New-StripItem 'Check for updates' { Invoke-ManualUpdateCheck }
$script:updateItems['check'] = $miCheckUpdate
[void]$script:ctxStrip.Items.Add($miCheckUpdate)

$miInstallUpdate = New-StripItem 'Install update' { Invoke-InstallCheckedUpdate }
$miInstallUpdate.Enabled = $false
$script:updateItems['install'] = $miInstallUpdate
[void]$script:ctxStrip.Items.Add($miInstallUpdate)

$miUpdateStatus = New-StripItem 'Update status: unknown' $null
$miUpdateStatus.Enabled = $false
$script:updateItems['status'] = $miUpdateStatus
[void]$script:ctxStrip.Items.Add($miUpdateStatus)
Sync-UpdateMenuItems
Add-Separator

# Sections
foreach ($pair in @(@('Show/Hide Claude','claude'), @('Show/Hide Codex','codex'), @('Show/Hide Cursor','cursor'))) {
    $label = $pair[0]
    $key = $pair[1]
    $item = New-StripItem $label ([scriptblock]::Create("`$visible = -not (Get-SectionVisible '$key'); Set-SectionVisible '$key' `$visible; `$script:Cfg.Sections['$key'] = `$visible; Save-UnifiedState; Sync-SectionMenuItems"))
    $item.CheckOnClick = $false
    $item.Checked = Get-SectionVisible $key
    $script:sectionItems[$key] = $item
    [void]$script:ctxStrip.Items.Add($item)
}

# View mode: pinned panel vs Quake-style drop-down on a global hotkey
$script:viewModeItems = @{}
function Sync-ViewModeMenuItems {
    $mode = if (Test-DropdownMode) { 'Quake' } else { 'Pinned' }
    foreach ($k in @($script:viewModeItems.Keys)) { $script:viewModeItems[$k].Checked = ($k -eq $mode) }
    if ($script:dropdownHotkeyItems) {
        $cur = [string]$script:Cfg['DropdownHotkey']
        foreach ($k in @($script:dropdownHotkeyItems.Keys)) { $script:dropdownHotkeyItems[$k].Checked = ($k -eq $cur) }
    }
    if ($script:dropdownMonitorItems) {
        $cur = [string]$script:Cfg['DropdownMonitor']
        foreach ($k in @($script:dropdownMonitorItems.Keys)) { $script:dropdownMonitorItems[$k].Checked = ($k -eq $cur) }
    }
}

$miView = New-StripItem 'View' $null
foreach ($pair in @(@('Pinned panel', 'Pinned'), @('Quake terminal (hotkey)', 'Quake'))) {
    $lbl = $pair[0]; $mode = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create(
        "if ('$mode' -eq 'Quake') { Enter-DropdownMode } else { Exit-DropdownMode }; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:viewModeItems[$mode] = $sub
    [void]$miView.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Hotkey presets. Any combo the parser understands can be set in the state file;
# these are the ones unlikely to collide with editors or browsers.
$script:dropdownHotkeyItems = @{}
$miHotkey = New-StripItem 'Drop-down hotkey' $null
foreach ($combo in @('Shift+F11', 'Shift+F12', 'Ctrl+Alt+`', 'Ctrl+Alt+U', 'Win+`')) {
    $c = $combo
    $sub = New-StripItem $c ([scriptblock]::Create("Set-DropdownHotkey '$c'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownHotkeyItems[$c] = $sub
    [void]$miHotkey.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add($miHotkey)

# Monitor picker, built from the live screen list so labels show real resolutions.
$script:dropdownMonitorItems = @{}
$miMonitor = New-StripItem 'Drop-down monitor' $null
foreach ($pair in @(@('Primary', 'Primary'), @('Monitor with mouse', 'Active'))) {
    $lbl = $pair[0]; $val = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("Set-DropdownMonitor '$val'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownMonitorItems[$val] = $sub
    [void]$miMonitor.DropDownItems.Add($sub)
}
[void]$miMonitor.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$screenIndex = 0
foreach ($scr in (Get-DropdownScreens)) {
    $screenIndex++
    $dev = $scr.DeviceName
    $lbl = '{0}: {1}x{2}{3}' -f $screenIndex, $scr.Bounds.Width, $scr.Bounds.Height, $(if ($scr.Primary) { ' (primary)' } else { '' })
    $sub = New-StripItem $lbl ([scriptblock]::Create("Set-DropdownMonitor '$dev'; Save-UnifiedState; Sync-ViewModeMenuItems"))
    $sub.CheckOnClick = $false
    $script:dropdownMonitorItems[$dev] = $sub
    [void]$miMonitor.DropDownItems.Add($sub)
}
[void]$miView.DropDownItems.Add($miMonitor)

$miHideFocus = New-StripItem 'Hide when it loses focus' {
    $script:Cfg['DropdownHideOnFocusLoss'] = -not [bool]$script:Cfg['DropdownHideOnFocusLoss']
    $miHideFocus.Checked = [bool]$script:Cfg['DropdownHideOnFocusLoss']
    Save-UnifiedState
}
$miHideFocus.CheckOnClick = $false
$miHideFocus.Checked = [bool]$script:Cfg['DropdownHideOnFocusLoss']
[void]$miView.DropDownItems.Add($miHideFocus)
[void]$script:ctxStrip.Items.Add($miView)
Sync-ViewModeMenuItems
Add-Separator

# Snap to corner
$miSnap = New-StripItem 'Snap to corner' $null
foreach ($pair in @(@('Top right','TR'), @('Top left','TL'), @('Bottom right','BR'), @('Bottom left','BL'))) {
    $lbl = $pair[0]; $key = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("Snap-ToCorner '$key'"))
    [void]$miSnap.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miSnap)

# Opacity
$miOp = New-StripItem 'Opacity' $null
foreach ($pair in @(@('100%',1.0), @('80%',0.8), @('60%',0.6), @('40%',0.4))) {
    $lbl = $pair[0]; $val = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("`$script:Cfg.Opacity=$val; Apply-UnifiedSettings; Save-UnifiedState; foreach(`$x in `$script:opacityItems.Values){`$x.Checked=`$false}; `$script:opacityItems['$lbl'].Checked=`$true"))
    $sub.CheckOnClick = $false
    $sub.Checked = ([double]$script:Cfg.Opacity -eq [double]$val)
    $script:opacityItems[$lbl] = $sub
    [void]$miOp.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miOp)

# Themes
$miTheme = New-StripItem 'Theme' $null
foreach ($tname in $script:Themes.Keys) {
    $tn  = $tname
    $sub = New-StripItem $tname ([scriptblock]::Create("`$script:Cfg.Theme='$tn'; Apply-UnifiedTheme '$tn'; Save-UnifiedState; foreach(`$x in `$script:themeItems.Values){`$x.Checked=`$false}; `$script:themeItems['$tn'].Checked=`$true"))
    $sub.CheckOnClick = $false
    $sub.Checked = ($tname -eq $script:Cfg.Theme)
    $script:themeItems[$tname] = $sub
    [void]$miTheme.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miTheme)
Add-Separator

# Toggles
$miStats = New-StripItem 'Show stats panel' {
    $script:Cfg.ShowStats = -not [bool]$script:Cfg.ShowStats
    $miStats.Checked = [bool]$script:Cfg.ShowStats
    Apply-UnifiedSettings; Save-UnifiedState
}
$miStats.Checked = [bool]$script:Cfg.ShowStats
[void]$script:ctxStrip.Items.Add($miStats)

$miCompact = New-StripItem 'Compact mode' {
    $script:Cfg.Compact = -not [bool]$script:Cfg.Compact
    $miCompact.Checked = [bool]$script:Cfg.Compact
    Apply-UnifiedSettings
    Update-AllSections
    Resize-ToContent
    Save-UnifiedState
}
$miCompact.Checked = [bool]$script:Cfg.Compact
[void]$script:ctxStrip.Items.Add($miCompact)

$miAlerts = New-StripItem 'Threshold alerts' {
    $script:Cfg.ShowAlerts = -not [bool]$script:Cfg.ShowAlerts
    $miAlerts.Checked = [bool]$script:Cfg.ShowAlerts
    Save-UnifiedState
}
$miAlerts.Checked = [bool]$script:Cfg.ShowAlerts
[void]$script:ctxStrip.Items.Add($miAlerts)

$miGraph = New-StripItem 'Show history graph' {
    $script:Cfg.ShowGraph = -not [bool]$script:Cfg.ShowGraph
    $miGraph.Checked = [bool]$script:Cfg.ShowGraph
    Apply-UnifiedSettings; Save-UnifiedState
    Update-AllSections
}
$miGraph.Checked = [bool]$script:Cfg.ShowGraph
[void]$script:ctxStrip.Items.Add($miGraph)
Add-Separator

# Login
$script:miLogin = New-StripItem 'Open at login' {
    if (Test-Autostart) { Uninstall-Autostart } else { Install-Autostart }
    $script:miLogin.Checked = (Test-Autostart)
}
$script:miLogin.Checked = (Test-Autostart)
[void]$script:ctxStrip.Items.Add($script:miLogin)

$miSH = New-StripItem 'Start hidden to tray' {
    $script:Cfg.StartHidden = -not [bool]$script:Cfg.StartHidden
    $miSH.Checked = [bool]$script:Cfg.StartHidden
    Save-UnifiedState
}
$miSH.Checked = [bool]$script:Cfg.StartHidden
[void]$script:ctxStrip.Items.Add($miSH)
Add-Separator

# Window
[void]$script:ctxStrip.Items.Add((New-StripItem 'Minimize to tray' { $script:window.Hide() }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Quit' { Quit-App }))

# ---------------------------------------------------------------------------
# Tray icon - left-click toggles the unified window
# ---------------------------------------------------------------------------
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $grd = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 1,1),(New-Object System.Drawing.Point 31,31),
        [System.Drawing.Color]::FromArgb(255,30,58,138),[System.Drawing.Color]::FromArgb(255,109,40,217))
    $g.FillEllipse($grd,1,1,30,30)
    $fnt = New-Object System.Drawing.Font('Bahnschrift',11,[System.Drawing.FontStyle]::Bold)
    $sf  = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('AI',$fnt,[System.Drawing.Brushes]::White,(New-Object System.Drawing.RectangleF(0,0,32,32)),$sf)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = New-TrayIcon
$script:notify.Text = 'AI Usage  (left-click to show)'
$script:notify.ContextMenuStrip = $script:ctxStrip
$script:notify.Visible = $true
$script:notify.add_MouseClick({ param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window }
})
