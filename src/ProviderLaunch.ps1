# ProviderLaunch.ps1 - open Claude, Codex, or Grok in a folder, or open that folder in Cursor.
# The command is a fixed argument list. Nothing the user types is executed.
# Tests call Get-ProviderLaunchCommand and Select-ExplorerFolder. They do not spawn a process.

function Test-LaunchFolderPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # Kept out of the argument list even though we never join a shell string.
    if ($Path -match '[\r\n;&|`]') { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    if ($full -match '[\r\n;&|`]') { return $false }
    return (Test-Path -LiteralPath $full -PathType Container)
}

function Get-LaunchFolderLeaf([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $trim = $Path.TrimEnd('\', '/')
    if (-not $trim) { return $Path }
    $leaf = Split-Path -Leaf $trim
    if (-not $leaf) { return $trim }
    return $leaf
}

function New-ProviderLaunchFailure([string]$Provider, [string]$Reason) {
    [pscustomobject]@{
        Provider          = $Provider
        Ok                = $false
        Reason            = $Reason
        FilePath          = $null
        ArgumentList      = [string[]]::new(0)
        WorkingDirectory  = $null
        UseTerminal       = $false
    }
}

function Get-ProviderLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [string]$Folder,
        [string]$CliPath,
        [string]$CursorExe,
        [string]$TerminalPath
    )

    $key = $Provider.ToLowerInvariant()
    if ($key -notin @('claude', 'codex', 'grok', 'cursor')) {
        return (New-ProviderLaunchFailure $key 'provider')
    }
    if (-not (Test-LaunchFolderPath $Folder)) {
        return (New-ProviderLaunchFailure $key 'folder')
    }
    $full = [System.IO.Path]::GetFullPath($Folder)

    if ($key -eq 'cursor') {
        if ([string]::IsNullOrWhiteSpace($CursorExe)) {
            return (New-ProviderLaunchFailure $key 'not-installed')
        }
        return [pscustomobject]@{
            Provider         = $key
            Ok               = $true
            Reason           = $null
            FilePath         = $CursorExe
            ArgumentList     = [string[]]@($full)
            WorkingDirectory = $full
            UseTerminal      = $false
        }
    }

    if ([string]::IsNullOrWhiteSpace($CliPath)) {
        return (New-ProviderLaunchFailure $key 'not-installed')
    }

    $terminal = $null
    if (-not [string]::IsNullOrWhiteSpace($TerminalPath)) { $terminal = $TerminalPath }
    # Windows Terminal starts an .exe. A .cmd shim (npm) needs the working-directory fallback,
    # which ShellExecute can launch. Do not wrap it in cmd /c.
    $cliExe = [System.IO.Path]::GetExtension($CliPath) -eq '.exe'
    if ($terminal -and $cliExe) {
        return [pscustomobject]@{
            Provider         = $key
            Ok               = $true
            Reason           = $null
            FilePath         = $terminal
            ArgumentList     = [string[]]@('-d', $full, '--', $CliPath)
            WorkingDirectory = $null
            UseTerminal      = $true
        }
    }

    return [pscustomobject]@{
        Provider         = $key
        Ok               = $true
        Reason           = $null
        FilePath         = $CliPath
        ArgumentList     = [string[]]::new(0)
        WorkingDirectory = $full
        UseTerminal      = $false
    }
}

function Start-ProviderLaunchProcess {
    param($Command)

    if (-not $Command -or -not $Command.Ok -or -not $Command.FilePath) { return $null }

    $argList = @($Command.ArgumentList | Where-Object { $null -ne $_ -and "$_" -ne '' })
    $file = [string]$Command.FilePath
    if ($Command.UseTerminal) {
        if ($argList.Count -gt 0) {
            return Start-Process -FilePath $file -ArgumentList $argList -PassThru
        }
        return Start-Process -FilePath $file -PassThru
    }

    $dir = [string]$Command.WorkingDirectory
    if ($argList.Count -gt 0) {
        return Start-Process -FilePath $file -ArgumentList $argList -WorkingDirectory $dir -PassThru
    }
    return Start-Process -FilePath $file -WorkingDirectory $dir -PassThru
}

function Resolve-WindowsTerminalPath {
    $cmd = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $path = $null
        if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) { $path = [string]$cmd.Source }
        elseif ($cmd.PSObject.Properties['Path'] -and $cmd.Path) { $path = [string]$cmd.Path }
        if ($path) { return $path }
    }
    if ($env:LOCALAPPDATA) {
        $local = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
        if (Test-Path -LiteralPath $local) { return $local }
    }
    return $null
}

