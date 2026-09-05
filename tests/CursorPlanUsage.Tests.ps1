#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\CursorData.ps1')
}

Describe 'Get-CursorPlanUsageFromSummary' {
    It 'reads Cursor Models / Other Models from individualUsage.plan' {
        $sum = [pscustomobject]@{
            membershipType = 'pro'
            billingCycleEnd = '2026-10-01T00:00:00.000Z'
            individualUsage = [pscustomobject]@{
                plan = [pscustomobject]@{
                    used = 8
                    limit = 2000
                    autoPercentUsed = 1
                    apiPercentUsed = 6
                }
                onDemand = [pscustomobject]@{ enabled = $false; used = 0 }
            }
        }
        $p = Get-CursorPlanUsageFromSummary $sum
        $p.Used | Should -Be 8
        $p.Limit | Should -Be 2000
        $p.AutoPercent | Should -Be 1
        $p.ApiPercent | Should -Be 6
        $p.BarPercent | Should -Be 1
        $p.OnDemandEnabled | Should -Be $false
        $p.MembershipType | Should -Be 'pro'
    }


    It 'Settings display message % wins over plan.autoPercentUsed (17% vs 11%)' {
        $sum = [pscustomobject]@{
            autoModelSelectedDisplayMessage = "You've used 17% of your included total usage"
            namedModelSelectedDisplayMessage = "You've used 90% of your included API usage"
            individualUsage = [pscustomobject]@{
                plan = [pscustomobject]@{
                    used = 2000
                    limit = 2000
                    autoPercentUsed = 10.88
                    apiPercentUsed = 89.9
                }
                onDemand = [pscustomobject]@{ enabled = $false; used = 0 }
            }
        }
        $p = Get-CursorPlanUsageFromSummary $sum
        $p.AutoPercent | Should -Be 17
        $p.ApiPercent | Should -Be 90
        $p.BarPercent | Should -Be 17
        Format-CursorPlanCountText $p | Should -Be '17%'
    }
    It 'falls back to display-message percents when plan percents are absent' {
        $sum = [pscustomobject]@{
            autoModelSelectedDisplayMessage = "You've used 1% of your included total usage"
            namedModelSelectedDisplayMessage = "You've used 6% of your included API usage"
            individualUsage = [pscustomobject]@{ plan = $null; onDemand = [pscustomobject]@{ enabled = $false; used = 0 } }
        }
        $p = Get-CursorPlanUsageFromSummary $sum
        $p.AutoPercent | Should -Be 1
        $p.ApiPercent | Should -Be 6
        $p.BarPercent | Should -Be 1
    }

    It 'does not invent 0 when summary is missing' {
        $p = Get-CursorPlanUsageFromSummary $null
        $p.Used | Should -BeNullOrEmpty
        $p.Limit | Should -BeNullOrEmpty
        $p.BarPercent | Should -BeNullOrEmpty
        $p.ApiPercent | Should -BeNullOrEmpty
        $p.OnDemandUsedCents | Should -BeNullOrEmpty
    }
}

Describe 'Cursor Plan & Usage HUD wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:History = Get-Content (Join-Path $root 'src\History.ps1') -Raw -Encoding UTF8
    }
    It 'labels MODELS / OTHER Codex-clean and paints from summary helper' {
        $script:Shell | Should -Match 'Text="MODELS"'
        $script:Shell | Should -Match 'Text="OTHER"'
        $script:Shell | Should -Not -Match 'CURSOR MODELS'
        $script:Shell | Should -Not -Match 'OTHER MODELS'
        $script:Shell | Should -Match 'reqSub'
        $script:Shell | Should -Match 'Get-CursorPlanUsageFromSummary'
        $script:Shell | Should -Match 'Do not paint from legacy usage'
        $script:Shell | Should -Not -Match "\$d\.'gpt-4'"
        $script:History | Should -Match 'Get-CursorPlanUsageFromSummary'
        $script:History | Should -Not -Match "numRequests"
    }
}


Describe 'Format-CursorPlanCountText' {
    It 'leads with plan % when used/limit fights the bar (2000/2000 vs ~10%)' {
        $plan = [pscustomobject]@{
            Used = 2000
            Limit = 2000
            BarPercent = 9.75
            AutoPercent = 9.75
        }
        Format-CursorPlanCountText $plan | Should -Be '10%'
    }

    It 'shows used/limit when the ratio agrees with the bar %' {
        $plan = [pscustomobject]@{
            Used = 500
            Limit = 1000
            BarPercent = 50
            AutoPercent = 50
        }
        Format-CursorPlanCountText $plan | Should -Be '500 / 1000'
    }

    It 'falls back to % when only BarPercent is present' {
        $plan = [pscustomobject]@{
            Used = $null
            Limit = $null
            BarPercent = 12.4
        }
        Format-CursorPlanCountText $plan | Should -Be '12%'
    }

    It 'returns -- when plan is empty' {
        Format-CursorPlanCountText $null | Should -Be '--'
        Format-CursorPlanCountText ([pscustomobject]@{}) | Should -Be '--'
    }
}

Describe 'Cursor clarity HUD wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
    }
    It 'paints Models count via Format-CursorPlanCountText and keeps on-demand secondary' {
        $script:Shell | Should -Match 'Format-CursorPlanCountText'
        $script:Shell | Should -Match 'onDemandRow'
        $script:Shell | Should -Match 'MODELS \(plan %\)'
        $script:Shell | Should -Match 'reqSub'
        $script:Shell | Should -Not -Match '<!-- ON-DEMAND HERO'
        $script:Shell | Should -Match 'Prefer bar % for overage'
    }
}
