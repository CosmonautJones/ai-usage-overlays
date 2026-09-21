$ErrorActionPreference = 'Stop'
# Real RegisterHotKey calls claim combos system-wide, so they run in a fresh STA
# process rather than inside the Pester runner, and everything claimed here is
# released again before exit. Ctrl+Alt+Shift+F9/F10 are deliberately obscure;
# if another app already owns either, report a skip rather than a failure.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root = Split-Path $PSScriptRoot -Parent
function Write-Log { param([string]$Message) }
. (Join-Path $root 'src\Dropdown.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HotkeyProbeNative {
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
}
'@

$fired = New-Object System.Collections.ArrayList
function Toggle-Window        { [void]$fired.Add('toggle') }
function Invoke-ManualRefresh { [void]$fired.Add('refresh') }

# WM_HOTKEY sent straight to the owner window: SendMessage on the owning thread
# runs WndProc synchronously, so no message pump or real keypress is needed.
function Send-Hotkey([int]$Id) {
    [void][HotkeyProbeNative]::SendMessage($script:HotkeyOwner.Handle, 0x0312, [IntPtr]$Id, [IntPtr]::Zero)
}

$mods  = [uint32](1 -bor 2 -bor 4 -bor 0x4000)   # ALT | CONTROL | SHIFT | NOREPEAT
$vkF9  = [uint32]0x78
$vkF10 = [uint32]0x79
$idA = [int](Get-HotkeyAction 'Toggle').Id
$idB = [int](Get-HotkeyAction 'Refresh').Id
$idC = 0x7A03                                   # bound to no action

$owner = Get-OverlayHotkeyOwner
try {
    if (-not $owner.Register($idA, $mods, $vkF9)) {
        'Hotkey probe skipped: Ctrl+Alt+Shift+F9 is already owned by another app'
        return
    }
    if (-not $owner.Register($idB, $mods, $vkF10)) {
        'Hotkey probe skipped: Ctrl+Alt+Shift+F10 is already owned by another app'
        return
    }

    # Each id reaches its own action; an id this window does not hold is ignored.
    Send-Hotkey $idA
    Send-Hotkey $idB
    Send-Hotkey $idC
    if (($fired -join ',') -ne 'toggle,refresh') {
        throw "WM_HOTKEY dispatch fired '$($fired -join ',')'; expected 'toggle,refresh'"
    }

    # A second id on the same combo is refused by Windows - this is how a
    # duplicate binding surfaces at runtime.
    if ($owner.Register($idC, $mods, $vkF9)) {
        throw 'A duplicate combo registered twice; expected RegisterHotKey to refuse it'
    }

    # Re-binding drops the old claim before trying the new one. Pointing idA at
    # the combo idB holds is refused, but F9 has already been let go.
    if ($owner.Register($idA, $mods, $vkF10)) {
        throw 'Re-binding idA onto a combo idB holds should have been refused'
    }
    if (-not $owner.Register($idC, $mods, $vkF9)) {
        throw 'Re-binding did not release the previous combo'
    }
    $owner.Unregister($idB)
    if (-not $owner.Register($idA, $mods, $vkF10)) {
        throw 'Re-binding idA onto a freed combo failed'
    }

    # Releasing everything returns both combos to the OS and stops dispatch.
    $owner.UnregisterAll()
    $fired.Clear()
    Send-Hotkey $idA
    if ($fired.Count -ne 0) { throw 'An unregistered id still dispatched its action' }
    if (-not $owner.Register($idB, $mods, $vkF9)) {
        throw 'UnregisterAll did not release Ctrl+Alt+Shift+F9'
    }
    if (-not $owner.Register($idC, $mods, $vkF10)) {
        throw 'UnregisterAll did not release Ctrl+Alt+Shift+F10'
    }

    # The quit path must hand back whatever is still held.
    Dispose-DropdownHotkey
    $check = New-Object AIUsageGlobalHotkey
    try {
        if (-not $check.Register($idA, $mods, $vkF9) -or -not $check.Register($idB, $mods, $vkF10)) {
            throw 'Dispose-DropdownHotkey left a combo registered'
        }
    } finally {
        $check.Dispose()
    }

    'Hotkey probe passed'
} finally {
    Dispose-DropdownHotkey
}
