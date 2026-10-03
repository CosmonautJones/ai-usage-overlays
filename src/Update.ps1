# Update.ps1 - master-branch update checks and installer handoff.
# The latest commit on master is the latest release. The installer for that
# commit is published by the Release Installer workflow.

$script:UpdateAssetName = 'AIUsageOverlaySetup.exe'
$script:UpdateApiBase = 'https://api.github.com'
$script:UpdateAutoCheckIntervalHours = 24
$script:UpdateState = [ordered]@{
    CheckedAt      = $null
    Status         = 'unknown'
    Message        = 'Updates have not been checked yet.'
    CurrentVersion = $script:AppVersion
    LatestVersion  = $null
    DownloadUrl    = $null
    WebUrl         = $null
}

function Get-AppUpdateVersionKey {
    param($Info)

    if (-not $Info) { return $null }

    $latest = $Info.LatestVersion
    if ($latest) { return [string]$latest }

    return $null
}

function Test-AppUpdateAutoCheckDue {
    param(
        [bool]$Enabled = $true,
        $LastCheckedAt = $script:UpdateState.CheckedAt,
        [datetime]$Now = (Get-Date),
        [int]$IntervalHours = $script:UpdateAutoCheckIntervalHours
    )

    if (-not $Enabled) { return $false }
    if (-not $LastCheckedAt) { return $true }

    try {
        $last = [datetime]$LastCheckedAt
        return (($Now - $last).TotalHours -ge $IntervalHours)
    } catch {
        return $true
    }
}

function Test-AppUpdateNotificationDue {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [string]$LastNotifiedVersion
    )

    if (-not $Info -or $Info.Status -ne 'available') { return $false }

    $versionKey = Get-AppUpdateVersionKey $Info
    if (-not $versionKey) { return $false }

    return ($versionKey -ne $LastNotifiedVersion)
}

function ConvertTo-AppVersion {
    param([string]$Value)

    if (-not $Value) { return $null }
    $clean = $Value.Trim()
    if ($clean.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = $clean.Substring(1)
    }
    $match = [regex]::Match($clean, '\d+(?:\.\d+){0,3}')
    if (-not $match.Success) { return $null }

    try { return [version]$match.Value } catch { return $null }
}

function Test-AppVersionGreater {
    param(
        [Parameter(Mandatory = $true)][string]$LatestVersion,
        [Parameter(Mandatory = $true)][string]$CurrentVersion
    )

    $latest = ConvertTo-AppVersion $LatestVersion
    $current = ConvertTo-AppVersion $CurrentVersion
    if ($latest -and $current) { return $latest -gt $current }

    return ($LatestVersion -ne $CurrentVersion)
}

function New-AppUpdateInfo {
    param(
        [string]$Status,
        [string]$Message,
        [string]$CurrentVersion = $script:AppVersion,
        [string]$LatestVersion,
        [string]$DownloadUrl,
        [string]$WebUrl
    )

    [pscustomobject]@{
        Status         = $Status
        Message        = $Message
        CurrentVersion = $CurrentVersion
        LatestVersion  = $LatestVersion
        DownloadUrl    = $DownloadUrl
        WebUrl         = $WebUrl
        CheckedAt      = Get-Date
    }
}

function Convert-GitHubReleaseToAppUpdateInfo {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [string]$CurrentVersion = $script:AppVersion
    )

    $latestVersion = [string]$Release.tag_name
    $asset = Get-UpdateSetupAsset $Release

    if (-not (Test-AppVersionGreater -LatestVersion $latestVersion -CurrentVersion $CurrentVersion)) {
        return New-AppUpdateInfo -Status 'current' -Message "AI Usage Overlay is up to date ($CurrentVersion)." -CurrentVersion $CurrentVersion -LatestVersion $latestVersion -WebUrl $Release.html_url
    }

    if (-not $asset) {
        return New-AppUpdateInfo -Status 'missing-asset' -Message "Version $latestVersion is available, but it does not include $script:UpdateAssetName." -CurrentVersion $CurrentVersion -LatestVersion $latestVersion -WebUrl $Release.html_url
    }

    return New-AppUpdateInfo -Status 'available' -Message "AI Usage Overlay $latestVersion is available." -CurrentVersion $CurrentVersion -LatestVersion $latestVersion -DownloadUrl $asset.browser_download_url -WebUrl $Release.html_url
}

