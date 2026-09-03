#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    # History.ps1 references $script:AppDir at parse/dot-source time to build $script:HistoryPath
    $script:AppDir = $root
    . (Join-Path $root 'src\Config.ps1')
    . (Join-Path $root 'src\History.ps1')
}

Describe 'Add-HistorySample (ring buffer)' {
    BeforeEach {
        $script:History = [System.Collections.Generic.List[object]]::new()
        $script:HistoryMaxLen = 480
    }
    It 'adds a sample with correct fields' {
        $data = [PSCustomObject]@{
            five_hour        = [PSCustomObject]@{ utilization = 50.0 }
            seven_day        = [PSCustomObject]@{ utilization = 30.0 }
            seven_day_fable  = [PSCustomObject]@{ utilization = 20.0 }
            seven_day_opus   = $null
        }
        Add-HistorySample $data
        $script:History.Count | Should -Be 1
        $script:History[0].five_hour  | Should -Be 50.0
        $script:History[0].seven_day  | Should -Be 30.0
        $script:History[0].seven_day_fable | Should -Be 20.0
        $script:History[0].seven_day_opus | Should -BeNullOrEmpty
    }
    It 'trims to HistoryMaxLen when exceeded' {
        $script:HistoryMaxLen = 5
        $data = [PSCustomObject]@{
            five_hour        = [PSCustomObject]@{ utilization = 10.0 }
            seven_day        = $null
            seven_day_fable  = $null
            seven_day_opus   = $null
        }
        for ($i = 0; $i -lt 7; $i++) { Add-HistorySample $data }
        $script:History.Count | Should -Be 5
    }
}

Describe 'Get-Eta' {
    It 'returns $null with fewer than 3 samples' {
        Get-Eta @() 'five_hour' | Should -BeNullOrEmpty

        $s = [PSCustomObject]@{
            t         = (Get-Date).AddMinutes(-5) | Get-Date -Format 'o'
            five_hour = 10
        }
        Get-Eta @($s) 'five_hour' | Should -BeNullOrEmpty
    }
    It 'returns $null for flat data' {
        $now = Get-Date
        $samples = 0..4 | ForEach-Object {
            [PSCustomObject]@{
                t         = $now.AddMinutes(-$_ * 5) | Get-Date -Format 'o'
                five_hour = 50.0
            }
        }
        Get-Eta $samples 'five_hour' | Should -BeNullOrEmpty
    }
    It 'returns $null for decreasing data' {
        $now = Get-Date
        # Samples ordered oldest-first: times go from -20min to now, values go 80 -> 60 (decreasing)
        $samples = 0..4 | ForEach-Object {
            [PSCustomObject]@{
                t         = $now.AddMinutes($_ * 5 - 20) | Get-Date -Format 'o'
                five_hour = 80.0 - ($_ * 5)  # 80, 75, 70, 65, 60 - decreasing over time
            }
        }
        Get-Eta $samples 'five_hour' | Should -BeNullOrEmpty
    }
    It 'returns positive minutes for clearly rising data' {
        $now = Get-Date
        # Rising from 10% to 50% over 40 minutes - ETA should be well-defined
        $samples = 0..4 | ForEach-Object {
            [PSCustomObject]@{
                t         = $now.AddMinutes($_ * 10 - 40) | Get-Date -Format 'o'
                five_hour = 10.0 + ($_ * 10)  # 10, 20, 30, 40, 50
            }
        }
        $eta = Get-Eta $samples 'five_hour'
        $eta | Should -Not -BeNullOrEmpty
        $eta | Should -BeGreaterThan 0
    }
    It 'returns $null when ETA is more than 24 hours away' {
        $now = Get-Date
        # Very slow rise: 0% to 1% over 60 min - would take hundreds of hours
        $samples = 0..4 | ForEach-Object {
            [PSCustomObject]@{
                t         = $now.AddMinutes($_ * 15 - 60) | Get-Date -Format 'o'
                five_hour = 0.0 + ($_ * 0.25)  # 0, 0.25, 0.5, 0.75, 1.0
            }
        }
        Get-Eta $samples 'five_hour' | Should -BeNullOrEmpty
    }
}

