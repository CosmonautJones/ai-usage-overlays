BeforeAll {
    . "$PSScriptRoot/../src/GrokData.ps1"
    function Pack-Varint([long]$Value) {
        $b=[Collections.Generic.List[byte]]::new()
        do { $x=[byte]($Value -band 127); $Value=$Value -shr 7; if($Value){$x=$x -bor 128}; $b.Add($x) } while($Value)
        return ,$b.ToArray()
    }
    function Pack-Field([int]$Number,[byte[]]$Body) {
        return ,([byte[]]((Pack-Varint ($Number*8+2)) + (Pack-Varint $Body.Length) + $Body))
    }
    function Pack-Reset([string]$Id,[long]$Start,[long]$End) {
        $idField=Pack-Field 10 ([Text.Encoding]::UTF8.GetBytes($Id))
        $startField=Pack-Field 20 ([byte[]](@(8)+(Pack-Varint $Start)))
        $endField=Pack-Field 30 ([byte[]](@(8)+(Pack-Varint $End)))
        return ,(Pack-Field 10 ([byte[]]($idField+$startField+$endField)))
    }
    function Pack-Frame([byte[]]$Body,[byte]$Flag=0) {
        return ,([byte[]](@($Flag,0,0,($Body.Length -shr 8),($Body.Length -band 255))+$Body))
    }
    function Pack-Response([byte[]]$Body,[string]$Status='0') {
        return ,([byte[]]((Pack-Frame $Body)+(Pack-Frame ([Text.Encoding]::ASCII.GetBytes("grpc-status:$Status`r`n")) 128)))
    }
    $now=[datetimeoffset]::FromUnixTimeSeconds(1800000000)
}
Describe 'Grok one-time reset response' {
    It 'counts unique, currently valid reset tokens without exposing their IDs' {
        $valid=Pack-Reset 'fixture-valid' 1700000000 1900000000
        $expired=Pack-Reset 'fixture-expired' 1600000000 1700000000
        $future=Pack-Reset 'fixture-future' 1850000000 1950000000
        $r=ConvertFrom-GrokResetsResponse (Pack-Response ([byte[]]($valid+$valid+$expired+$future))) -Now $now
        $r.ResetsAvailable | Should -Be 1
        $r.ResetStatus | Should -Be 'ok'
        ($r | ConvertTo-Json) | Should -Not -Match 'fixture-'
    }
    It 'distinguishes a successful empty response from failure' {
        (ConvertFrom-GrokResetsResponse (Pack-Response @()) -Now $now).ResetsAvailable | Should -Be 0
    }
    It 'rejects an HTTP-success response containing a gRPC authentication error' {
        { ConvertFrom-GrokResetsResponse (Pack-Response @() '16') } | Should -Throw
    }
    It 'rejects truncated frames and missing status trailers' {
        { ConvertFrom-GrokResetsResponse ([byte[]]@(0,0,0,0,9,1)) } | Should -Throw
        { ConvertFrom-GrokResetsResponse (Pack-Frame @()) } | Should -Throw
    }
    It 'rejects incomplete token records instead of claiming zero available' {
        { ConvertFrom-GrokResetsResponse (Pack-Response (Pack-Field 10 (Pack-Field 10 ([Text.Encoding]::UTF8.GetBytes('fixture'))))) } | Should -Throw
    }
    It 'keeps lookup failures unknown rather than zero' {
        Mock Invoke-WebRequest { throw 'network unavailable' }
        $r=Get-GrokRemainingResets -Token 'fixture-token'
        $r.ResetsAvailable | Should -BeNullOrEmpty
        $r.ResetStatus | Should -Be 'unavailable'
    }
    It 'preserves weekly usage when only the reset lookup fails' {
        $authPath=Join-Path $TestDrive 'auth.json'
        '{"access_token":"fixture-token"}' | Set-Content $authPath
        Mock Invoke-RestMethod { [pscustomobject]@{config=[pscustomobject]@{creditUsagePercent=57}} }
        Mock Get-GrokRemainingResets { @{ResetsAvailable=$null;ResetStatus='unavailable'} }
        $r=Get-GrokLiveUsage -AuthPath $authPath
        $r.WeekPct | Should -Be 57
        $r.ResetsAvailable | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'ok'
    }
}

Describe 'Grok reset display' {
    BeforeAll {
        $source=Get-Content "$PSScriptRoot/../src/Shell.ps1" -Raw
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-GrokResetDisplay'},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    BeforeEach {
        $script:label=[pscustomobject]@{Text='old';ToolTip='old'}
        $script:window=[pscustomobject]@{}
        $script:window | Add-Member ScriptMethod FindName {param($Name) $script:label}
        $script:GrokAuthState='ok'
    }
    It 'shows a confirmed zero' {
        $script:GrokUsage=@{ResetsAvailable=0;ResetStatus='ok'}
        Update-GrokResetDisplay
        $script:label.Text | Should -Be '0 available'
    }
    It 'shows the count and expiry' {
        $script:GrokUsage=@{ResetsAvailable=1;ResetStatus='ok';ResetExpiresAt=[datetimeoffset]::Now.AddDays(2)}
        Update-GrokResetDisplay
        $script:label.Text | Should -Be '1 available'
        $script:label.ToolTip | Should -Match 'Earliest expires'
    }
    It 'clears a previously shown count on lookup failure' {
        $script:GrokUsage=@{ResetsAvailable=$null;ResetStatus='unavailable'}
        Update-GrokResetDisplay
        $script:label.Text | Should -Be '--'
    }
    It 'does not advertise stale or expired resets' {
        $script:GrokUsage=@{ResetsAvailable=1;ResetStatus='ok';ResetExpiresAt=[datetimeoffset]::Now.AddSeconds(-1)}
        Update-GrokResetDisplay
        $script:label.Text | Should -Be '--'
        $script:GrokAuthState='stale'
        $script:GrokUsage.ResetExpiresAt=[datetimeoffset]::Now.AddDays(1)
        Update-GrokResetDisplay
        $script:label.Text | Should -Be '--'
    }
}
