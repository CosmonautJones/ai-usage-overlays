#Requires -Module Pester
#
# Translucent theme tints must be written #AARRGGBB, the only 8-digit form WPF
# reads. Suffixing the alpha (#RRGGBBAA) repainted the warning sub-labels and
# the section divider in hues no theme ever chose.
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
}

Describe 'Theme tints lead with their alpha' {
    It 'paints sub-labels and the divider in the theme hue, faded' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/ThemeAlphaProbe.ps1" -Root $script:Root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Theme alpha passed'
    }
}
