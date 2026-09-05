# GrokData.ps1 - SuperGrok / grok CLI billing adapter
#
# Same auth contract as Codex: init | ok | stale | auth | notoken + message.
# Never log or snapshot the bearer token.

$script:GrokAuthState = 'init'
$script:GrokErrMsg    = ''
$script:GrokUsage     = $null

function Set-GrokAuthState {
    param([string]$State, [string]$Message = '')

    $script:GrokAuthState = $State
    $script:GrokErrMsg    = $Message
}

function Write-GrokLog {
    param([string]$Message)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message
    }
}

function Resolve-GrokAuthPath {
    param([string]$AuthPath)

    if ($AuthPath) { return $AuthPath }

    if ($env:GROK_HOME) {
        try { return (Join-Path $env:GROK_HOME 'auth.json') } catch { }
    }

    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if ($root) {
            try { return (Join-Path (Join-Path $root '.grok') 'auth.json') } catch { }
        }
    }

    return (Join-Path $env:USERPROFILE '.grok\auth.json')
}

function Get-GrokNoteValue {
    param($Obj, [string]$Name)

    if (-not $Obj -or -not $Name) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }

    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }

    return $null
}

function Test-GrokAuthEntryExpired {
    param($Entry)

    $raw = Get-GrokNoteValue $Entry 'expires_at'
    if (-not $raw) { return $false }

    try {
        $exp = [datetimeoffset]::Parse([string]$raw)
        return ($exp -le [datetimeoffset]::Now)
    } catch {
        return $false
    }
}

function Get-GrokTokenFromEntry {
    param($Entry)

    if (-not $Entry) { return $null }
    if (Test-GrokAuthEntryExpired $Entry) { return $null }

    foreach ($name in @('key', 'access_token')) {
        $val = Get-GrokNoteValue $Entry $name
        if ($val -is [string] -and $val) { return $val }
    }

    $tokens = Get-GrokNoteValue $Entry 'tokens'
    $nested = Get-GrokNoteValue $tokens 'access_token'
    if ($nested -is [string] -and $nested) { return $nested }

    return $null
}

function Get-GrokAccessToken {
    param($Auth)

    if (-not $Auth) { return $null }

    $preferred = [System.Collections.Generic.List[object]]::new()
    $fallback  = [System.Collections.Generic.List[object]]::new()

    if ($Auth.PSObject) {
        foreach ($prop in $Auth.PSObject.Properties) {
            $val = $prop.Value
            if ($null -eq $val -or $val -is [string] -or $val -is [ValueType]) { continue }
            if ($prop.Name -like 'https://auth.x.ai::*') {
                [void]$preferred.Add($val)
            } else {
                [void]$fallback.Add($val)
            }
        }
    }

    foreach ($entry in $preferred) {
        $token = Get-GrokTokenFromEntry $entry
        if ($token) { return $token }
    }
    foreach ($entry in $fallback) {
        $token = Get-GrokTokenFromEntry $entry
        if ($token) { return $token }
    }

    return Get-GrokTokenFromEntry $Auth
}

function Convert-GrokPeriodEnd {
    param($Value)

    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [System.DateTimeOffset]::Parse([string]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Convert-GrokPrepaidText {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [ValueType]) {
        try { return ('{0:N2}' -f [double]$Value) } catch { return [string]$Value }
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($name in @('val', 'amount', 'balance', 'credits', 'remaining', 'value')) {
            if ($Value.Contains($name) -and $null -ne $Value[$name]) {
                try { return ('{0:N2}' -f [double]$Value[$name]) } catch { return [string]$Value[$name] }
            }
        }
        return $null
    }

    $amount = $null
    foreach ($name in @('val', 'amount', 'balance', 'credits', 'remaining', 'value')) {
        $prop = $Value.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $amount = $prop.Value
            break
        }
    }
    if ($null -eq $amount) { return $null }
    try { return ('{0:N2}' -f [double]$amount) } catch { return [string]$amount }
}

