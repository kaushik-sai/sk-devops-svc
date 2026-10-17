Set-StrictMode -Version Latest

# Deployment helpers shared by Invoke-Rollback (module) and scripts/Invoke-Deploy.ps1
# (which dot-sources this file). Invoke-DockerCommand is the ONLY place that runs
# docker, so tests mock that one function and never need a Docker daemon.

function Invoke-DockerCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)

    if (-not (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) {
        return [pscustomobject] @{ ExitCode = -1; Output = 'docker is not installed or not on PATH' }
    }
    # 2>&1 so Compose progress and error text are captured, not printed.
    $output = & docker @Arguments 2>&1
    [pscustomobject] @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

# "docker info" talks to the daemon, so it fails when Docker Desktop is not running.
function Test-DockerRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $result = Invoke-DockerCommand -Arguments @('info')
    return $result.ExitCode -eq 0
}

# Host URL of each environment (ports from docker-compose.yml, bound to 127.0.0.1).
function Get-EnvironmentBaseUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment)
    $ports = @{ dev = 7311; prod = 7312 }
    return "http://127.0.0.1:$($ports[$Environment])"
}

# docker-compose.yml at the repo root, found from this file's location
# (modules/ReleaseGuard/Private), not from the current folder.
function Get-DefaultComposeFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', 'docker-compose.yml'
}

# Starts (or replaces) the app container of one environment with the given image tag.
function Invoke-ComposeUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        [Parameter(Mandatory)] [string] $ImageTag,
        [ValidateRange(0, 1)] [double] $FailRate = 0,
        [string] $ComposeFile = (Get-DefaultComposeFile)
    )

    # -p keeps dev and prod in separate Compose projects; --profile and the service
    # name start only this environment's app. --no-build: the image must already exist.
    $arguments = @(
        'compose', '-f', $ComposeFile, '-p', "sksvc-$Environment", '--profile', $Environment,
        'up', '-d', '--no-build', "app-$Environment"
    )

    # Compose reads IMAGE_TAG and FAIL_RATE from the process environment.
    # Save the old values and put them back afterwards so nothing leaks into later steps.
    $oldImageTag = $env:IMAGE_TAG
    $oldFailRate = $env:FAIL_RATE
    try {
        $env:IMAGE_TAG = $ImageTag
        # Invariant culture so 0.5 is never written as "0,5" on other locales.
        $env:FAIL_RATE = $FailRate.ToString([cultureinfo]::InvariantCulture)
        $result = Invoke-DockerCommand -Arguments $arguments
    } finally {
        # Assigning $null removes the variable, which restores "not set".
        $env:IMAGE_TAG = $oldImageTag
        $env:FAIL_RATE = $oldFailRate
    }

    if ($result.ExitCode -ne 0) {
        Write-Error -Message "docker compose up failed for $Environment ($ImageTag): $($result.Output)" `
            -ErrorId 'ReleaseGuard.ComposeFailed' -Category InvalidResult -ErrorAction Stop
    }
}

# Polls a JSON endpoint until <Property> equals <ExpectedValue>, for up to TimeoutSeconds.
# Returns $true when it matched, $false on timeout. The caller decides what a timeout means.
function Wait-EndpointValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Property,
        [Parameter(Mandatory)] [string] $ExpectedValue,
        [int] $TimeoutSeconds = 60,
        [int] $IntervalSeconds = 2
    )
    # Two limits: a number of attempts (simple and testable with a mocked Start-Sleep) and a
    # deadline, so slow responses cannot stretch the wait far past TimeoutSeconds.
    $attempts = [math]::Max(1, [math]::Ceiling($TimeoutSeconds / $IntervalSeconds))
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $attempts; $i++) {
        # Each request may use at most the time that is left (5 s at most, 1 s at least).
        $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
        $requestTimeout = [int] [math]::Max(1, [math]::Min(5, [math]::Floor($remaining)))
        try {
            $response = Invoke-RestMethod -Uri $Url -TimeoutSec $requestTimeout
            if ("$($response.$Property)" -eq $ExpectedValue) {
                return $true
            }
            Write-Verbose "Attempt $i/$($attempts): $Property is '$($response.$Property)', waiting for '$ExpectedValue'"
        } catch {
            # Not up yet (connection refused, 5xx, not JSON): keep waiting.
            Write-Verbose "Attempt $i/$($attempts): $($_.Exception.Message)"
        }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            break
        }
        if ($i -lt $attempts) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    return $false
}