function Resolve-ProviderLaunchTarget {
    param([Parameter(Mandatory = $true)][string]$Provider)

    $key = $Provider.ToLowerInvariant()
    $cliPath = $null
    $cursor = $null
    $terminal = $null
    if ($key -eq 'cursor') {
        if (Get-Command Resolve-CursorAppExePath -ErrorAction SilentlyContinue) {
            $cursor = Resolve-CursorAppExePath
        }
    } else {
        if (Get-Command Resolve-ProviderLoginCli -ErrorAction SilentlyContinue) {
            $resolved = Resolve-ProviderLoginCli $key
            if ($resolved -and $resolved.Path) { $cliPath = [string]$resolved.Path }
        }
        $terminal = Resolve-WindowsTerminalPath
    }
    [pscustomobject]@{
        CliPath      = $cliPath
        CursorExe    = $cursor
        TerminalPath = $terminal
    }
}

# Filesystem folders only. Virtual shell paths (::{GUID}) are not launch targets.
# Foreground wins when it is one of the windows. Otherwise the first z-order hit,
# because the overlay itself is usually the foreground window while its menu is open.
function Select-ExplorerFolder {
    param(
        [object[]]$Windows,
        [long]$ForegroundHwnd = 0,
        [long[]]$TopToBottomHwnds
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($w in @($Windows)) {
        if ($null -eq $w) { continue }
        $hwnd = [long]0
        $path = ''
        if ($w -is [System.Collections.IDictionary]) {
            if ($w.Contains('Hwnd')) { $hwnd = [long]$w['Hwnd'] }
            if ($w.Contains('Path')) { $path = [string]$w['Path'] }
        } else {
            $hwndProp = $w.PSObject.Properties['Hwnd']
            $pathProp = $w.PSObject.Properties['Path']
            if ($hwndProp -and $null -ne $hwndProp.Value) { $hwnd = [long]$hwndProp.Value }
            if ($pathProp) { $path = [string]$pathProp.Value }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -notmatch '^[A-Za-z]:\\' -and $path -notmatch '^\\\\') { continue }
        $rows.Add([pscustomobject]@{ Hwnd = $hwnd; Path = $path })
    }
    if ($rows.Count -eq 0) { return $null }

    if ($ForegroundHwnd -ne 0) {
        foreach ($row in $rows) {
            if ([long]$row.Hwnd -eq $ForegroundHwnd) { return [string]$row.Path }
        }
    }
    if ($TopToBottomHwnds) {
        foreach ($hwnd in @($TopToBottomHwnds)) {
            foreach ($row in $rows) {
                if ([long]$row.Hwnd -eq [long]$hwnd) { return [string]$row.Path }
            }
        }
    }
    return [string]$rows[0].Path
}

function Get-FrontExplorerFolder {
    $windows = [System.Collections.Generic.List[object]]::new()
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            try {
                $path = [string]$w.Document.Folder.Self.Path
                $hwnd = [long]$w.HWND
                $windows.Add(@{ Hwnd = $hwnd; Path = $path })
            } catch { }
        }
    } catch {
        return $null
    }

    $foreground = [long]0
    $order = @()
    try {
        if (-not ('OverlayWindowWalk' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class OverlayWindowWalk {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    public static long Foreground() { return GetForegroundWindow().ToInt64(); }
    public static long[] TopWindows(int max) {
        var list = new List<long>();
        IntPtr h = GetTopWindow(IntPtr.Zero);
        int n = 0;
        while (h != IntPtr.Zero && n < max) {
            list.Add(h.ToInt64());
            h = GetWindow(h, 2);
            n++;
        }
        return list.ToArray();
    }
}
'@
        }
        $foreground = [OverlayWindowWalk]::Foreground()
        $order = @([OverlayWindowWalk]::TopWindows(400))
    } catch { }

    return (Select-ExplorerFolder -Windows $windows.ToArray() -ForegroundHwnd $foreground -TopToBottomHwnds $order)
}

function Show-LaunchFolderDialog {
    param(
        [string]$Description = 'Choose a folder',
        [string]$InitialPath
    )

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    try { $dlg.UseDescriptionForTitle = $true } catch { }
    if ($InitialPath -and (Test-LaunchFolderPath $InitialPath)) {
        $dlg.SelectedPath = $InitialPath
    }
    $result = $dlg.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [string]$dlg.SelectedPath
}
