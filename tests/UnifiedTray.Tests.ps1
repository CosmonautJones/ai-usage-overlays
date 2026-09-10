#Requires -Module Pester

Describe 'Unified tray refresh menu' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:UnifiedTraySource = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
        $script:ThresholdAlertSource = [regex]::Match(
            $script:UnifiedTraySource,
            '(?s)# Threshold alert system.*?(?=# Context menu items)'
        ).Value
    }

    It 'wires Platforms from the shipped link catalog rather than a single Claude URL' {
        $script:UnifiedTraySource | Should -Match "New-StripItem 'Platforms'"
        $script:UnifiedTraySource | Should -Match 'Get-ProviderLinkMenuShape'
        $script:UnifiedTraySource | Should -Match 'Open-ProviderLink -Provider'
        $script:UnifiedTraySource | Should -Not -Match "New-StripItem 'Open claude.ai/usage'"
        $script:UnifiedTraySource | Should -Match 'Version \{0\}'
    }

    It 'routes Refresh now through the async refresh pipeline' {
        $script:UnifiedTraySource | Should -Match "New-StripItem 'Refresh now' \{ Invoke-ManualRefresh \}"
        $script:UnifiedTraySource | Should -Match 'function Invoke-ManualRefresh'
        $script:UnifiedTraySource | Should -Match 'Start-AllRefreshJobs'
    }

    It 'does not call provider fetchers directly from the Refresh now menu handler' {
        $refreshHandler = [regex]::Match(
            $script:UnifiedTraySource,
            "New-StripItem 'Refresh now' \{ (?<handler>.*?) \}"
        ).Groups['handler'].Value

        $refreshHandler | Should -Not -Match 'Get-Usage'
        $refreshHandler | Should -Not -Match 'Get-Stats'
        $refreshHandler | Should -Not -Match 'Get-CodexStats'
        $refreshHandler | Should -Not -Match 'Get-CursorUsage'
        $refreshHandler | Should -Not -Match 'Get-CursorLocalStats'
    }

    It 'positions the panel context menu in the WinForms pointer coordinate space' {
        $script:UnifiedTraySource | Should -Match 'function Show-ContextMenuAtWpfPointer'
        $script:UnifiedTraySource | Should -Match 'function Get-ContextMenuScreenPoint'
        $script:UnifiedTraySource | Should -Match '\[System.Windows.Forms.Control\]::MousePosition'
        $script:UnifiedTraySource | Should -Not -Match '\$script:window.PointToScreen\('

        $rightClickHandler = [regex]::Match(
            $script:UnifiedTraySource,
            '\$script:window\.Add_MouseRightButtonUp\(\{\s*(?<handler>.*?)\s*\}\)',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Groups['handler'].Value

        $rightClickHandler | Should -Match 'Show-ContextMenuAtWpfPointer \$e'
        $rightClickHandler | Should -Not -Match 'MousePosition'
    }

    It 'exposes test and dismiss alert menu controls' {
        $script:UnifiedTraySource | Should -Match "New-StripItem 'Test alert' \{ Invoke-TestAlert \}"
        $script:UnifiedTraySource | Should -Match "New-StripItem 'Dismiss current alert' \{ Dismiss-CurrentAlerts \}"
    }

    It 'includes an automatic update check toggle and background update path' {
        $script:UnifiedTraySource | Should -Match "New-StripItem 'Automatically check for updates'"
        $script:UnifiedTraySource | Should -Match 'function Start-AppUpdateBackgroundCheck'
        $script:UnifiedTraySource | Should -Match 'Start-OverlayBackgroundJob'
        $script:UnifiedTraySource | Should -Match 'function Invoke-AutomaticUpdateCheck'
        $script:UnifiedTraySource | Should -Match 'function Complete-AppUpdateCheckJobs'
    }

    It 'gates automatic update notifications by the persisted notified release version' {
        $script:UnifiedTraySource | Should -Match 'Test-AppUpdateNotificationDue -Info \$info -LastNotifiedVersion \$script:Cfg.LastNotifiedUpdateVersion'
        $script:UnifiedTraySource | Should -Match '\$script:Cfg.LastNotifiedUpdateVersion = Get-AppUpdateVersionKey \$info'
        $script:UnifiedTraySource | Should -Match 'Save-UnifiedState'
    }

    It 'loads persisted threshold alert state into the tray alert cache' {
        $root = Split-Path $PSScriptRoot -Parent
        $unifiedStateSource = Get-Content (Join-Path $root 'src\UnifiedState.ps1') -Raw -Encoding UTF8

        $unifiedStateSource | Should -Match '\$s\.PSObject\.Properties\[''AlertState''\]'
        $unifiedStateSource | Should -Match 'Import-AlertStateFromConfig'
    }

    It 'keeps manual update checks bypassing the automatic interval gate' {
        $manualCheck = [regex]::Match(
            $script:UnifiedTraySource,
            '(?s)function Invoke-ManualUpdateCheck \{(?<body>.*?)\n\}'
        ).Groups['body'].Value

        $manualCheck | Should -Match 'Start-AppUpdateBackgroundCheck'
        $manualCheck | Should -Not -Match 'Test-AppUpdateAutoCheckDue'
        $manualCheck | Should -Not -Match 'Invoke-AutomaticUpdateCheck'
    }
}

