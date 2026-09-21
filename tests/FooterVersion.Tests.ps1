# FooterVersion.Tests.ps1 - the overlay shows its own version like it shows every
# provider's, and that version is the update signal: amber when a release is
# waiting, the theme's footer chrome colour otherwise.
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ShellSource = Get-Content (Join-Path $script:Root 'src\Shell.ps1') -Raw -Encoding UTF8
    $script:TraySource  = Get-Content (Join-Path $script:Root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8

    # Lifts one function verbatim out of a source file so the shipping body runs
    # under both shells without dot-sourcing Shell.ps1, which needs WPF loaded in
    # the Pester runner (see ShellFitProbe.ps1 for why that is not allowed).
    function Get-SourceFunctionText {
        param([string]$Source, [string]$Name)

        $start = $Source.IndexOf("function $Name")
        if ($start -lt 0) { throw "function $Name not found" }
        $open = $Source.IndexOf('{', $start)
        if ($open -lt 0) { throw "function $Name has no body" }

        $depth = 0
        for ($i = $open; $i -lt $Source.Length; $i++) {
            if ($Source[$i] -eq '{') {
                $depth++
            } elseif ($Source[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { return $Source.Substring($start, $i - $start + 1) }
            }
        }
        throw "function $Name body is not brace-balanced"
    }

    . ([scriptblock]::Create((Get-SourceFunctionText $script:ShellSource 'Resolve-FooterVersionFg')))
}

Describe 'Resolve-FooterVersionFg' {
    It 'goes amber when a release is waiting, whatever the theme' {
        Resolve-FooterVersionFg 'available' '#5C8AAA' | Should -Be '#FBBF24'
        Resolve-FooterVersionFg 'available' '#3DC95A' | Should -Be '#FBBF24'
        Resolve-FooterVersionFg 'available' $null     | Should -Be '#FBBF24'
    }

    It 'reads as theme chrome for every other update status' {
        foreach ($status in 'current', 'unknown', 'checking', 'error',
                            'no-release', 'missing-asset', 'installing') {
            Resolve-FooterVersionFg $status '#B383E0' | Should -Be '#B383E0'
            Resolve-FooterVersionFg $status '#909090' | Should -Be '#909090'
        }
    }

    It 'falls back to the provider-version slate when the theme has no brand colour' {
        Resolve-FooterVersionFg 'current' $null | Should -Be '#5C7A96'
        Resolve-FooterVersionFg 'current' ''    | Should -Be '#5C7A96'
        Resolve-FooterVersionFg ''        '   ' | Should -Be '#5C7A96'
    }
}

Describe 'Footer version markup' {
    BeforeAll {
        $script:FooterStart = $script:ShellSource.IndexOf('<Grid x:Name="footerRow">')
    }

    It 'right-aligns a named version label beside the TravOS brand' {
        $script:ShellSource | Should -Match 'x:Name="footerRow"'
        $script:ShellSource | Should -Match 'x:Name="versionLabel"'
        $script:FooterStart | Should -BeGreaterThan 0

        $end = $script:ShellSource.IndexOf('</Grid>', $script:ShellSource.IndexOf('x:Name="versionLabel"'))
        $end | Should -BeGreaterThan $script:FooterStart
        $footer = $script:ShellSource.Substring($script:FooterStart, $end - $script:FooterStart)

        $footer | Should -Match 'x:Name="brandLabel"'
        $footer | Should -Match 'x:Name="versionLabel"'
        $footer | Should -Match 'HorizontalAlignment="Right"'
        # A third Auto column carries it so the brand label keeps the * slack.
        ([regex]::Matches($footer, '<ColumnDefinition')).Count | Should -Be 3
        $footer | Should -Match 'Grid\.Column="2"'
    }

    It 'stays ASCII so Windows PowerShell 5.1 can still parse Shell.ps1' {
        $script:FooterStart | Should -BeGreaterThan 0
        $chunk = $script:ShellSource.Substring($script:FooterStart, 900)
        @($chunk.ToCharArray() | Where-Object { [int]$_ -ge 128 }).Count | Should -Be 0
    }
}

Describe 'Footer version wiring' {
    It 'renders from the live app version and update state' {
        $script:ShellSource | Should -Match 'function Update-FooterVersion'
        $fn = Get-SourceFunctionText $script:ShellSource 'Update-FooterVersion'
        $fn | Should -Match 'versionLabel'
        $fn | Should -Match '\$script:AppVersion'
        $fn | Should -Match '\$script:UpdateState'
        $fn | Should -Match 'BrandLabelFg'
        $fn | Should -Match 'Resolve-FooterVersionFg'
    }

    It 'repaints on theme switch so a theme change cannot clobber the amber tint' {
        $fn = Get-SourceFunctionText $script:ShellSource 'Apply-UnifiedTheme'
        $fn | Should -Match 'Update-FooterVersion'
    }

    It 'repaints on every update-state change the tray funnels through' {
        $fn = Get-SourceFunctionText $script:TraySource 'Sync-UpdateMenuItems'
        $fn | Should -Match 'Update-FooterVersion'
        # Ahead of the menu-item guard, so the startup paint is never skipped.
        $fn.IndexOf('Update-FooterVersion') | Should -BeLessThan $fn.IndexOf('$script:updateItems')
    }

    It 'leaves the tray version row resolving from the same source' {
        $script:TraySource | Should -Match '\$miVersion'
        $script:TraySource | Should -Match '\$script:AppVersion'
    }
}

Describe 'Footer version costs no vertical height' {
    It 'measures identically with the version shown and hidden, and paints both states' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/FooterVersionProbe.ps1" -Root $script:Root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Footer version passed'
    }
}
