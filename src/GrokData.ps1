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

function Get-GrokAccessToken {
    param($Auth)

    if (-not $Auth) { return $null }
    if ($Auth.tokens -and $Auth.tokens.access_token) { return [string]$Auth.tokens.access_token }
    if ($Auth.access_token) { return [string]$Auth.access_token }
    return $null
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

    $amount = $null
    foreach ($name in @('amount', 'balance', 'credits', 'remaining', 'value')) {
        $prop = $Value.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $amount = $prop.Value
            break
        }
    }
    if ($null -eq $amount) { return $null }
    try { return ('{0:N2}' -f [double]$amount) } catch { return [string]$amount }
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

    return @{
        WeekPct         = $weekPct
        WeekResetsAt    = $weekResetsAt
        PrepaidBalance  = Convert-GrokPrepaidText $obj.prepaidBalance
        ProductUsage    = $obj.productUsage
        PlanType        = Convert-GrokPlanType $obj
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
