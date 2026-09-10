# Tray.ps1 - system tray icon, dark context menu, threshold alert balloons

# ---------------------------------------------------------------------------
# Window events - wired per window instance (called by Build-And-Show on each build)
# ---------------------------------------------------------------------------
function Wire-WindowEvents {
    $script:window.Add_MouseLeftButtonDown({ try { $script:window.DragMove() } catch { Write-Log "DragMove error: $($_.Exception.Message)" }; Save-State })
    $script:window.Add_Loaded({ Position-Window })
    $script:window.Add_Closing({ param($s, $e) if (-not $script:ReallyQuit) { $e.Cancel = $true; $script:window.Hide() } })
    $script:window.Add_MouseRightButtonUp({
        param($s, $e)
        Show-ContextMenuAtWpfPointer $e
    })
}

function Toggle-Window {
    if ($script:window.IsVisible) { $script:window.Hide() }
    else { $script:window.Show(); $script:window.Activate(); $script:window.Topmost = $true }
}

function Get-ContextMenuScreenPoint {
    # ContextMenuStrip.Show and Control.MousePosition share WinForms screen
    # coordinates. WPF PointToScreen can use a different DPI coordinate space.
    return [System.Windows.Forms.Control]::MousePosition
}

function Show-ContextMenuAtWpfPointer {
    param($EventArgs)

    $pt = Get-ContextMenuScreenPoint
    $EventArgs.Handled = $true
    $script:ctxStrip.Show($pt)
}

function Quit-App {
    $script:ReallyQuit = $true
    if ($script:pollTimer) { $script:pollTimer.Stop() }
    if ($script:tickTimer) { $script:tickTimer.Stop() }
    if ($script:notify)    { $script:notify.Visible = $false; $script:notify.Dispose() }
    $script:window.Close()
    $script:window.Dispatcher.InvokeShutdown()
}

# ---------------------------------------------------------------------------
# Right-click context menu - dark-themed WinForms ContextMenuStrip shown
# from the WPF panel's MouseRightButtonUp event.
# ---------------------------------------------------------------------------
$script:themeItems  = @{}
$script:opacityItems = @{}

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

# ---------------------------------------------------------------------------
# Threshold alert system
# ---------------------------------------------------------------------------
$script:Notified = @{ five_hour = 0; seven_day = 0; seven_day_fable = 0; seven_day_opus = 0 }

function Check-Alert([string]$key, $util) {
    if (-not [bool]$script:Cfg.ShowAlerts) { return }
    if (-not $script:notify) { return }
    if ($null -eq $util) { return }

    $u    = [double]$util
    $last = if ($script:Notified.ContainsKey($key)) { $script:Notified[$key] } else { 0 }

    # Reset when usage drops back below warn threshold
    if ($u -lt $script:WarnPct) {
        $script:Notified[$key] = 0
        return
    }

    # Fire CRITICAL alert (crosses into CritPct band)
    if ($u -ge $script:CritPct -and $last -lt $script:CritPct) {
        $label = switch ($key) {
            'five_hour'        { '5-hour session' }
            'seven_day'        { 'Weekly limit' }
            'seven_day_fable'  { 'Fable weekly' }
            'seven_day_opus'   { 'Opus weekly' }
            default            { $key }
        }
        $eta = ''
        if ($script:History -and $script:History.Count -gt 2) {
            $mins = Get-Eta $script:History $key
            if ($null -ne $mins) { $eta = " (~$mins min to limit)" }
        }
        $script:notify.ShowBalloonTip(5000, 'Claude Usage Critical', "$label at $([int]$u)%$eta", [System.Windows.Forms.ToolTipIcon]::Warning)
        $script:Notified[$key] = $script:CritPct
        return
    }

    # Fire WARN alert (crosses into WarnPct band)
    if ($u -ge $script:WarnPct -and $last -lt $script:WarnPct) {
        $label = switch ($key) {
            'five_hour'        { '5-hour session' }
            'seven_day'        { 'Weekly limit' }
            'seven_day_fable'  { 'Fable weekly' }
            'seven_day_opus'   { 'Opus weekly' }
            default            { $key }
        }
        $script:notify.ShowBalloonTip(4000, 'Claude Usage Warning', "$label at $([int]$u)%", [System.Windows.Forms.ToolTipIcon]::Info)
        $script:Notified[$key] = $script:WarnPct
        return
    }
}

