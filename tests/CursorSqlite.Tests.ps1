#Requires -Module Pester
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:root 'src\CursorData.ps1')
}

Describe 'Resolve-Sqlite3Path' {
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("sqlite-resolve-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'src') -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'finds sqlite3.exe sitting beside the module' {
        $exe = Join-Path $script:sandbox 'src\sqlite3.exe'
        Set-Content -LiteralPath $exe -Value 'stub'
        Resolve-Sqlite3Path (Join-Path $script:sandbox 'src') | Should -Be $exe
    }

    # The installer drops sqlite3.exe in the app root but the PS modules in {app}\src,
    # so resolution must walk one level up. Without this the overlay silently reports
    # "Cannot read Cursor token from state.vscdb".
    It 'finds the bundled sqlite3.exe one level up in the app root' {
        $exe = Join-Path $script:sandbox 'sqlite3.exe'
        Set-Content -LiteralPath $exe -Value 'stub'
        Resolve-Sqlite3Path (Join-Path $script:sandbox 'src') | Should -Be $exe
    }

    It 'prefers the module-local copy over the app root copy' {
        Set-Content -LiteralPath (Join-Path $script:sandbox 'sqlite3.exe') -Value 'stub'
        $local = Join-Path $script:sandbox 'src\sqlite3.exe'
        Set-Content -LiteralPath $local -Value 'stub'
        Resolve-Sqlite3Path (Join-Path $script:sandbox 'src') | Should -Be $local
    }

    It 'returns $null when no sqlite3.exe is reachable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'sqlite3.exe' }
        Resolve-Sqlite3Path (Join-Path $script:sandbox 'src') | Should -BeNullOrEmpty
    }

    It 'resolves the real bundled sqlite3.exe from the repo layout' {
        # Guards the actual shipped layout: src\CursorData.ps1 + root\sqlite3.exe
        $resolved = Resolve-Sqlite3Path (Join-Path $script:root 'src')
        $resolved | Should -Not -BeNullOrEmpty
        (Split-Path $resolved -Leaf) | Should -Be 'sqlite3.exe'
        Test-Path -LiteralPath $resolved | Should -BeTrue
    }
}

Describe 'Invoke-Sqlite' {
    It 'reads a real SQLite database via the bundled exe' {
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("sqlite-probe-" + [guid]::NewGuid().ToString('N') + '.db')
        $exe = Resolve-Sqlite3Path (Join-Path $script:root 'src')
        & $exe $db "CREATE TABLE ItemTable(key TEXT, value TEXT); INSERT INTO ItemTable VALUES('cursorAuth/accessToken','tok-123');"
        try {
            $raw = Invoke-Sqlite $db "SELECT key, value FROM ItemTable"
            $raw | Should -Not -BeNullOrEmpty
            $rows = $raw | ConvertFrom-Json
            $rows[0].value | Should -Be 'tok-123'
        } finally {
            Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Overlay PATH hygiene' {
    # A long-lived overlay re-runs the refresh scriptblock in-process every 180s.
    # Prepending to $env:PATH there grew it past the Win32 32,767-char env-var
    # limit in ~1.8 days, after which EVERY child process spawn failed and the
    # Cursor section died with "Cannot read Cursor token from state.vscdb".
    It 'never mutates $env:PATH in unified-overlay.ps1' {
        $source = Get-Content (Join-Path $script:root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $matches = [regex]::Matches($source, '\$env:PATH\s*=')
        $matches.Count | Should -Be 0 -Because 'PATH mutation in a repeatedly-executed scriptblock leaks until spawns fail'
    }
}
