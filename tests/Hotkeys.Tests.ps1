#Requires -Module Pester

Describe 'Hotkey combo parsing' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    It 'parses the shipped drop-down default' {
        $spec = ConvertTo-HotkeySpec 'Shift+F11'

        $spec.Vk | Should -Be 0x7A
        ($spec.Mods -band 4)      | Should -Be 4        # MOD_SHIFT
        ($spec.Mods -band 0x4000) | Should -Be 0x4000   # MOD_NOREPEAT
    }

    It 'combines every modifier in a multi-part combo' {
        $spec = ConvertTo-HotkeySpec 'Ctrl+Alt+`'

        $spec.Vk | Should -Be 0xC0
        ($spec.Mods -band 3) | Should -Be 3            # MOD_ALT | MOD_CONTROL
    }

    It 'ignores case differences' {
        $lower = ConvertTo-HotkeySpec 'shift+f11'
        $upper = ConvertTo-HotkeySpec 'SHIFT+F11'

        $lower.Mods | Should -Be $upper.Mods
        $lower.Vk   | Should -Be $upper.Vk
    }

    It 'treats an unbound binding as no spec at all' -ForEach @(
        @{ Combo = '' }, @{ Combo = '   ' }, @{ Combo = $null }
    ) {
        ConvertTo-HotkeySpec $Combo | Should -BeNullOrEmpty
    }

    It 'rejects a combo it cannot map to a virtual key' -ForEach @(
        @{ Combo = 'Meta+F11' }, @{ Combo = 'Ctrl+Alt+Backspace' }, @{ Combo = 'Shift' }
    ) {
        ConvertTo-HotkeySpec $Combo | Should -BeNullOrEmpty
    }
}

Describe 'Hotkey action table' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\UnifiedState.ps1')
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    It 'covers the drop-down, show/hide and refresh actions' {
        $names = @(Get-HotkeyActionNames)

        $names | Should -Contain 'Dropdown'
        $names | Should -Contain 'Toggle'
        $names | Should -Contain 'Refresh'
    }

    It 'keeps the original drop-down id so that binding is unchanged' {
        (Get-HotkeyAction 'Dropdown').Id | Should -Be 0x4149
    }

    It 'gives every action its own id' {
        $ids = @(Get-HotkeyActionNames | ForEach-Object { [int](Get-HotkeyAction $_).Id })

        $ids.Count | Should -BeGreaterThan 1
        (@($ids | Sort-Object -Unique)).Count | Should -Be $ids.Count
    }

    It 'points every action at a config key that has a default' {
        foreach ($name in (Get-HotkeyActionNames)) {
            $key = [string](Get-HotkeyAction $name).ConfigKey
            $script:UnifiedCfgDefaults.ContainsKey($key) | Should -BeTrue -Because "$name stores its combo in $key"
        }
    }

    It 'leaves both new bindings unbound out of the box' {
        $script:UnifiedCfgDefaults[(Get-HotkeyAction 'Toggle').ConfigKey]  | Should -Be ''
        $script:UnifiedCfgDefaults[(Get-HotkeyAction 'Refresh').ConfigKey] | Should -Be ''
    }

    It 'keeps the drop-down default combo' {
        $script:UnifiedCfgDefaults[(Get-HotkeyAction 'Dropdown').ConfigKey] | Should -Be 'Shift+F11'
    }

    It 'restricts only the drop-down binding to the quake view' {
        [bool](Get-HotkeyAction 'Dropdown').DropdownModeOnly | Should -BeTrue
        [bool](Get-HotkeyAction 'Toggle').DropdownModeOnly   | Should -BeFalse
        [bool](Get-HotkeyAction 'Refresh').DropdownModeOnly  | Should -BeFalse
    }

    It 'returns nothing for an action name it does not know' {
        Get-HotkeyAction 'NoSuchAction' | Should -BeNullOrEmpty
        Get-HotkeyAction '' | Should -BeNullOrEmpty
    }
}

