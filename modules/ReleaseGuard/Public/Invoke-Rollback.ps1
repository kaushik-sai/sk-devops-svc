Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Rolls an environment back to its previous successfully deployed release.

.DESCRIPTION
    Reads the environment's deploy history (<history folder>/<env>.json). The latest
    entry is the release on the environment now (the bad one). The target is the
    newest earlier entry with status "deployed" that is a different release: another
    tag, or the same tag with another FAIL_RATE (so a bad FAIL_RATE on the current
    image rolls back to that image with FAIL_RATE 0, not to an older commit).

    Steps:
    1. If the latest entry was itself written by a rollback, the environment is
       already rolled back: report it and stop (success). This makes a second run
       a safe no-op.
    2. Check Docker is running.
    3. Redeploy the target tag with docker compose (-p sksvc-<env>, IMAGE_TAG=<tag>,
       FAIL_RATE=0).
    4. Poll /version until it returns the target tag, or time out.
    5. Mark the bad release "rolled_back" and append a "deployed" entry for the
       target tag with rolledBackFrom set to the bad tag.

    Terminating errors (each with its own error ID):
    - ReleaseGuard.NoPreviousRelease   no earlier successful deploy to go back to
    - ReleaseGuard.DockerNotRunning    "docker info" failed
    - ReleaseGuard.HealthCheckTimeout  /version did not show the target tag in time
    - ReleaseGuard.ComposeFailed       docker compose up returned an error
    History is only changed after the target tag is confirmed on /version.

.PARAMETER Environment
    dev or prod.

.PARAMETER ComposeFile
    Path to docker-compose.yml. Defaults to the one at the repo root.

.PARAMETER TimeoutSeconds
    How long to wait for /version to show the target tag. Default 60.

.EXAMPLE
    Invoke-Rollback -Environment prod

    Puts prod back on the previous release and records the rollback.

.EXAMPLE
    Invoke-Rollback -Environment prod -TimeoutSeconds 120 -Verbose

    Waits up to two minutes and shows each health poll.
#>
function Invoke-Rollback {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        [string] $ComposeFile = (Get-DefaultComposeFile),
        [ValidateRange(1, 3600)] [int] $TimeoutSeconds = 60
    )

    # Show progress by default; a caller can still hide it with -InformationAction Ignore.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
        $InformationPreference = 'Continue'
    }

    $entries = Read-DeployHistory -Environment $Environment
    if ($entries.Count -eq 0) {
        Write-Error -Message "No deploy history for '$Environment' ($(Get-DeployHistoryPath -Environment $Environment)), so there is no previous release to roll back to." `
            -ErrorId 'ReleaseGuard.NoPreviousRelease' -Category ObjectNotFound -ErrorAction Stop
    }

    # The latest entry is what was last put on the environment.
    $current = $entries[-1]

    # Idempotency: if the latest entry came from a rollback, there is nothing left to do.
    if ($current.status -eq 'deployed' -and $current.rolledBackFrom) {
        Write-Information "Already rolled back: $Environment is on $($current.tag) (rolled back from $($current.rolledBackFrom)). Nothing to do."
        return [pscustomobject] @{
            Environment = $Environment
            Action      = 'AlreadyRolledBack'
            FromTag     = $current.rolledBackFrom
            ToTag       = $current.tag
        }
    }

    # Target: newest earlier "deployed" entry that is a different release (rollback depth is one release).
    $currentFailRate = Get-EntryFailRate -Entry $current
    $target = $null
    for ($i = $entries.Count - 2; $i -ge 0; $i--) {
        if ($entries[$i].status -eq 'deployed' -and
            -not (Test-SameRelease -Entry $entries[$i] -Tag $current.tag -FailRate $currentFailRate)) {
            $target = $entries[$i]
            break
        }
    }
    if (-not $target) {
        Write-Error -Message "No previous successful release in '$Environment' history before $($current.tag)." `
            -ErrorId 'ReleaseGuard.NoPreviousRelease' -Category ObjectNotFound -ErrorAction Stop
    }

    if (-not (Test-DockerRunning)) {
        Write-Error -Message 'Docker is not running ("docker info" failed). Start Docker and try again.' `
            -ErrorId 'ReleaseGuard.DockerNotRunning' -Category ResourceUnavailable -ErrorAction Stop
    }

    Write-Information "Rolling back $Environment from $($current.tag) (FAIL_RATE=$currentFailRate) to $($target.tag) (FAIL_RATE=0)"
    # FAIL_RATE=0 on purpose: the "bad release" can be the same image with a high
    # FAIL_RATE, so a rollback must restore a known-good configuration too.
    Invoke-ComposeUp -Environment $Environment -ImageTag $target.tag -FailRate 0 -ComposeFile $ComposeFile

    # /version returns the commit SHA, which is also the image tag.
    $versionUrl = "$(Get-EnvironmentBaseUrl -Environment $Environment)/version"
    $healthy = Wait-EndpointValue -Url $versionUrl -Property 'version' -ExpectedValue $target.tag -TimeoutSeconds $TimeoutSeconds
    if (-not $healthy) {
        Write-Error -Message "$versionUrl did not report $($target.tag) within $TimeoutSeconds seconds. History not changed." `
            -ErrorId 'ReleaseGuard.HealthCheckTimeout' -Category OperationTimeout -ErrorAction Stop
    }

    # Record: the bad release is marked, then the rollback is appended as a new deploy.
    $current.status = 'rolled_back'
    Write-DeployHistory -Environment $Environment -Entries $entries
    Add-DeployHistoryEntry -Environment $Environment -Tag $target.tag -Status 'deployed' -RolledBackFrom $current.tag | Out-Null

    Write-Information "Rolled back $Environment to $($target.tag)."
    return [pscustomobject] @{
        Environment = $Environment
        Action      = 'RolledBack'
        FromTag     = $current.tag
        ToTag       = $target.tag
    }
}
