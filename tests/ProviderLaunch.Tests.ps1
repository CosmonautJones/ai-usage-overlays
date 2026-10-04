#Requires -Module Pester

Describe 'Provider launch command' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLaunch.ps1')
    }

    It 'opens a CLI in Windows Terminal with the folder as its own argument' {
        $dir = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cmd = Get-ProviderLaunchCommand -Provider 'Claude' -Folder $dir -CliPath 'C:\tools\claude.exe' -TerminalPath 'C:\wt\wt.exe'
        $cmd.Ok | Should -BeTrue
        $cmd.UseTerminal | Should -BeTrue
        $cmd.FilePath | Should -Be 'C:\wt\wt.exe'
        $cmd.WorkingDirectory | Should -BeNullOrEmpty
        @($cmd.ArgumentList) | Should -Be @('-d', ([System.IO.Path]::GetFullPath($dir)), '--', 'C:\tools\claude.exe')
    }

    It 'uses the working directory for a .cmd shim even when Windows Terminal is installed' {
        $dir = Join-Path $TestDrive 'shim'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cmd = Get-ProviderLaunchCommand -Provider 'claude' -Folder $dir -CliPath 'C:\npm\claude.cmd' -TerminalPath 'C:\wt\wt.exe'
        $cmd.Ok | Should -BeTrue
        $cmd.UseTerminal | Should -BeFalse
        $cmd.FilePath | Should -Be 'C:\npm\claude.cmd'
        $cmd.WorkingDirectory | Should -Be ([System.IO.Path]::GetFullPath($dir))
    }

    It 'falls back to the CLI working directory when Windows Terminal is absent' {
        $dir = Join-Path $TestDrive 'fallback'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Mock Start-Process { throw 'should not spawn' }
        $cmd = Get-ProviderLaunchCommand -Provider 'codex' -Folder $dir -CliPath 'C:\tools\codex.exe' -TerminalPath $null
        $cmd.Ok | Should -BeTrue
        $cmd.UseTerminal | Should -BeFalse
        $cmd.FilePath | Should -Be 'C:\tools\codex.exe'
        $cmd.WorkingDirectory | Should -Be ([System.IO.Path]::GetFullPath($dir))
        @($cmd.ArgumentList).Count | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'opens Cursor on the folder and does not use a terminal' {
        $dir = Join-Path $TestDrive 'cursor-repo'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $full = [System.IO.Path]::GetFullPath($dir)
        $cmd = Get-ProviderLaunchCommand -Provider 'cursor' -Folder $dir -CursorExe 'C:\Apps\Cursor.exe' -TerminalPath 'C:\wt\wt.exe'
        $cmd.Ok | Should -BeTrue
        $cmd.UseTerminal | Should -BeFalse
        $cmd.FilePath | Should -Be 'C:\Apps\Cursor.exe'
        @($cmd.ArgumentList) | Should -Be @($full)
        $cmd.WorkingDirectory | Should -Be $full
    }

    It 'refuses a missing CLI, a missing folder, and a folder that looks like a command' {
        $dir = Join-Path $TestDrive 'real'
        New-Item -ItemType Directory -Path $dir | Out-Null
        (Get-ProviderLaunchCommand -Provider 'grok' -Folder $dir -CliPath $null).Reason | Should -Be 'not-installed'
        (Get-ProviderLaunchCommand -Provider 'cursor' -Folder $dir -CursorExe '').Reason | Should -Be 'not-installed'
        (Get-ProviderLaunchCommand -Provider 'claude' -Folder 'C:\no\such\folder' -CliPath 'C:\tools\claude.exe').Reason | Should -Be 'folder'
        (Get-ProviderLaunchCommand -Provider 'claude' -Folder 'C:\work & calc.exe' -CliPath 'C:\tools\claude.exe').Reason | Should -Be 'folder'
        (Get-ProviderLaunchCommand -Provider 'nope' -Folder $dir -CliPath 'C:\tools\claude.exe').Reason | Should -Be 'provider'
    }

    It 'starts the built command and never hides the window' {
        $dir = Join-Path $TestDrive 'spawn'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Mock Start-Process { [pscustomobject]@{ Id = 77 } }
        $cmd = Get-ProviderLaunchCommand -Provider 'grok' -Folder $dir -CliPath 'C:\tools\grok.exe'
        $proc = Start-ProviderLaunchProcess $cmd
        $proc.Id | Should -Be 77
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\tools\grok.exe' -and
            $WorkingDirectory -eq ([System.IO.Path]::GetFullPath($dir)) -and
            "$WindowStyle" -ne 'Hidden'
        }
    }
}

