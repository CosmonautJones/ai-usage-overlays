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
    It 'labels Cursor Models and Other Models and paints from summary helper' {
        $script:Shell | Should -Match 'CURSOR MODELS'
        $script:Shell | Should -Match 'OTHER MODELS'
        $script:Shell | Should -Match 'Get-CursorPlanUsageFromSummary'
        $script:Shell | Should -Match 'Do not paint from legacy usage'
        $script:Shell | Should -Not -Match "\$d\.'gpt-4'"
        $script:History | Should -Match 'Get-CursorPlanUsageFromSummary'
        $script:History | Should -Not -Match "numRequests"
    }
}