Describe 'Hotkey registration' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) $script:HotkeyLog.Add([string]$Message) }
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    BeforeEach {
        $script:HotkeyLog   = [System.Collections.Generic.List[string]]::new()
        $script:HotkeyCalls = [System.Collections.Generic.List[object]]::new()
        $script:HotkeyTaken = @()      # virtual keys a "different app" already owns

        $script:Cfg = @{
            ViewMode            = 'Pinned'
            DropdownHotkey      = 'Shift+F11'
            ToggleOverlayHotkey = ''
            RefreshHotkey       = ''
        }

        # Stands in for AIUsageGlobalHotkey: records the calls and decides which
        # combos RegisterHotKey would refuse, without touching the real OS table.
        $owner = [pscustomobject]@{}
        $owner | Add-Member ScriptMethod Register {
            param($id, $modifiers, $vk)
            $script:HotkeyCalls.Add([pscustomobject]@{
                Op = 'Register'; Id = [int]$id; Mods = [uint32]$modifiers; Vk = [int]$vk
            })
            return (-not ($script:HotkeyTaken -contains [int]$vk))
        }
        $owner | Add-Member ScriptMethod Unregister {
            param($id)
            $script:HotkeyCalls.Add([pscustomobject]@{ Op = 'Unregister'; Id = [int]$id })
        }
        $script:HotkeyOwner = $owner
    }

    It 'registers nothing and says nothing when a binding is unbound' {
        Register-OverlayHotkey 'Toggle' | Should -BeFalse

        @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' }).Count | Should -Be 0
        $script:HotkeyLog.Count | Should -Be 0
    }

    It 'releases the previous combo when a binding is cleared' {
        [void](Register-OverlayHotkey 'Toggle')

        $released = @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Unregister' })
        $released.Count | Should -Be 1
        $released[0].Id | Should -Be ([int](Get-HotkeyAction 'Toggle').Id)
    }

    It 'unregisters the old combo before claiming a new one' {
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'

        Register-OverlayHotkey 'Toggle' | Should -BeTrue

        $script:HotkeyCalls.Count | Should -Be 2
        $script:HotkeyCalls[0].Op | Should -Be 'Unregister'
        $script:HotkeyCalls[1].Op | Should -Be 'Register'
        $script:HotkeyCalls[1].Id | Should -Be ([int](Get-HotkeyAction 'Toggle').Id)
        $script:HotkeyCalls[1].Vk | Should -Be 0x41
    }

    It 'logs and carries on when the combo is not one it recognises' {
        $script:Cfg['RefreshHotkey'] = 'Ctrl+Alt+Backspace'

        Register-OverlayHotkey 'Refresh' | Should -BeFalse

        @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' }).Count | Should -Be 0
        $script:HotkeyLog.Count | Should -Be 1
        $script:HotkeyLog[0] | Should -Match 'Ctrl\+Alt\+Backspace'
    }

    It 'logs and carries on when another app already owns the combo' {
        $script:HotkeyTaken = @(0x41)
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'

        Register-OverlayHotkey 'Toggle' | Should -BeFalse

        $script:HotkeyLog.Count | Should -Be 1
        $script:HotkeyLog[0] | Should -Match 'already taken by another app'
    }

    It 'surfaces a second action bound to a combo the first already claimed' {
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'
        $script:Cfg['RefreshHotkey']       = 'Ctrl+Alt+A'

        Register-OverlayHotkey 'Toggle' | Should -BeTrue
        $script:HotkeyTaken = @(0x41)
        Register-OverlayHotkey 'Refresh' | Should -BeFalse

        $script:HotkeyLog.Count | Should -Be 1
        $script:HotkeyLog[0] | Should -Match 'already taken by another app'
    }

    It 'still registers the drop-down binding through its own entry point' {
        $script:Cfg['ViewMode'] = 'Quake'

        Register-DropdownHotkey | Should -BeTrue

        $registered = @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' })
        $registered.Count | Should -Be 1
        $registered[0].Id | Should -Be 0x4149
        $registered[0].Vk | Should -Be 0x7A
    }

    It 'keeps the existing drop-down failure message' {
        $script:Cfg['ViewMode'] = 'Quake'
        $script:HotkeyTaken = @(0x7A)

        Register-DropdownHotkey | Should -BeFalse

        $script:HotkeyLog[0] | Should -Be "Dropdown hotkey 'Shift+F11' is already taken by another app; pick a different one."
    }

    It 'skips the quake-only binding while the pinned view is active' {
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'

        Register-OverlayHotkeys

        $registered = @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' })
        @($registered | Where-Object { $_.Id -eq 0x4149 }).Count | Should -Be 0
        @($registered | Where-Object { $_.Id -eq [int](Get-HotkeyAction 'Toggle').Id }).Count | Should -Be 1
    }

    It 'registers the quake binding alongside the others in quake mode' {
        $script:Cfg['ViewMode'] = 'Quake'
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'

        Register-OverlayHotkeys

        $registered = @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' })
        $registered.Count | Should -Be 2
        @($registered | Where-Object { $_.Id -eq 0x4149 }).Count | Should -Be 1
    }

    It 'stores and registers a newly chosen combo' {
        Set-OverlayHotkey 'Refresh' 'Shift+F5'

        $script:Cfg['RefreshHotkey'] | Should -Be 'Shift+F5'
        $registered = @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' })
        $registered.Count | Should -Be 1
        $registered[0].Vk | Should -Be 0x74
    }

    It 'clears a binding back to unbound without registering anything' {
        Set-OverlayHotkey 'Refresh' 'Shift+F5'
        $script:HotkeyCalls.Clear()

        Set-OverlayHotkey 'Refresh' ''

        $script:Cfg['RefreshHotkey'] | Should -Be ''
        @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Register' }).Count   | Should -Be 0
        @($script:HotkeyCalls | Where-Object { $_.Op -eq 'Unregister' }).Count | Should -Be 1
    }

    It 'leaves an unknown action name alone' {
        Set-OverlayHotkey 'NoSuchAction' 'Shift+F5'

        $script:HotkeyCalls.Count | Should -Be 0
    }

    It 'drops only the drop-down binding when leaving quake mode' {
        Unregister-OverlayHotkey 'Dropdown'

        $script:HotkeyCalls.Count | Should -Be 1
        $script:HotkeyCalls[0].Op | Should -Be 'Unregister'
        $script:HotkeyCalls[0].Id | Should -Be 0x4149
    }
}