Describe 'Add-HistorySample provider extras' {
    BeforeEach {
        $script:History = [System.Collections.Generic.List[object]]::new()
        $script:HistoryMaxLen = 480
        $script:CodexStats = $null
        $script:GrokUsage = $null
        $script:LiveData = $null
        $script:HistoryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hist-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    AfterEach {
        Remove-Item -LiteralPath $script:HistoryPath -Force -ErrorAction SilentlyContinue
    }
    It 'writes extra keys as $null and never invents 0 from a missing provider' {
        $data = [PSCustomObject]@{
            five_hour = [PSCustomObject]@{ utilization = 50.0 }
            seven_day = [PSCustomObject]@{ utilization = 30.0 }
        }
        Add-HistorySample $data
        $s = $script:History[0]
        $s.codex_five_hour | Should -BeNullOrEmpty
        $s.codex_seven_day | Should -BeNullOrEmpty
        $s.grok_seven_day | Should -BeNullOrEmpty
        $s.cursor_requests | Should -BeNullOrEmpty
        $s.five_hour | Should -Be 50.0
    }
    It 'records live extras as numbers without coercing missing to 0' {
        $script:CodexStats = [pscustomobject]@{ FiveHourPct = 33; WeekPct = 100 }
        $script:GrokUsage = [pscustomobject]@{ WeekPct = 25 }
        $script:LiveData = [pscustomobject]@{ 'gpt-4' = [pscustomobject]@{ numRequests = 10; maxRequestUsage = 50 } }
        Add-HistorySample ([PSCustomObject]@{ five_hour = [PSCustomObject]@{ utilization = 10.0 } })
        $s = $script:History[0]
        $s.codex_five_hour | Should -Be 33
        $s.codex_seven_day | Should -Be 100
        $s.grok_seven_day | Should -Be 25
        $s.cursor_requests | Should -Be 20
    }
    It 'leaves cursor_requests null when maxRequestUsage is 0' {
        $script:LiveData = [pscustomobject]@{ 'gpt-4' = [pscustomobject]@{ numRequests = 0; maxRequestUsage = 0 } }
        Add-HistorySample ([PSCustomObject]@{ five_hour = [PSCustomObject]@{ utilization = 10.0 } })
        $script:History[0].cursor_requests | Should -BeNullOrEmpty
    }
    It 'leaves Codex 5-hour null when FiveHourPct is missing' {
        $script:CodexStats = [pscustomobject]@{ WeekPct = 80 }
        Add-HistorySample ([PSCustomObject]@{ five_hour = [PSCustomObject]@{ utilization = 10.0 } })
        $script:History[0].codex_five_hour | Should -BeNullOrEmpty
        $script:History[0].codex_seven_day | Should -Be 80
    }
}

Describe 'Codex 5-hour HUD hide' {
    It 'Update-CodexSection hides the 5-HOUR row when FiveHourPct is null' {
        $root = Split-Path $PSScriptRoot -Parent
        $shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $shell | Should -Match 'x:Name="codexFivehRow"'
        $shell | Should -Match 'x:Name="codexFivehRowC"'
        $fn = [regex]::Match($shell, '(?s)function Update-CodexSection \{.*?\nfunction Update-GrokSection').Value
        $fn | Should -Match 'FiveHourPct'
        $fn | Should -Match 'codexFivehRow'
        $fn | Should -Match 'Collapsed'
    }
}

Describe 'Spark rows under each real bar' {
    It 'clones 14px polylines for Codex Grok and Cursor in full and compact' {
        $root = Split-Path $PSScriptRoot -Parent
        $shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $state = Get-Content (Join-Path $root 'src\UnifiedState.ps1') -Raw -Encoding UTF8
        $overlay = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $shell | Should -Match 'codexWeekSparkRow'
        $shell | Should -Match 'codexWeekSparkRowC'
        $shell | Should -Match 'grokWeekSparkRow'
        $shell | Should -Match 'cursorReqSparkRow'
        $shell | Should -Match 'Set-Spark .*codex_seven_day'
        $shell | Should -Match 'Set-Spark .*grok_seven_day'
        $shell | Should -Match 'Set-Spark .*cursor_requests'
        $state | Should -Match 'SparkRowNames'
        $overlay | Should -Match 'Complete-UnifiedHistoryPoll'
    }
}

Describe 'Complete-UnifiedHistoryPoll (D-HIST-1)' {
    BeforeEach {
        $script:History = [System.Collections.Generic.List[object]]::new()
        $script:HistoryMaxLen = 480
        $script:State = @{ Data = $null; Status = 'auth'; Message = 'Auth expired' }
        $script:CodexStats = $null
        $script:GrokUsage = $null
        $script:LiveData = $null
        $script:HistoryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hist-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    AfterEach {
        Remove-Item -LiteralPath $script:HistoryPath -Force -ErrorAction SilentlyContinue
    }
    It 'two poll completes with Claude data null still produce two timestamps and non-null Codex/Grok keys' {
        $script:CodexStats = [pscustomobject]@{ FiveHourPct = 12; WeekPct = 80 }
        $script:GrokUsage = [pscustomobject]@{ WeekPct = 25 }
        Complete-UnifiedHistoryPoll
        Start-Sleep -Milliseconds 15
        Complete-UnifiedHistoryPoll
        $script:History.Count | Should -Be 2
        $script:History[0].t | Should -Not -Be $script:History[1].t
        $script:History[0].five_hour | Should -BeNullOrEmpty
        $script:History[1].five_hour | Should -BeNullOrEmpty
        $script:History[0].seven_day | Should -BeNullOrEmpty
        $script:History[1].seven_day | Should -BeNullOrEmpty
        $script:History[0].codex_five_hour | Should -Be 12
        $script:History[1].codex_five_hour | Should -Be 12
        $script:History[0].codex_seven_day | Should -Be 80
        $script:History[1].codex_seven_day | Should -Be 80
        $script:History[0].grok_seven_day | Should -Be 25
        $script:History[1].grok_seven_day | Should -Be 25
        $script:History[0].cursor_requests | Should -BeNullOrEmpty
        $script:History[1].cursor_requests | Should -BeNullOrEmpty
    }
}