Describe 'Explorer folder selection' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderLaunch.ps1')
    }

    It 'prefers the foreground Explorer window' {
        $windows = @(
            @{ Hwnd = 10; Path = 'C:\older' }
            @{ Hwnd = 20; Path = 'D:\front' }
        )
        Select-ExplorerFolder -Windows $windows -ForegroundHwnd 20 | Should -Be 'D:\front'
    }

    It 'skips virtual shell folders and uses z-order when the overlay is in front' {
        $windows = @(
            [pscustomobject]@{ Hwnd = 10; Path = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}' }
            [pscustomobject]@{ Hwnd = 11; Path = 'C:\behind' }
            [pscustomobject]@{ Hwnd = 12; Path = '\\wsl.localhost\Ubuntu\home\me\src' }
        )
        Select-ExplorerFolder -Windows $windows -ForegroundHwnd 99 -TopToBottomHwnds @(99, 12, 11) |
            Should -Be '\\wsl.localhost\Ubuntu\home\me\src'
    }

    It 'returns null when no Explorer window is a filesystem folder' {
        Select-ExplorerFolder -Windows @(@{ Hwnd = 1; Path = '::{GUID}' }) | Should -BeNullOrEmpty
        Select-ExplorerFolder -Windows @() | Should -BeNullOrEmpty
    }
}

Describe 'Remembered launch folder' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Cfg = @{}
        . (Join-Path $root 'src\UnifiedState.ps1')
    }

    It 'saves one folder per provider and drops anything else' {
        $script:StatePath = Join-Path $TestDrive 'unified-state.json'
        $script:Cfg['LaunchFolders']['claude'] = 'C:\work\app'
        $script:Cfg['LaunchFolders']['evil'] = 'C:\nope'
        Save-UnifiedState

        $script:Cfg = @{}
        Load-UnifiedState
        $script:Cfg['LaunchFolders']['claude'] | Should -Be 'C:\work\app'
        $script:Cfg['LaunchFolders'].Contains('evil') | Should -BeFalse
        $script:Cfg['LaunchFolders'] | Should -BeOfType [System.Collections.IDictionary]
    }
}

Describe 'Open menu wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:TraySource = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
        $script:OverlaySource = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $script:LaunchSource = Get-Content (Join-Path $root 'src\ProviderLaunch.ps1') -Raw -Encoding UTF8
    }

    It 'dots ProviderLaunch into the overlay and adds the Open submenu' {
        $script:OverlaySource | Should -Match "src\\ProviderLaunch\.ps1"
        $script:TraySource | Should -Match "New-StripItem 'Open'"
        $script:TraySource | Should -Match 'Use Explorer folder'
        $script:TraySource | Should -Match 'Choose another folder'
        $script:TraySource | Should -Match 'function Invoke-ProviderOpen'
        $script:TraySource | Should -Match 'function Queue-ProviderOpen'
        $script:TraySource | Should -Match 'Sync-ProviderLaunchMenuItems'
    }

    It 'does not hide the launched window or build a shell command string' {
        $script:LaunchSource | Should -Not -Match 'WindowStyle Hidden'
        $script:LaunchSource | Should -Not -Match 'cmd\.exe'
        $script:LaunchSource | Should -Match "ArgumentList\s*=\s*\[string\[\]\]@\('-d'"
    }
}