Describe 'Hotkey dispatch' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) $script:HotkeyLog.Add([string]$Message) }
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    BeforeEach {
        $script:HotkeyLog = [System.Collections.Generic.List[string]]::new()
        $script:Fired     = [System.Collections.Generic.List[string]]::new()
        $script:Cfg       = @{ ViewMode = 'Pinned' }

        function Toggle-Dropdown     { $script:Fired.Add('dropdown') }
        function Toggle-Window       { $script:Fired.Add('toggle') }
        function Invoke-ManualRefresh { $script:Fired.Add('refresh') }
    }

    It 'routes <Name> to its own action' -ForEach @(
        @{ Name = 'Dropdown'; Expected = 'dropdown' }
        @{ Name = 'Toggle';   Expected = 'toggle' }
        @{ Name = 'Refresh';  Expected = 'refresh' }
    ) {
        Invoke-OverlayHotkey ([int](Get-HotkeyAction $Name).Id)

        $script:Fired.Count | Should -Be 1
        $script:Fired[0] | Should -Be $Expected
    }

    It 'ignores an id that is not bound to anything' {
        Invoke-OverlayHotkey 0

        $script:Fired.Count | Should -Be 0
    }

    It 'logs instead of throwing when an action fails' {
        function Invoke-ManualRefresh { throw 'boom' }

        { Invoke-OverlayHotkey ([int](Get-HotkeyAction 'Refresh').Id) } | Should -Not -Throw

        $script:HotkeyLog.Count | Should -Be 1
        $script:HotkeyLog[0] | Should -Match 'boom'
    }
}

Describe 'Hotkey persistence' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\UnifiedState.ps1')
    }

    BeforeEach {
        $script:window = $null
        $script:Cfg = @{}
        $script:StatePath = Join-Path $TestDrive 'unified-overlay-state.json'
        Initialize-UnifiedCfg
    }

    It 'starts both new bindings unbound' {
        $script:Cfg['ToggleOverlayHotkey'] | Should -Be ''
        $script:Cfg['RefreshHotkey']       | Should -Be ''
    }

    It 'round-trips both new bindings through the state file' {
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'
        $script:Cfg['RefreshHotkey']       = 'Shift+F5'
        Save-UnifiedState

        $script:Cfg = @{}
        Initialize-UnifiedCfg
        Load-UnifiedState

        $script:Cfg['ToggleOverlayHotkey'] | Should -Be 'Ctrl+Alt+A'
        $script:Cfg['RefreshHotkey']       | Should -Be 'Shift+F5'
    }

    It 'keeps a cleared binding cleared across a restart' {
        $script:Cfg['ToggleOverlayHotkey'] = 'Ctrl+Alt+A'
        Save-UnifiedState
        $script:Cfg['ToggleOverlayHotkey'] = ''
        Save-UnifiedState

        $script:Cfg = @{}
        Initialize-UnifiedCfg
        Load-UnifiedState

        $script:Cfg['ToggleOverlayHotkey'] | Should -Be ''
    }

    It 'lists both new bindings as persisted settings' {
        (Get-OverlayPersistedSettingKeys) | Should -Contain 'ToggleOverlayHotkey'
        (Get-OverlayPersistedSettingKeys) | Should -Contain 'RefreshHotkey'
    }
}

