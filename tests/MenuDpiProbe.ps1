param([Parameter(Mandatory)][string]$EntryPoint)
$ErrorActionPreference = 'Stop'
# Run the real assembly/bootstrap section in a fresh STA process. Loading WPF
# in the test runner first would conceal the startup-order regression.
$source = Get-Content -LiteralPath $EntryPoint -Raw
$bootstrap = [regex]::Match($source, '(?s)Add-Type -AssemblyName PresentationFramework,.*?(?=\r?\n# -{5})').Value
if (-not $bootstrap) { throw 'UI bootstrap section not found' }
function Log { param($Message) }
. ([scriptblock]::Create($bootstrap))
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MenuDpiTestNative {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    public struct Rect { public int Left, Top, Right, Bottom; }
}
'@
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
[void]$menu.Items.Add('Placement regression')
$window = [System.Windows.Window]::new()
$window.Width = 1; $window.Height = 1
$window.ShowInTaskbar = $false; $window.ShowActivated = $false
try {
    $window.Show()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $point = [System.Drawing.Point]::new($screen.WorkingArea.Left + 50, $screen.WorkingArea.Top + 50)
        foreach ($attempt in 1..2) {
            $menu.Show($point)
            $rect = New-Object MenuDpiTestNative+Rect
            if (-not [MenuDpiTestNative]::GetWindowRect($menu.Handle, [ref]$rect)) { throw 'GetWindowRect failed' }
            if ([Math]::Abs($rect.Left - $point.X) -gt 1 -or [Math]::Abs($rect.Top - $point.Y) -gt 1) {
                throw "Menu displaced on $($screen.DeviceName), opening ${attempt}: requested $point, actual $($rect.Left),$($rect.Top)"
            }
            $menu.Close()
        }
    }
    'Menu DPI placement passed'
} finally {
    $menu.Dispose()
    $window.Close()
}
