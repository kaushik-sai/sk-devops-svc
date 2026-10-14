<#
.SYNOPSIS
    Tears the whole local stack down with one command.

.DESCRIPTION
    Stops and removes the four Compose projects (sksvc-dev, sksvc-prod, sksvc-data, sksvc-mon)
    and the shared network sksvc-net.
    With -Purge it also deletes the volumes (the database data) and the deploy history folder,
    so the next Start-Stack begins from a clean state. The database password file is kept.

.PARAMETER Purge
    Also delete volumes and the deploy history.

.EXAMPLE
    pwsh ./scripts/Stop-Stack.ps1

.EXAMPLE
    pwsh ./scripts/Stop-Stack.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch] $Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$script:ComposeFile = Join-Path -Path $script:RepoRoot -ChildPath 'docker-compose.yml'
$script:NetworkName = 'sksvc-net'

# Project name -> Compose profile. The order matters: apps and monitoring before the database
# and the network they use.
$script:Projects = [ordered] @{
    'sksvc-mon'  = 'monitoring'
    'sksvc-prod' = 'prod'
    'sksvc-dev'  = 'dev'
    'sksvc-data' = 'data'
}

# The one place that runs docker. Tests mock this function.
# Returns ExitCode and Output instead of throwing: tear-down keeps going even if one step fails.
function Invoke-StackCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string[]] $Arguments = @()
    )
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Warning "'$Command $($Arguments -join ' ')' exited $exitCode`: $($output | Out-String)"
    }
    return [pscustomobject] @{ ExitCode = $exitCode; Output = @($output) }
}

# ReleaseGuard's history helpers: the one definition of where deploy history lives.
. (Join-Path -Path $script:RepoRoot -ChildPath 'modules' -AdditionalChildPath 'ReleaseGuard', 'Private', 'History.ps1')

# The folder that holds <env>.json for every environment.
function Get-HistoryFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Split-Path -Path (Get-DeployHistoryPath -Environment 'dev') -Parent
}

function Stop-Stack {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([switch] $Purge)

    $failures = 0

    foreach ($project in $script:Projects.Keys) {
        $arguments = @('compose', '-f', $script:ComposeFile, '-p', $project, '--profile', $script:Projects[$project], 'down', '--remove-orphans')
        if ($Purge) {
            # -v removes the project's named volumes, for example the Postgres data.
            $arguments += '-v'
        }
        if ($PSCmdlet.ShouldProcess($project, 'docker compose down')) {
            if ((Invoke-StackCommand -Command 'docker' -Arguments $arguments).ExitCode -ne 0) {
                $failures++
            }
        }
    }

    # Remove the network only if it exists, so a second run is quiet and still succeeds.
    if ($PSCmdlet.ShouldProcess($script:NetworkName, 'Remove Docker network')) {
        # "network ls" with a filter prints the name only if it exists, and does not fail when it is missing.
        $list = Invoke-StackCommand -Command 'docker' -Arguments @('network', 'ls', '--filter', "name=^$($script:NetworkName)$", '--format', '{{.Name}}')
        $exists = $list.Output -contains $script:NetworkName
        if ($exists -and (Invoke-StackCommand -Command 'docker' -Arguments @('network', 'rm', $script:NetworkName)).ExitCode -ne 0) {
            $failures++
        }
    }

    if ($Purge) {
        $historyFolder = Get-HistoryFolder
        if ((Test-Path -LiteralPath $historyFolder) -and $PSCmdlet.ShouldProcess($historyFolder, 'Delete deploy history')) {
            Remove-Item -LiteralPath $historyFolder -Recurse -Force
            Write-Information "Deleted deploy history in $historyFolder."
        }
    }

    return $failures
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    # Show progress messages (Write-Information) when run as a script.
    $InformationPreference = 'Continue'
    $failed = Stop-Stack -Purge:$Purge
    if ($failed -gt 0) {
        Write-Error "$failed tear-down step(s) failed; see the warnings above." -ErrorAction Continue
        exit 1
    }
    Write-Output 'Stack is down.'
    exit 0
}
