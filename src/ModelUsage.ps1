# ModelUsage.ps1 - per-model lifetime buckets. Dot-sourced by Data.ps1 and CodexData.ps1.
# Rows are the tokens already parsed. No extra log scan and no cache-version bump.

function Add-ModelUsage($Buckets, [string]$Name, [long]$In, [long]$Out, [long]$Cached, [long]$CacheBase, $Cost) {
    if (-not $Buckets) { return }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = '(unknown)' }
    if (-not $Buckets.ContainsKey($Name)) {
        $Buckets[$Name] = @{
            Name      = $Name
            In        = [long]0
            Out       = [long]0
            Cached    = [long]0
            CacheBase = [long]0
            Cost      = [double]0
            Turns     = [int]0
        }
    }
    $row = $Buckets[$Name]
    $row.In        += $In
    $row.Out       += $Out
    $row.Cached    += $Cached
    $row.CacheBase += $CacheBase
    $row.Cost      += [double]$Cost
    $row.Turns     += 1
}

function Get-SortedModelRows($Buckets) {
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($Buckets) {
        foreach ($name in @($Buckets.Keys)) {
            $b = $Buckets[$name]
            # Claude writes an empty <synthetic> bucket. It is not a model the user picked.
            if ($b.Name -eq '<synthetic>' -and $b.In -eq 0 -and $b.Out -eq 0 -and $b.Cached -eq 0) { continue }
            $rows.Add([pscustomobject]@{
                Name      = [string]$b.Name
                In        = [long]$b.In
                Out       = [long]$b.Out
                Cached    = [long]$b.Cached
                CacheBase = [long]$b.CacheBase
                Cost      = [double]$b.Cost
                Turns     = [int]$b.Turns
            })
        }
    }
    if ($rows.Count -eq 0) { return ,@() }
    # Most context + output first. Name breaks ties so the order is stable.
    $sorted = @(
        $rows.ToArray() | Sort-Object @{ Expression = { -([double]$_.CacheBase + [double]$_.Out) } }, @{ Expression = { [string]$_.Name } }
    )
    return ,$sorted
}