function Get-InstalledAppRevision {
    param([string]$AppDir = $script:AppDir)

    if (-not $AppDir) { return '' }
    $path = Join-Path $AppDir 'app-revision.txt'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try { return (Get-Content -LiteralPath $path -Raw).Trim() } catch { return '' }
}

function Get-UpdateSetupAsset {
    param($Release)

    if (-not $Release) { return $null }
    return @($Release.assets) |
        Where-Object { $_.name -eq $script:UpdateAssetName } |
        Select-Object -First 1
}

function Get-ReleaseRevision {
    param($Release)

    if (-not $Release) { return $null }

    $body = [string]$Release.body
    $match = [regex]::Match($body, '(?m)^Revision:\s*([0-9a-fA-F]{40})\s*$')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }

    $target = [string]$Release.target_commitish
    if ($target -match '^[0-9a-fA-F]{40}$') { return $target.ToLowerInvariant() }

    return $null
}

function Resolve-AppUpdateFromMaster {
    param(
        [Parameter(Mandatory = $true)][string]$MasterSha,
        [Parameter(Mandatory = $true)][string]$InstalledRevision,
        $Release,
        [string]$CurrentVersion = $script:AppVersion
    )

    $master = $MasterSha.Trim().ToLowerInvariant()
    $installed = $InstalledRevision.Trim().ToLowerInvariant()
    $tag = if ($Release) { [string]$Release.tag_name } else { $null }
    $web = if ($Release) { [string]$Release.html_url } else { $null }

    if ($master -and $installed -eq $master) {
        return New-AppUpdateInfo -Status 'current' -Message "AI Usage Overlay is up to date ($CurrentVersion)." -CurrentVersion $CurrentVersion -LatestVersion $(if ($tag) { $tag } else { $CurrentVersion }) -WebUrl $web
    }

    $releaseSha = Get-ReleaseRevision $Release
    $asset = Get-UpdateSetupAsset $Release
    if ($releaseSha -and $master -and $releaseSha -eq $master -and $asset) {
        $short = $master.Substring(0, [Math]::Min(7, $master.Length))
        return New-AppUpdateInfo -Status 'available' -Message "A newer master build is available ($short)." -CurrentVersion $CurrentVersion -LatestVersion $tag -DownloadUrl $asset.browser_download_url -WebUrl $web
    }

    return New-AppUpdateInfo -Status 'pending' -Message 'Master has newer approved work. The installer for that commit is not published yet.' -CurrentVersion $CurrentVersion -LatestVersion $tag -WebUrl $web
}

function Get-GitHubMasterCommit {
    param(
        [string]$Owner = $script:RepoOwner,
        [string]$Repo = $script:RepoName,
        [int]$TimeoutSec = 8
    )

    $uri = "$script:UpdateApiBase/repos/$Owner/$Repo/commits/master"
    $headers = @{
        'User-Agent' = "AIUsageOverlay/$script:AppVersion"
        'Accept'     = 'application/vnd.github+json'
    }

    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }
        if ($statusCode -eq 404) { return $null }
        throw
    }
}