function Format-GrokProductChip {
    param(
        [string]$Name,
        $Qty,
        [switch]$AsPercent
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($null -eq $Qty) { return $Name }
    try {
        $n = [double]$Qty
        if ($AsPercent) { return ('{0} {1:0}%' -f $Name, $n) }
        return ('{0} {1}' -f $Name, $Qty)
    } catch {
        return ('{0} {1}' -f $Name, $Qty)
    }
}

function Format-GrokProductUsage {
    # Chips like "GrokChat 20% | GrokBuild 5%". usagePercent is a qty on a named
    # product — never emit prop names like "usagePercent 20".
    param($Usage)

    if ($null -eq $Usage) { return $null }

    $sep = ' | '
    $parts = [System.Collections.Generic.List[string]]::new()
    $items = if ($Usage -is [System.Collections.IEnumerable] -and $Usage -isnot [string]) { @($Usage) } else { @($Usage) }
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($k in @($item.Keys)) {
                if ($null -eq $item[$k]) { continue }
                $chip = Format-GrokProductChip -Name ([string]$k) -Qty $item[$k] -AsPercent
                if ($chip) { [void]$parts.Add($chip) }
            }
            continue
        }
        if ($item.PSObject) {
            $named = $null
            $qty = $null
            $asPct = $false
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('product', 'name')) {
                    $named = [string]$prop.Value
                    continue
                }
                if ($prop.Name -in @('usagePercent', 'percent', 'creditUsagePercent') -and $null -ne $prop.Value) {
                    $qty = $prop.Value
                    $asPct = $true
                    continue
                }
                if ($prop.Name -in @('count', 'usage', 'credits', 'val', 'value', 'amount') -and $null -ne $prop.Value) {
                    $qty = $prop.Value
                    continue
                }
            }
            if ($named) {
                $chip = Format-GrokProductChip -Name $named -Qty $qty -AsPercent:$asPct
                if ($chip) { [void]$parts.Add($chip) }
                continue
            }
            # Shorthand notes: { GrokChat = 20 } with no product/name field.
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('product', 'name', 'usagePercent', 'percent', 'creditUsagePercent', 'count', 'usage', 'credits', 'val', 'value', 'amount')) {
                    continue
                }
                if ($null -eq $prop.Value) { continue }
                if (-not ($prop.Value -is [ValueType] -or $prop.Value -is [string])) { continue }
                $chip = Format-GrokProductChip -Name ([string]$prop.Name) -Qty $prop.Value -AsPercent
                if ($chip) { [void]$parts.Add($chip) }
            }
        }
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join $sep)
}
function Convert-GrokPlanType {
    param($Obj)

    if (-not $Obj) { return $null }

    foreach ($candidate in @(
        $Obj.product,
        $(if ($Obj.config) { $Obj.config.product }),
        $(if ($Obj.config) { $Obj.config.plan }),
        $Obj.plan,
        $Obj.planType
    )) {
        if ($candidate) { return [string]$candidate }
    }

    $usage = $Obj.productUsage
    if (-not $usage -and $Obj.config) { $usage = $Obj.config.productUsage }
    if ($usage) {
        if ($usage -is [System.Collections.IEnumerable] -and $usage -isnot [string]) {
            foreach ($item in @($usage)) {
                if ($item -and $item.product) { return [string]$item.product }
                if ($item -and $item.name) { return [string]$item.name }
            }
        } elseif ($usage.product) {
            return [string]$usage.product
        }
    }

    return $null
}

# Pure parser so tests do not need a network call. All fields optional.
function ConvertFrom-GrokBillingResponse($obj) {
    if (-not $obj) { return $null }

    $cfg = $obj.config
    $weekPct = $null
    $weekResetsAt = $null

    if ($cfg) {
        if ($null -ne $cfg.creditUsagePercent) {
            try { $weekPct = [double]$cfg.creditUsagePercent } catch { }
        }
        if ($cfg.currentPeriod) {
            $weekResetsAt = Convert-GrokPeriodEnd $cfg.currentPeriod.end
        }
    }

    $prepaidRaw = $null
    $productRaw = $null
    if ($cfg) {
        $prepaidRaw = Get-GrokNoteValue $cfg 'prepaidBalance'
        $productRaw = Get-GrokNoteValue $cfg 'productUsage'
    }
    if ($null -eq $prepaidRaw) { $prepaidRaw = Get-GrokNoteValue $obj 'prepaidBalance' }
    if ($null -eq $productRaw) { $productRaw = Get-GrokNoteValue $obj 'productUsage' }

    $productText = Format-GrokProductUsage $productRaw

    return @{
        WeekPct           = $weekPct
        WeekResetsAt      = $weekResetsAt
        PrepaidBalance    = Convert-GrokPrepaidText $prepaidRaw
        ProductUsage      = $productRaw
        ProductUsageText  = $productText
        PlanType          = Convert-GrokPlanType $obj
    }
}

function Get-GrokLiveUsage {
    param(
        [int]$TimeoutSec = 15,
        [string]$AuthPath
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = 15 }
    $TimeoutSec = [math]::Min(120, [math]::Max(1, $TimeoutSec))

    $path = Resolve-GrokAuthPath -AuthPath $AuthPath
    if (-not (Test-Path -LiteralPath $path)) {
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    try {
        $auth = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        Write-GrokLog "Get-GrokLiveUsage: cannot read auth.json - $($_.Exception.Message)"
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    $token = Get-GrokAccessToken $auth
    if (-not $token) {
        Set-GrokAuthState 'notoken' 'run grok login'
        return $null
    }

    $headers = @{
        'Authorization'     = "Bearer $token"
        'x-xai-token-auth'  = 'xai-grok-cli'
        'Accept'            = 'application/json'
        'User-Agent'        = 'grok-cli (ai-usage-overlay)'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' `
            -Headers $headers -Method GET -TimeoutSec $TimeoutSec
        Set-GrokAuthState 'ok' ''
        $parsed = ConvertFrom-GrokBillingResponse $resp
        $script:GrokUsage = $parsed
        return $parsed
    } catch {
        $message = $_.Exception.Message
        Write-GrokLog "Get-GrokLiveUsage: request failed - $message"
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401 -or $message -match '\b401\b') {
            Set-GrokAuthState 'auth' 'Grok login expired - run grok login'
        } else {
            Set-GrokAuthState 'stale' $message
        }
        return $null
    }
}