Describe 'Unified tray threshold alerts' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms

        $root = Split-Path $PSScriptRoot -Parent
        $source = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
        $script:ThresholdAlertSource = [regex]::Match(
            $source,
            '(?s)# Threshold alert system.*?(?=# Context menu items)'
        ).Value
    }

    BeforeEach {
        $script:Cfg = @{ ShowAlerts = $true }
        $script:WarnPct = 80
        $script:CritPct = 95
        $script:History = @()
        $script:SaveUnifiedStateCalls = 0
        function Save-UnifiedState { $script:SaveUnifiedStateCalls++ }
        $script:BalloonCalls = [System.Collections.Generic.List[object]]::new()
        $script:notify = [pscustomobject]@{}
        $script:notify | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value {
            param($timeout, $title, $message, $icon)
            $script:BalloonCalls.Add([pscustomobject]@{
                Timeout = $timeout
                Title = $title
                Message = $message
                Icon = $icon
            })
        }
        $script:State = [pscustomobject]@{
            Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{
                    utilization = 0
                    resets_at = '2026-07-06T18:00:00Z'
                }
            }
        }

        . ([scriptblock]::Create($script:ThresholdAlertSource))
    }

    It 'sends a test alert through the tray notification path' {
        Invoke-TestAlert

        $script:BalloonCalls.Count | Should -Be 1
        $script:BalloonCalls[0].Title | Should -Be 'AI Usage Overlay Test'
        $script:BalloonCalls[0].Message | Should -Be 'Threshold alerts are working.'
    }

    It 'fires a warning only once in the same reset window' {
        $script:State.Data.five_hour.utilization = 85

        Check-Alert 'five_hour' 85
        Check-Alert 'five_hour' 86

        $script:BalloonCalls.Count | Should -Be 1
        $script:BalloonCalls[0].Title | Should -Be 'Claude Usage Warning'
        $script:Cfg.AlertState['five_hour']['Level'] | Should -Be 80
        $script:Cfg.AlertState['five_hour']['Reset'] | Should -Be '2026-07-06T18:00:00Z'
    }

    It 'does not refire a persisted warning alert after restart in the same reset window' {
        $script:Cfg.AlertState = @{
            five_hour = @{ Level = 80; Reset = '2026-07-06T18:00:00Z' }
        }
        . ([scriptblock]::Create($script:ThresholdAlertSource))

        Check-Alert 'five_hour' 86

        $script:BalloonCalls.Count | Should -Be 0
    }

    It 'does not refire a persisted critical alert after restart in the same reset window' {
        $script:Cfg.AlertState = @{
            five_hour = @{ Level = 95; Reset = '2026-07-06T18:00:00Z' }
        }
        . ([scriptblock]::Create($script:ThresholdAlertSource))

        Check-Alert 'five_hour' 97

        $script:BalloonCalls.Count | Should -Be 0
    }

    It 're-arms persisted alerting when usage drops below the warning threshold' {
        $script:Cfg.AlertState = @{
            five_hour = @{ Level = 95; Reset = '2026-07-06T18:00:00Z' }
        }
        . ([scriptblock]::Create($script:ThresholdAlertSource))

        Check-Alert 'five_hour' 20
        Check-Alert 'five_hour' 85

        $script:BalloonCalls.Count | Should -Be 1
        $script:BalloonCalls[0].Title | Should -Be 'Claude Usage Warning'
        $script:Cfg.AlertState['five_hour']['Level'] | Should -Be 80
    }

    It 're-arms alerting when the reset window changes' {
        $script:State.Data.five_hour.utilization = 85

        Check-Alert 'five_hour' 85
        $script:State.Data.five_hour.resets_at = '2026-07-06T23:00:00Z'
        Check-Alert 'five_hour' 85

        $script:BalloonCalls.Count | Should -Be 2
        $script:Cfg.AlertState['five_hour']['Reset'] | Should -Be '2026-07-06T23:00:00Z'
    }

    It 'dismisses the current active alert condition for the current reset window' {
        $script:State.Data.five_hour.utilization = 96

        Dismiss-CurrentAlerts
        Check-Alert 'five_hour' 96

        $script:BalloonCalls.Count | Should -Be 0
        $script:Notified['five_hour']['Level'] | Should -Be 95
    }

    It 'keeps the threshold alerts toggle authoritative' {
        $script:Cfg.ShowAlerts = $false
        $script:State.Data.five_hour.utilization = 96

        Check-Alert 'five_hour' 96

        $script:BalloonCalls.Count | Should -Be 0
    }
}
