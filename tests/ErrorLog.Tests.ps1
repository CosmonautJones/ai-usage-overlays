#Requires -Module Pester
#
# unified-overlay-error.log was append-only and reached 120 MB. Write-Log now
# caps it: past the limit the file is cut back to its newest whole lines, so the
# recent history that matters for a bug report survives and the size stays put.
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Data.ps1')

    function New-NumberedLog([string]$Path, [int]$Lines) {
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 1; $i -le $Lines; $i++) {
            [void]$sb.Append(('line {0:D6} padding padding padding padding padding' -f $i)).Append("`r`n")
        }
        [System.IO.File]::WriteAllText($Path, $sb.ToString())
    }
}

Describe 'Limit-LogFile' {
    BeforeEach {
        $script:LogPath = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N') + '.log')
    }

    It 'leaves a log under the cap untouched' {
        New-NumberedLog $script:LogPath 10
        $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:LogPath))
        Limit-LogFile -Path $script:LogPath -MaxBytes 4096 -KeepBytes 1024
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:LogPath)) | Should -Be $before
    }

    It 'cuts an oversized log back to its newest whole lines' {
        New-NumberedLog $script:LogPath 400
        $original = [System.IO.File]::ReadAllText($script:LogPath)
        Limit-LogFile -Path $script:LogPath -MaxBytes 8192 -KeepBytes 2048

        $kept = [System.IO.File]::ReadAllText($script:LogPath)
        $kept.Length | Should -BeLessOrEqual 2048
        $kept.Length | Should -BeGreaterThan 1500
        $original.EndsWith($kept) | Should -BeTrue
        $kept | Should -Match '^line \d{6} '
        $kept | Should -Match 'line 000400 padding'
        $kept | Should -Not -Match 'line 000001 '
    }

    It 'does nothing when the log does not exist yet' {
        { Limit-LogFile -Path $script:LogPath -MaxBytes 10 -KeepBytes 5 } | Should -Not -Throw
        Test-Path -LiteralPath $script:LogPath | Should -BeFalse
    }
}

Describe 'Write-Log keeps the error log bounded' {
    BeforeEach {
        $script:ErrLog = Join-Path $TestDrive ('err-' + [guid]::NewGuid().ToString('N') + '.log')
    }

    It 'appends to a small log without trimming it' {
        New-NumberedLog $script:ErrLog 3
        Write-Log 'fresh entry'
        $lines = @(Get-Content -LiteralPath $script:ErrLog)
        $lines.Count | Should -Be 4
        $lines[0] | Should -Match '^line 000001 '
        $lines[3] | Should -Match '\] fresh entry$'
    }

    It 'trims a runaway log before appending, keeping the newest lines' {
        # About 1.4 MB, past the 1 MB cap.
        New-NumberedLog $script:ErrLog 25000
        Write-Log 'fresh entry'

        (Get-Item -LiteralPath $script:ErrLog).Length | Should -BeLessOrEqual 1MB
        $lines = @(Get-Content -LiteralPath $script:ErrLog)
        $lines[0] | Should -Match '^line \d{6} '
        $lines[-2] | Should -Match '^line 025000 '
        $lines[-1] | Should -Match '\] fresh entry$'
    }

    It 'creates the log when none exists' {
        Write-Log 'first entry'
        @(Get-Content -LiteralPath $script:ErrLog)[-1] | Should -Match '\] first entry$'
    }
}
