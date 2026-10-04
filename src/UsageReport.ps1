# UsageReport.ps1 - lifetime model lines for the HUD, the clipboard, and usage-report.txt.
# Claude cache = cache-read / (input + cache write + cache read).
# Codex cache = cached input / input. Codex input already includes the cached part.
# Dollars are short-context API estimates, not the subscription bill.

function Get-UsageNote($Obj, [string]$Name) {
    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ModelUsageRows($Stats) {
    $raw = Get-UsageNote $Stats 'Models'
    if ($null -eq $raw) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($raw)) {
        if ($null -eq $row) { continue }
        $name = Get-UsageNote $row 'Name'
        if ($name) { $items.Add($row) }
    }
    if ($items.Count -eq 0) { return @() }
    return $items.ToArray()
}

function Format-UsagePercent($Numerator, $Denominator) {
    if ($null -eq $Denominator -or $Denominator -eq '') { return $null }
    $den = [double]$Denominator
    if ($den -le 0) { return $null }
    $num = 0.0
    if ($null -ne $Numerator -and $Numerator -ne '') { $num = [double]$Numerator }
    return [int][math]::Round((100.0 * $num / $den), [System.MidpointRounding]::AwayFromZero)
}

function Format-ModelMoney([double]$Amount) {
    if ([math]::Abs($Amount) -ge 100) {
        if (Get-Command Fmt-Money -ErrorAction SilentlyContinue) { return (Fmt-Money $Amount) }
        return ('${0:N0}' -f $Amount)
    }
    return ('${0:N2}' -f $Amount)
}

function Format-TopModelLine($Stats) {
    $rows = @(Get-ModelUsageRows $Stats)
    if ($rows.Count -eq 0) { return $null }
    $name = [string](Get-UsageNote $rows[0] 'Name')
    if (-not $name) { return $null }
    $cache = Format-UsagePercent (Get-UsageNote $rows[0] 'Cached') (Get-UsageNote $rows[0] 'CacheBase')
    if ($null -ne $cache) { return ('{0}  {1}% cache' -f $name, $cache) }
    return $name
}

function Format-TopModelTooltip($Stats) {
    $rows = @(Get-ModelUsageRows $Stats)
    if ($rows.Count -eq 0) { return $null }
    $top = $rows[0]
    $total = 0.0
    foreach ($row in $rows) {
        $base = Get-UsageNote $row 'CacheBase'
        if ($null -ne $base) { $total += [double]$base }
    }
    $share = Format-UsagePercent (Get-UsageNote $top 'CacheBase') $total
    $base = Get-UsageNote $top 'CacheBase'
    $out = Get-UsageNote $top 'Out'
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $share) { $parts.Add("$share% of input") }
    if ($null -ne $base -and [double]$base -gt 0 -and $null -ne $out) {
        $parts.Add(('{0:0.###} out per input' -f ([double]$out / [double]$base)))
    }
    $cost = Get-UsageNote $top 'Cost'
    if ($null -ne $cost) { $parts.Add(('~{0}' -f (Format-ModelMoney ([double]$cost)))) }
    $parts.Add('API estimate, not the subscription bill')
    return ($parts -join ' · ')
}

function Format-UsageTok([double]$Amount) {
    if (Get-Command Fmt-Tok -ErrorAction SilentlyContinue) { return (Fmt-Tok $Amount) }
    return ('{0:0}' -f $Amount)
}

function Format-ModelDetail($Row, [double]$TotalBase) {
    $name = [string](Get-UsageNote $Row 'Name')
    $inText = Format-UsageTok ([double](Get-UsageNote $Row 'In'))
    $cachedText = Format-UsageTok ([double](Get-UsageNote $Row 'Cached'))
    $outText = Format-UsageTok ([double](Get-UsageNote $Row 'Out'))
    $cache = Format-UsagePercent (Get-UsageNote $Row 'Cached') (Get-UsageNote $Row 'CacheBase')
    $share = Format-UsagePercent (Get-UsageNote $Row 'CacheBase') $TotalBase
    $cacheText = if ($null -eq $cache) { 'cache --' } else { "$cache% cache" }
    $shareText = if ($null -eq $share) { '' } else { "  $share% of input" }
    $money = Format-ModelMoney ([double](Get-UsageNote $Row 'Cost'))
    $turns = [int](Get-UsageNote $Row 'Turns')
    return ('{0}  {1} in / {2} cached / {3} out  {4}{5}  ~{6}  {7} records' -f $name, $inText, $cachedText, $outText, $cacheText, $shareText, $money, $turns)
}