# ---------------------------------------------------------------------------
# Context menu items
# ---------------------------------------------------------------------------

# Actions
[void]$script:ctxStrip.Items.Add((New-StripItem 'Refresh now'             { Get-Usage; Get-Stats; Update-UI }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Copy stats to clipboard' { Copy-Stats }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Open claude.ai/usage'    { Start-Process 'https://claude.ai/new#settings/usage' }))
Add-Separator

# Snap to corner
$miSnap = New-StripItem 'Snap to corner' $null
foreach ($pair in @(('Top right','TR'),('Top left','TL'),('Bottom right','BR'),('Bottom left','BL'))) {
    $lbl = $pair[0]; $key = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("Snap-ToCorner '$key'"))
    [void]$miSnap.DropDownItems.Add($sub)
}
[void]$script:ctxStrip.Items.Add($miSnap)

# Opacity
$miOp = New-StripItem 'Opacity' $null
foreach ($pair in @(('100%',1.0),('80%',0.8),('60%',0.6),('40%',0.4))) {
    $lbl = $pair[0]; $val = $pair[1]
    $sub = New-StripItem $lbl ([scriptblock]::Create("`$script:Cfg.Opacity=$val; Apply-Settings; Save-State; foreach(`$x in `$script:opacityItems.Values){`$x.Checked=`$false}; `$script:opacityItems['$lbl'].Checked=`$true"))
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
    $sub = New-StripItem $tname ([scriptblock]::Create("`$script:Cfg.Theme='$tn'; Apply-Theme '$tn'; Save-State; foreach(`$x in `$script:themeItems.Values){`$x.Checked=`$false}; `$script:themeItems['$tn'].Checked=`$true"))
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
    Apply-Settings; Save-State
}
$miStats.Checked = [bool]$script:Cfg.ShowStats
[void]$script:ctxStrip.Items.Add($miStats)

$script:miLogin = New-StripItem 'Open at login' {
    if (Test-Autostart) { Uninstall-Autostart } else { Install-Autostart }
    $script:miLogin.Checked = (Test-Autostart)
}
$script:miLogin.Checked = (Test-Autostart)
[void]$script:ctxStrip.Items.Add($script:miLogin)

$miSH = New-StripItem 'Start hidden to tray' {
    $script:Cfg.StartHidden = -not [bool]$script:Cfg.StartHidden
    $miSH.Checked = [bool]$script:Cfg.StartHidden; Save-State
}
$miSH.Checked = [bool]$script:Cfg.StartHidden
[void]$script:ctxStrip.Items.Add($miSH)

$miAlerts = New-StripItem 'Threshold alerts' {
    $script:Cfg.ShowAlerts = -not [bool]$script:Cfg.ShowAlerts
    $miAlerts.Checked = [bool]$script:Cfg.ShowAlerts; Save-State
}
$miAlerts.Checked = [bool]$script:Cfg.ShowAlerts
[void]$script:ctxStrip.Items.Add($miAlerts)

$miGraph = New-StripItem 'Show history graph' {
    $script:Cfg.ShowGraph = -not [bool]$script:Cfg.ShowGraph
    $miGraph.Checked = [bool]$script:Cfg.ShowGraph
    Apply-Settings; Save-State
    Update-UI   # populate sparklines immediately instead of waiting for next tick
}
$miGraph.Checked = [bool]$script:Cfg.ShowGraph
[void]$script:ctxStrip.Items.Add($miGraph)

Add-Separator

# Window
[void]$script:ctxStrip.Items.Add((New-StripItem 'Minimize to tray' { $script:window.Hide() }))
[void]$script:ctxStrip.Items.Add((New-StripItem 'Quit'             { Quit-App }))

# ---------------------------------------------------------------------------
# Tray icon - left-click only (full menu is on the panel)
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
    $fnt = New-Object System.Drawing.Font('Bahnschrift',14,[System.Drawing.FontStyle]::Bold)
    $sf  = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('C',$fnt,[System.Drawing.Brushes]::White,(New-Object System.Drawing.RectangleF(0,0,32,32)),$sf)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon    = New-TrayIcon
$script:notify.Text    = 'Claude Usage  (left-click to show)'
$script:notify.Visible = $true
$script:notify.add_MouseClick({ param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Window }
})
