# ProviderPicker.ps1 - first-run / tray provider chooser (MS-PRODUCTIZE-OVERLAY)
# Calm WinForms checklist. Persists via Cfg.Sections + Save-UnifiedState.

function Get-DefaultUnifiedSections {
    # Demo / stranger path: Claude off until chosen. Codex/Cursor/Grok on.
    @{
        claude = $false
        codex  = $true
        cursor = $true
        grok   = $true
    }
}

function Test-UnifiedFirstRun {
    if (-not $script:StatePath) { return $false }
    return -not (Test-Path -LiteralPath $script:StatePath)
}

function Apply-ProviderSections {
    param($Sections)

    if (-not $script:Cfg) { $script:Cfg = @{} }
    if (Get-Command Initialize-UnifiedCfg -ErrorAction SilentlyContinue) {
        Initialize-UnifiedCfg
    }
    if (Get-Command ConvertTo-UnifiedSectionsMap -ErrorAction SilentlyContinue) {
        $script:Cfg['Sections'] = ConvertTo-UnifiedSectionsMap $Sections
    } else {
        $script:Cfg['Sections'] = $Sections
    }

    if (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue) {
        Save-UnifiedState
    }
    if (Get-Command Apply-UnifiedSettings -ErrorAction SilentlyContinue) {
        Apply-UnifiedSettings
    }
    if (Get-Command Sync-SectionMenuItems -ErrorAction SilentlyContinue) {
        Sync-SectionMenuItems
    }
    if (Get-Command Update-AllSections -ErrorAction SilentlyContinue) {
        Update-AllSections
    }
    if (Get-Command Resize-ToContent -ErrorAction SilentlyContinue) {
        Resize-ToContent
    }
}

function New-ProviderPickerForm {
    # Layout is driven entirely by AutoSize panels so the dialog fits at any DPI / font size.
    param($Initial = $null, [double]$FontSize = 10)

    $map = if (Get-Command ConvertTo-UnifiedSectionsMap -ErrorAction SilentlyContinue) {
        ConvertTo-UnifiedSectionsMap $(if ($null -ne $Initial) { $Initial } else { Get-DefaultUnifiedSections })
    } elseif ($null -ne $Initial) {
        $Initial
    } else {
        Get-DefaultUnifiedSections
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AI Usage Overlay'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', $FontSize)
    $em = $form.Font.Height
    $form.Padding = New-Object System.Windows.Forms.Padding([int]($em * 1.2), [int]($em * 0.9), [int]($em * 1.2), [int]($em * 0.9))

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.AutoSize = $true
    $root.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $root.ColumnCount = 1
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.BackColor = $form.BackColor

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Which providers do you use?'
    $title.AutoSize = $true
    $title.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', ($FontSize * 1.1))
    $title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int]($em * 0.3))

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Hidden tiles stay quiet. Change anytime from the tray > Providers.'
    $hint.AutoSize = $true
    # Wrap the hint to the title's width so the dialog stays compact at any scale.
    $hint.MaximumSize = New-Object System.Drawing.Size([Math]::Max($title.PreferredSize.Width, [int]($em * 14)), 0)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $hint.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int]($em * 0.6))

    $list = New-Object System.Windows.Forms.FlowLayoutPanel
    $list.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $list.WrapContents = $false
    $list.AutoSize = $true
    $list.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $list.Margin = New-Object System.Windows.Forms.Padding([int]($em * 0.4), 0, 0, [int]($em * 0.6))

    $checks = @{}
    foreach ($pair in @(
        @('codex', 'Codex'),
        @('cursor', 'Cursor'),
        @('grok', 'Grok'),
        @('claude', 'Claude')
    )) {
        $key = $pair[0]
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $pair[1]
        $cb.Checked = [bool]$map[$key]
        $cb.AutoSize = $true
        $cb.ForeColor = $form.ForeColor
        $cb.BackColor = $form.BackColor
        $cb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int]($em * 0.25))
        $checks[$key] = $cb
        [void]$list.Controls.Add($cb)
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Continue'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.AutoSize = $true
    $ok.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $ok.Padding = New-Object System.Windows.Forms.Padding([int]($em * 0.9), [int]($em * 0.2), [int]($em * 0.9), [int]($em * 0.2))
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $ok.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $ok.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 95)
    $ok.ForeColor = $form.ForeColor

    [void]$root.Controls.Add($title)
    [void]$root.Controls.Add($hint)
    [void]$root.Controls.Add($list)
    [void]$root.Controls.Add($ok)
    [void]$form.Controls.Add($root)
    $form.AcceptButton = $ok

    return @{ Form = $form; Checks = $checks }
}

function Show-ProviderPickerDialog {
    param($Initial = $null)

    $picker = New-ProviderPickerForm -Initial $Initial
    $form = $picker.Form
    $checks = $picker.Checks

    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $out = @{}
    foreach ($key in @('claude', 'codex', 'cursor', 'grok')) {
        $out[$key] = [bool]$checks[$key].Checked
    }
    # Keep at least one tile so the HUD isn't an empty shell.
    $any = $false
    foreach ($v in $out.Values) { if ($v) { $any = $true; break } }
    if (-not $any) { $out['cursor'] = $true }
    return $out
}

function Invoke-ProviderPickerFromTray {
    $initial = if ($script:Cfg -and $script:Cfg.Sections) { $script:Cfg.Sections } else { Get-DefaultUnifiedSections }
    $choice = Show-ProviderPickerDialog -Initial $initial
    if ($null -eq $choice) { return }
    Apply-ProviderSections $choice
}

function Invoke-FirstRunProviderPickerIfNeeded {
    if (-not (Test-UnifiedFirstRun)) { return }
    $choice = Show-ProviderPickerDialog -Initial (Get-DefaultUnifiedSections)
    if ($null -eq $choice) {
        $choice = Get-DefaultUnifiedSections
    }
    Apply-ProviderSections $choice
}
