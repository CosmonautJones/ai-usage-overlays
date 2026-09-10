#Requires -Module Pester

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:root = $root
    . (Join-Path $root 'src\InstallManifest.ps1')
    . (Join-Path $root 'src\Config.ps1')
}

Describe 'Install file set' {
    It 'names the overlay, src scripts, launcher, sqlite, README, and LICENSE' {
        $required = Get-OverlayInstallRequiredRelativePaths
        $required | Should -Contain 'unified-overlay.ps1'
        $required | Should -Contain 'Start-Unified.vbs'
        $required | Should -Contain 'sqlite3.exe'
        $required | Should -Contain 'LICENSE'
        $required | Should -Contain 'README.md'
        $required | Should -Contain 'src\*.ps1'
    }

    It 'copies the required set through Copy-OverlayInstallFiles' {
        $src = Join-Path $TestDrive 'payload'
        $dest = Join-Path $TestDrive 'install-dest'
        New-Item -ItemType Directory -Path (Join-Path $src 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'unified-overlay.ps1') -Value '# overlay'
        Set-Content -LiteralPath (Join-Path $src 'Start-Unified.vbs') -Value "' launcher"
        Set-Content -LiteralPath (Join-Path $src 'sqlite3.exe') -Value 'sqlite'
        Set-Content -LiteralPath (Join-Path $src 'LICENSE') -Value 'MIT'
        Set-Content -LiteralPath (Join-Path $src 'README.md') -Value '# readme'
        Set-Content -LiteralPath (Join-Path $src 'src\Export.ps1') -Value '# src'

        Copy-OverlayInstallFiles -SourceRoot $src -DestRoot $dest

        (Test-Path -LiteralPath (Join-Path $dest 'unified-overlay.ps1')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dest 'Start-Unified.vbs')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dest 'sqlite3.exe')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dest 'LICENSE')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dest 'README.md')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dest 'src\Export.ps1')) | Should -BeTrue
    }

    It 'has install.ps1 drive the shipped copy helper' {
        $install = Get-Content (Join-Path $script:root 'install.ps1') -Raw -Encoding UTF8
        $install | Should -Match 'InstallManifest\.ps1'
        $install | Should -Match 'Copy-OverlayInstallFiles'
    }

    It 'has the Inno script include the same required files' {
        $iss = Get-Content (Join-Path $script:root 'packaging\inno\AIUsageOverlay.iss') -Raw -Encoding UTF8
        foreach ($rel in Get-OverlayInstallRequiredRelativePaths) {
            $iss | Should -Match ([regex]::Escape($rel)) -Because "Inno [Files] must ship $rel"
        }
    }
}

Describe 'Documented app version' {
    It 'matches the README release version' {
        $readme = Get-Content (Join-Path $script:root 'README.md') -Raw -Encoding UTF8
        $script:AppVersion | Should -Not -BeNullOrEmpty
        $readme | Should -Match ([regex]::Escape("Version $script:AppVersion"))
        $readme | Should -Match ([regex]::Escape("v$script:AppVersion"))
    }
}

Describe 'README product path' {
    It 'documents install, first-run, login, usage, settings, platform links, and uninstall' {
        $readme = Get-Content (Join-Path $script:root 'README.md') -Raw -Encoding UTF8
        $readme | Should -Match '## Install'
        $readme | Should -Match '## Choose providers \(first run\)'
        $readme | Should -Match '## First login'
        $readme | Should -Match '## Usage'
        $readme | Should -Match '## Settings'
        $readme | Should -Match '## Platform links'
        $readme | Should -Match '## Uninstall'
        $readme | Should -Match 'claude.ai/settings/usage'
        $readme | Should -Match 'chatgpt.com/codex'
        $readme | Should -Match 'cursor.com/settings'
        $readme | Should -Match 'console.x.ai'
    }
}
