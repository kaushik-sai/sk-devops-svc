<#
.SYNOPSIS
    Brings the whole local stack up with one command: database, dev, prod and monitoring.

.DESCRIPTION
    1. Checks that Docker is running.
    2. Creates the shared Docker network sksvc-net if it is missing.
    3. Generates a random database password in .secrets/db_password if it is missing (git-ignored).
    4. Builds the image sk-svc:<full commit SHA> from the current commit.
    5. Starts Postgres (project sksvc-data) and waits until it is healthy.
    6. Deploys dev and prod with scripts/Invoke-Deploy.ps1 (migrations, start, health wait, deploy history).
    7. Starts Prometheus, Alertmanager and Grafana (project sksvc-mon).
    Safe to run again: existing network, password and containers are reused.

.PARAMETER SkipMonitoring
    Do not start the monitoring project.

.EXAMPLE
    pwsh ./scripts/Start-Stack.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipMonitoring
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$script:ComposeFile = Join-Path -Path $script:RepoRoot -ChildPath 'docker-compose.yml'
$script:NetworkName = 'sksvc-net'

# The one place that runs docker (and git). Tests mock this function.
# Returns the output lines; throws if the command fails.
function Invoke-StackCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string[]] $Arguments = @()
    )
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed (exit $LASTEXITCODE): $($output | Out-String)"
    }
    return $output
}

# Deploys one environment. A separate function so tests can mock the call to Invoke-Deploy.ps1.
function Invoke-EnvironmentDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $ImageTag
    )
    $deployScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Deploy.ps1'
    & $deployScript -Environment $Environment -ImageTag $ImageTag
    if ($LASTEXITCODE -ne 0) {
        throw "Deploy of $Environment failed (exit $LASTEXITCODE)."
    }
}

function Assert-DockerRunning {
    [CmdletBinding()]
    param()
    try {
        Invoke-StackCommand -Command 'docker' -Arguments @('info', '--format', '{{.ServerVersion}}') | Out-Null
    } catch {
        throw 'Docker is not running. Start Docker Desktop and try again.'
    }
}

function New-StackNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name)

    $existing = Invoke-StackCommand -Command 'docker' -Arguments @('network', 'ls', '--filter', "name=^$Name$", '--format', '{{.Name}}')
    if ($existing -contains $Name) {
        Write-Information "Network $Name already exists."
        return
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create Docker network')) {
        Invoke-StackCommand -Command 'docker' -Arguments @('network', 'create', $Name) | Out-Null
        Write-Information "Created network $Name."
    }
}

<#
.SYNOPSIS
    Returns a random password made of letters and digits, from a cryptographic random source.
#>
function New-RandomSecret {
    # Only returns a string; nothing outside the process changes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(24, 128)] [int] $Length = 32)

    # Letters and digits only, so the value is safe in any config file or shell.
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $chars = for ($i = 0; $i -lt $Length; $i++) {
        # GetInt32 is uniform (no modulo bias) and cryptographically secure.
        $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]
    }
    return -join $chars
}

function Initialize-SecretFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Information 'Database password already exists; keeping it.'
        return $Path
    }
    $folder = Split-Path -Path $Path -Parent
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    # -NoNewline: the password is exactly the file content, with no trailing newline.
    Set-Content -LiteralPath $Path -Value (New-RandomSecret) -NoNewline
    Write-Information "Generated a random database password in $Path (git-ignored)."
    return $Path
}

function Get-CommitSha {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $RepoPath)
    $sha = Invoke-StackCommand -Command 'git' -Arguments @('-C', $RepoPath, 'rev-parse', 'HEAD')
    $sha = ([string] $sha).Trim()
    if ($sha -notmatch '^[0-9a-f]{40}$') {
        throw "Could not read the full commit SHA (got '$sha')."
    }
    return $sha
}

function Build-ServiceImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [string] $RepoPath
    )
    $tag = "sk-svc:$Sha"
    Write-Information "Building $tag ..."
    Invoke-StackCommand -Command 'docker' -Arguments @('build', '--build-arg', "GIT_SHA=$Sha", '-t', $tag, $RepoPath) | Out-Null
    return $tag
}

function Wait-ContainerHealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContainerName,
        [int] $TimeoutSeconds = 90,
        [int] $IntervalSeconds = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = Invoke-StackCommand -Command 'docker' -Arguments @('inspect', '--format', '{{.State.Health.Status}}', $ContainerName)
        if (([string] $status).Trim() -eq 'healthy') {
            return
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw "$ContainerName did not become healthy within $TimeoutSeconds seconds."
}

function Start-ComposeProject {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Project,
        [Parameter(Mandatory)] [string] $ProfileName
    )
    if ($PSCmdlet.ShouldProcess($Project, 'docker compose up')) {
        Invoke-StackCommand -Command 'docker' -Arguments @(
            'compose', '-f', $script:ComposeFile, '-p', $Project, '--profile', $ProfileName, 'up', '-d'
        ) | Out-Null
    }
}

function Start-Stack {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch] $SkipMonitoring)

    Assert-DockerRunning
    New-StackNetwork -Name $script:NetworkName
    Initialize-SecretFile -Path (Join-Path -Path $script:RepoRoot -ChildPath '.secrets' -AdditionalChildPath 'db_password') | Out-Null

    $sha = Get-CommitSha -RepoPath $script:RepoRoot
    $tag = Build-ServiceImage -Sha $sha -RepoPath $script:RepoRoot

    # Database first: migrations in the deploy step need it.
    Start-ComposeProject -Project 'sksvc-data' -ProfileName 'data'
    Wait-ContainerHealthy -ContainerName 'sksvc-db'

    foreach ($environment in @('dev', 'prod')) {
        Invoke-EnvironmentDeploy -Environment $environment -ImageTag $sha
    }

    if (-not $SkipMonitoring) {
        Start-ComposeProject -Project 'sksvc-mon' -ProfileName 'monitoring'
    }

    Write-Output "Stack is up with image $tag"
    Write-Output '  dev:          http://127.0.0.1:7311/version'
    Write-Output '  prod:         http://127.0.0.1:7312/version'
    if (-not $SkipMonitoring) {
        Write-Output '  Prometheus:   http://127.0.0.1:7390'
        Write-Output '  Grafana:      http://127.0.0.1:7391'
        Write-Output '  Alertmanager: http://127.0.0.1:7393'
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    # Show progress messages (Write-Information) when run as a script.
    $InformationPreference = 'Continue'
    try {
        Start-Stack -SkipMonitoring:$SkipMonitoring
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