function Get-ModelUsageExportLines {
    param(
        $Stats,
        [string]$Label,
        [int]$Limit = 8
    )

    $rows = @(Get-ModelUsageRows $Stats)
    if ($rows.Count -eq 0) { return @() }
    $total = 0.0
    foreach ($row in $rows) {
        $base = Get-UsageNote $row 'CacheBase'
        if ($null -ne $base) { $total += [double]$base }
    }
    $take = $rows.Count
    if ($Limit -gt 0 -and $Limit -lt $rows.Count) { $take = $Limit }
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $take; $i++) {
        $lines.Add(('{0} model: {1}' -f $Label, (Format-ModelDetail $rows[$i] $total)))
    }
    $rest = $rows.Count - $take
    if ($rest -gt 0) {
        $lines.Add(('{0} models: {1} more in usage-report.txt' -f $Label, $rest))
    }
    return @($lines)
}

function Get-UsageReportLines {
    param(
        [datetime]$GeneratedAt = (Get-Date),
        [string]$AppVersion = $script:AppVersion,
        $ClaudeIdentity = $script:ClaudeIdentity,
        $ClaudeUsage,
        $ClaudeStats = $script:Stats,
        $CodexStats = $script:CodexStats,
        $CursorSummary = $script:SummaryData,
        $CursorLocal = $script:LocalData,
        $GrokUsage = $script:GrokUsage,
        $Sections,
        [int]$ModelDetailLimit = 0
    )

    if (-not $PSBoundParameters.ContainsKey('ClaudeUsage')) {
        $ClaudeUsage = $null
        if ($script:State -is [System.Collections.IDictionary] -and $script:State.Contains('Data')) {
            $ClaudeUsage = $script:State['Data']
        } elseif ($script:State) {
            $ClaudeUsage = $script:State.Data
        }
    }
    if (-not $PSBoundParameters.ContainsKey('Sections')) {
        if ($script:Cfg -is [System.Collections.IDictionary] -and $script:Cfg.Contains('Sections')) {
            $Sections = $script:Cfg['Sections']
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Get-Command Get-UnifiedExportLines -ErrorAction SilentlyContinue) {
        foreach ($line in @(Get-UnifiedExportLines -GeneratedAt $GeneratedAt -AppVersion $AppVersion -ClaudeIdentity $ClaudeIdentity -ClaudeUsage $ClaudeUsage -ClaudeStats $ClaudeStats -CodexStats $CodexStats -CursorSummary $CursorSummary -CursorLocal $CursorLocal -GrokUsage $GrokUsage -Sections $Sections -ModelDetailLimit $ModelDetailLimit)) {
            $lines.Add([string]$line)
        }
    }
    $lines.Add('')
    $lines.Add('Claude cache is cache-read tokens divided by input + cache write + cache read.')
    $lines.Add('Codex cache is cached input divided by input. Codex input already includes cached input.')
    $lines.Add('Grok lifetime tokens: not logged on this machine. The panel shows the weekly quota.')
    $lines.Add('Estimates use short-context API rates. They are not the subscription bill.')
    return @($lines)
}

function Get-UsageReportPath {
    param([string]$Directory = $script:AppDir)
    if (-not $Directory) { return $null }
    return (Join-Path $Directory 'usage-report.txt')
}

function Write-UsageReport {
    param([string]$Path)

    if (-not $Path) { $Path = Get-UsageReportPath }
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { return }

    $text = (@(Get-UsageReportLines) -join "`r`n") + "`r`n"
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Copy($tmp, $Path, $true)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
