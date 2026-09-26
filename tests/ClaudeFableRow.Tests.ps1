#Requires -Module Pester
#
# The Fable weekly row only earns its space when the account has a Fable
# window. Without one the API sends seven_day_fable = null and the row sat at
# '--' indefinitely; Opus has always hidden itself in the same situation.
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
}

Describe 'Claude Fable weekly row' {
    It 'shows only while the API reports a Fable reading' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/ClaudeFableRowProbe.ps1" -Root $script:Root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Claude Fable row passed'
    }
}