Describe 'Hotkey source structure' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:DropdownSource = Get-Content (Join-Path $root 'src\Dropdown.ps1')     -Raw -Encoding UTF8
        $script:TraySource     = Get-Content (Join-Path $root 'src\UnifiedTray.ps1')  -Raw -Encoding UTF8
        $script:StateSource    = Get-Content (Join-Path $root 'src\UnifiedState.ps1') -Raw -Encoding UTF8
    }

    It 'gives the native window a table of ids instead of a single constant' {
        $script:DropdownSource | Should -Not -Match 'private const int HOTKEY_ID'
        $script:DropdownSource | Should -Match 'public bool Register\(int id,'
        $script:DropdownSource | Should -Match 'public void Unregister\(int id\)'
        $script:DropdownSource | Should -Match 'public void UnregisterAll\(\)'
    }

    It 'carries the fired id on the event' {
        $script:DropdownSource | Should -Match 'class AIUsageHotkeyEventArgs'
        $script:DropdownSource | Should -Match 'EventHandler<AIUsageHotkeyEventArgs> Pressed'
    }

    It 'releases every registration on exit' {
        $script:DropdownSource | Should -Match '(?s)public void Dispose\(\)\s*\{\s*UnregisterAll\(\);'
        $script:TraySource     | Should -Match 'Dispose-DropdownHotkey'
    }

    It 'keeps the documented NativeWindow approach' {
        $script:DropdownSource | Should -Match 'public class AIUsageGlobalHotkey : NativeWindow'
        # The comment explaining why this is not a WPF HwndSourceHook must survive.
        $script:DropdownSource | Should -Match 'HwndSourceHook'
    }

    It 'reuses the existing tray actions instead of reimplementing them' {
        $script:DropdownSource | Should -Match 'Toggle-Window'
        $script:DropdownSource | Should -Match 'Invoke-ManualRefresh'
    }

    It 'defaults the two new bindings to unbound in the config defaults' {
        $defaults = [regex]::Match(
            $script:StateSource,
            '(?s)\$script:UnifiedCfgDefaults = @\{.*?\n\}'
        ).Value

        $defaults | Should -Match "ToggleOverlayHotkey\s*=\s*''"
        $defaults | Should -Match "RefreshHotkey\s*=\s*''"
        $defaults | Should -Match "DropdownHotkey\s*=\s*'Shift\+F11'"
    }

    It 'keeps the existing drop-down hotkey submenu' {
        $script:TraySource | Should -Match "New-StripItem 'Drop-down hotkey'"
        $script:TraySource | Should -Match "Set-DropdownHotkey '"
    }

    It 'adds a submenu for each new binding' {
        $script:TraySource | Should -Match "New-StripItem 'Hotkeys'"
        $script:TraySource | Should -Match "Action\s*=\s*'Toggle'"
        $script:TraySource | Should -Match "Action\s*=\s*'Refresh'"
        $script:TraySource | Should -Match "Label\s*=\s*'Show/hide overlay'"
        $script:TraySource | Should -Match "Label\s*=\s*'Refresh now'"
        $script:TraySource | Should -Match 'Set-OverlayHotkey'
    }

    It 'offers an explicit way back to unbound' {
        $script:TraySource | Should -Match 'None \(unbound\)'
    }

    It 'registers every binding once the saved config is loaded' {
        $wireEvents = [regex]::Match(
            $script:TraySource,
            '(?s)function Wire-UnifiedWindowEvents \{.*?\n\}'
        ).Value

        $wireEvents | Should -Match 'Register-OverlayHotkeys'
    }
}

Describe 'Hotkey registration against the real Windows table' {
    It 'registers, re-binds and releases several hotkeys on one window' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/HotkeyProbe.ps1" 2>&1
        $joined = ($output -join "`n")

        $LASTEXITCODE | Should -Be 0 -Because $joined
        if ($joined -match 'Hotkey probe skipped') {
            Set-ItResult -Skipped -Because $joined
            return
        }
        $output | Should -Contain 'Hotkey probe passed'
    }
}