function Get-GitHubLatestRelease {
    param(
        [string]$Owner = $script:RepoOwner,
        [string]$Repo = $script:RepoName,
        [int]$TimeoutSec = 8
    )

    $uri = "$script:UpdateApiBase/repos/$Owner/$Repo/releases/latest"
    $headers = @{
        'User-Agent' = "AIUsageOverlay/$script:AppVersion"
        'Accept'     = 'application/vnd.github+json'
    }

    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }
        if ($statusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Test-AppUpdateAvailable {
    param(
        [string]$Owner = $script:RepoOwner,
        [string]$Repo = $script:RepoName,
        [string]$CurrentVersion = $script:AppVersion,
        [string]$InstalledRevision,
        [int]$TimeoutSec = 8
    )

    if (-not $PSBoundParameters.ContainsKey('InstalledRevision')) {
        $InstalledRevision = Get-InstalledAppRevision
    }

    try {
        $trackMaster = ($script:UpdateChannel -eq 'master' -and $InstalledRevision)
        if ($trackMaster) {
            $master = Get-GitHubMasterCommit -Owner $Owner -Repo $Repo -TimeoutSec $TimeoutSec
            if (-not $master -or -not $master.sha) {
                return New-AppUpdateInfo -Status 'error' -Message 'Update check failed: master commit is unavailable.' -CurrentVersion $CurrentVersion
            }
            $release = Get-GitHubLatestRelease -Owner $Owner -Repo $Repo -TimeoutSec $TimeoutSec
            return Resolve-AppUpdateFromMaster -MasterSha $master.sha -InstalledRevision $InstalledRevision -Release $release -CurrentVersion $CurrentVersion
        }

        $release = Get-GitHubLatestRelease -Owner $Owner -Repo $Repo -TimeoutSec $TimeoutSec
        if (-not $release) {
            return New-AppUpdateInfo -Status 'no-release' -Message 'No GitHub release is published yet.' -CurrentVersion $CurrentVersion
        }
        return Convert-GitHubReleaseToAppUpdateInfo -Release $release -CurrentVersion $CurrentVersion
    } catch {
        return New-AppUpdateInfo -Status 'error' -Message "Update check failed: $($_.Exception.Message)" -CurrentVersion $CurrentVersion
    }
}

function Set-AppUpdateState {
    param([Parameter(Mandatory = $true)]$Info)

    $script:UpdateState.CheckedAt = $Info.CheckedAt
    $script:UpdateState.Status = $Info.Status
    $script:UpdateState.Message = $Info.Message
    $script:UpdateState.CurrentVersion = $Info.CurrentVersion
    $script:UpdateState.LatestVersion = $Info.LatestVersion
    $script:UpdateState.DownloadUrl = $Info.DownloadUrl
    $script:UpdateState.WebUrl = $Info.WebUrl
}

function Save-DownloadedUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [int]$TimeoutSec = 60
    )

    $dir = Join-Path $env:TEMP ('AIUsageOverlayUpdate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $target = Join-Path $dir $script:UpdateAssetName
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $target -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    return $target
}

function Install-AppUpdate {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [switch]$Wait
    )

    if ($Info.Status -ne 'available' -or -not $Info.DownloadUrl) {
        return New-AppUpdateInfo -Status 'error' -Message 'No installable update is available.' -CurrentVersion $script:AppVersion -LatestVersion $Info.LatestVersion -WebUrl $Info.WebUrl
    }

    try {
        $setupPath = Save-DownloadedUpdate -DownloadUrl $Info.DownloadUrl
        $args = @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        $process = Start-Process -FilePath $setupPath -ArgumentList $args -PassThru -Wait:$Wait
        return New-AppUpdateInfo -Status 'installing' -Message "Installing AI Usage Overlay $($Info.LatestVersion). The overlay will restart when setup finishes." -CurrentVersion $script:AppVersion -LatestVersion $Info.LatestVersion -DownloadUrl $Info.DownloadUrl -WebUrl $Info.WebUrl
    } catch {
        return New-AppUpdateInfo -Status 'error' -Message "Update install failed: $($_.Exception.Message)" -CurrentVersion $script:AppVersion -LatestVersion $Info.LatestVersion -DownloadUrl $Info.DownloadUrl -WebUrl $Info.WebUrl
    }
}
