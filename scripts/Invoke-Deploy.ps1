<#
.SYNOPSIS
    Deploys one image tag of sk-svc to dev or prod and records it in the deploy history.

.DESCRIPTION
    1. Runs the database migrations (scripts/Invoke-Migrations.ps1) for the environment.
    2. Starts the environment's app with docker compose (-p sksvc-<env>, IMAGE_TAG=<tag>,
       FAIL_RATE=<rate>).
    3. Polls /healthz until it reports "ok" or the timeout passes.
    4. Appends a "deployed" entry (tag and FAIL_RATE) to the deploy history, unless the
       latest entry is already this tag with this FAIL_RATE as "deployed" (re-running the
       same deploy adds nothing; the same tag with another FAIL_RATE is a new release).
       If docker compose fails or the health check times out, a "failed" entry is
       appended instead, so Invoke-Rollback knows the release on the environment is bad.
    Exits 0 on success, 2 when it failed before the environment was changed (migrations),
    so there is nothing to roll back, and 1 on any other failure.

.PARAMETER Environment
    dev or prod.

.PARAMETER ImageTag
    The image tag to deploy: the full commit SHA (the image is sk-svc:<tag>).

.PARAMETER FailRate
    Probability (0 to 1) that GET /work returns 500. Default 0. Used to simulate a bad release.

.PARAMETER ComposeFile
    Path to docker-compose.yml. Defaults to the one at the repo root.

.PARAMETER TimeoutSeconds
    How long to wait for /healthz. Default 60.

.EXAMPLE
    pwsh ./scripts/Invoke-Deploy.ps1 -Environment dev -ImageTag (git rev-parse HEAD)

.EXAMPLE
    pwsh ./scripts/Invoke-Deploy.ps1 -Environment prod -ImageTag $sha -FailRate 0.5

    Deploys a deliberately "bad" release for the rollback drill.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
    [Parameter(Mandatory)] [string] $ImageTag,
    [ValidateRange(0, 1)] [double] $FailRate = 0,
    [string] $ComposeFile,
    [ValidateRange(1, 3600)] [int] $TimeoutSeconds = 60
)

Set-StrictMode -Version Latest

# Reuse the module's history and Docker helpers (one Docker wrapper for the whole repo).
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard', 'Private'
. (Join-Path -Path $privatePath -ChildPath 'History.ps1')
. (Join-Path -Path $privatePath -ChildPath 'Deployment.ps1')

# Runs the migrations script in a child pwsh process, so its exit code is clear
# and its "exit" cannot end this script. Tests mock this function.
function Invoke-MigrationScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        # The migrations script next to this one. A parameter so tests can point at a fake.
        [string] $ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Migrations.ps1')
    )

    # The same pwsh that runs this script, so it works without pwsh on PATH.
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -NonInteractive -File $ScriptPath -Environment $Environment
    if ($LASTEXITCODE -ne 0) {
        Write-Error -Message "Migrations failed for $Environment (exit code $LASTEXITCODE). Nothing was deployed." `
            -ErrorId 'ReleaseGuard.MigrationsFailed' -Category InvalidResult -ErrorAction Stop
    }
}

function Invoke-Deployment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        [Parameter(Mandatory)] [string] $ImageTag,
        [ValidateRange(0, 1)] [double] $FailRate = 0,
        [string] $ComposeFile = (Get-DefaultComposeFile),
        [int] $TimeoutSeconds = 60
    )

    # Migrations first: the new code may need the new schema. They must stay
    # backward compatible, because a rollback does not undo them.
    Write-Information "Running migrations for $Environment"
    Invoke-MigrationScript -Environment $Environment

    Write-Information "Deploying sk-svc:$ImageTag to $Environment (FAIL_RATE=$FailRate)"
    try {
        Invoke-ComposeUp -Environment $Environment -ImageTag $ImageTag -FailRate $FailRate -ComposeFile $ComposeFile
    } catch {
        # Compose may have stopped or replaced the old container before it failed.
        Add-DeployHistoryEntry -Environment $Environment -Tag $ImageTag -Status 'failed' -FailRate $FailRate | Out-Null
        throw
    }

    $healthUrl = "$(Get-EnvironmentBaseUrl -Environment $Environment)/healthz"
    $healthy = Wait-EndpointValue -Url $healthUrl -Property 'status' -ExpectedValue 'ok' -TimeoutSeconds $TimeoutSeconds
    if (-not $healthy) {
        # Record the failure so Invoke-Rollback knows what is on the environment now.
        Add-DeployHistoryEntry -Environment $Environment -Tag $ImageTag -Status 'failed' -FailRate $FailRate | Out-Null
        Write-Error -Message "$healthUrl was not healthy within $TimeoutSeconds seconds. Recorded as failed." `
            -ErrorId 'ReleaseGuard.HealthCheckTimeout' -Category OperationTimeout -ErrorAction Stop
    }

    # Only record a new entry when this release (tag and FAIL_RATE) is not already the latest
    # deployed one, so re-running the same deploy does not fill the history with duplicates.
    $entries = Read-DeployHistory -Environment $Environment
    $latest = if ($entries.Count -gt 0) { $entries[-1] } else { $null }
    $alreadyRecorded = $null -ne $latest -and $latest.status -eq 'deployed' -and (Test-SameRelease -Entry $latest -Tag $ImageTag -FailRate $FailRate)
    if ($alreadyRecorded) {
        Write-Information "$ImageTag (FAIL_RATE=$FailRate) is already the latest deployed release of $Environment; history unchanged."
    } else {
        Add-DeployHistoryEntry -Environment $Environment -Tag $ImageTag -Status 'deployed' -FailRate $FailRate | Out-Null
        Write-Information "Recorded $ImageTag (FAIL_RATE=$FailRate) as deployed to $Environment."
    }

    return [pscustomobject] @{
        Environment = $Environment
        ImageTag    = $ImageTag
        Recorded    = -not $alreadyRecorded
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    # Show progress messages from Write-Information.
    $InformationPreference = 'Continue'
    $deployArgs = @{
        Environment    = $Environment
        ImageTag       = $ImageTag
        FailRate       = $FailRate
        TimeoutSeconds = $TimeoutSeconds
    }
    if ($ComposeFile) {
        $deployArgs.ComposeFile = $ComposeFile
    }
    try {
        Invoke-Deployment @deployArgs | Out-Null
        exit 0
    } catch {
        Write-Error -Message "Deploy failed: $($_.Exception.Message)" -ErrorAction Continue
        # Exit 2: migrations failed, so the environment still runs the previous release.
        # The pipeline uses it to skip the automatic rollback.
        if ($_.FullyQualifiedErrorId -like 'ReleaseGuard.MigrationsFailed*') {
            exit 2
        }
        exit 1
    }
}
