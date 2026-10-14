<#
.SYNOPSIS
    Prepares the agent machine: one shared folder for deploy history and the database password,
    usable by both you and the agent's service account.

.DESCRIPTION
    The pipeline agent runs as its own local account (for example svc-azagent) and checks the
    code out fresh for every run, so it cannot use files in your profile or in your clone.
    This script, run once as yourself (safe to run again):
      1. Creates <Root>, <Root>\history and <Root>\secrets.
      2. Moves in what already exists, without overwriting: the repo's .secrets/db_password and
         your ~/.releaseguard/history files, so the running Postgres keeps its password.
      3. Sets permissions: the agent account may modify <Root>; <Root>\secrets is limited to
         SYSTEM, Administrators, you and the agent account. The agent account may read and run
         the tools folder and the Docker Desktop CLI.
      4. Writes the agent's .env (RELEASEGUARD_HOME, SKSVC_DB_PASSWORD_FILE) and .path (your full
         PATH) so pipeline jobs find the shared folder, pwsh, docker, terraform and the rest.
      5. Sets the same two variables for your own account, so your terminal and the pipeline
         share one history and one password.
    Restart the agent service afterwards so it reads .env and .path.

    In production the password would come from a vault (Azure Key Vault); see DESIGN.md.

.PARAMETER Root
    The shared folder. Default C:\svc-app.

.PARAMETER AgentAccount
    The local account the agent service runs as. Default svc-azagent.

.PARAMETER AgentDirectory
    Where the agent is installed. Default C:\agent.

.PARAMETER ToolDirectories
    Folders the agent account must be able to read and run (tools, Docker CLI).

.EXAMPLE
    pwsh ./scripts/Initialize-AgentHost.ps1 -WhatIf

.EXAMPLE
    pwsh ./scripts/Initialize-AgentHost.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Root = 'C:\svc-app',
    [string] $AgentAccount = 'svc-azagent',
    [string] $AgentDirectory = 'C:\agent',
    [string[]] $ToolDirectories = @(
        (Join-Path -Path $HOME -ChildPath 'kaushik' -AdditionalChildPath 'softwares'),
        (Join-Path -Path $HOME -ChildPath 'AppData' -AdditionalChildPath 'Local', 'Programs', 'DockerDesktop')
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent

# The one place that runs icacls (Windows permissions). Tests mock this function.
function Invoke-AclCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $output = & icacls @Arguments 2>&1
    [pscustomobject] @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
}

# Sets an environment variable for the current user (persistent). Tests mock this function.
function Set-UserVariable {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )
    if ($PSCmdlet.ShouldProcess("user variable $Name", "Set to $Value")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
}

# Returns the paths every other step uses, in one place.
function Get-HostLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)
    [pscustomobject] @{
        Root       = $Root
        History    = Join-Path -Path $Root -ChildPath 'history'
        Secrets    = Join-Path -Path $Root -ChildPath 'secrets'
        SecretFile = Join-Path -Path $Root -ChildPath 'secrets' -AdditionalChildPath 'db_password'
    }
}

function New-HostFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [pscustomobject] $Layout)
    foreach ($folder in @($Layout.Root, $Layout.History, $Layout.Secrets)) {
        if (-not (Test-Path -LiteralPath $folder) -and $PSCmdlet.ShouldProcess($folder, 'Create folder')) {
            New-Item -ItemType Directory -Path $folder | Out-Null
            Write-Information "Created $folder"
        }
    }
}

# Copies the existing password and history into the shared folder. Never overwrites:
# the running Postgres was created with the existing password, so it must be kept.
function Copy-ExistingState {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Layout,
        [Parameter(Mandatory)] [string] $OldSecretFile,
        [Parameter(Mandatory)] [string] $OldHistory
    )
    if ((Test-Path -LiteralPath $OldSecretFile) -and -not (Test-Path -LiteralPath $Layout.SecretFile)) {
        if ($PSCmdlet.ShouldProcess($Layout.SecretFile, 'Copy existing database password')) {
            Copy-Item -LiteralPath $OldSecretFile -Destination $Layout.SecretFile
            Write-Information "Copied the existing database password to $($Layout.SecretFile)"
        }
    }
    if (Test-Path -LiteralPath $OldHistory) {
        foreach ($file in Get-ChildItem -LiteralPath $OldHistory -Filter '*.json' -File) {
            $target = Join-Path -Path $Layout.History -ChildPath $file.Name
            if (-not (Test-Path -LiteralPath $target) -and $PSCmdlet.ShouldProcess($target, 'Copy deploy history')) {
                Copy-Item -LiteralPath $file.FullName -Destination $target
                Write-Information "Copied deploy history $($file.Name)"
            }
        }
    }
}

# Grants permissions. Returns the number of icacls calls that failed.
function Set-HostPermission {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Layout,
        [Parameter(Mandatory)] [string] $AgentAccount,
        [Parameter(Mandatory)] [string] $CurrentUser,
        [string[]] $ToolDirectories = @()
    )
    # (OI)(CI) = applies to files and subfolders. M = modify, RX = read and run, F = full.
    $grants = @(
        @{ Target = $Layout.Root; Arguments = @($Layout.Root, '/grant', "${AgentAccount}:(OI)(CI)M") }
        # Secrets: stop inheriting the wide default permissions and allow only these four.
        @{ Target = $Layout.Secrets; Arguments = @($Layout.Secrets, '/inheritance:r', '/grant:r',
                'SYSTEM:(OI)(CI)F', 'Administrators:(OI)(CI)F', "${CurrentUser}:(OI)(CI)M", "${AgentAccount}:(OI)(CI)M") }
    )
    foreach ($tool in $ToolDirectories) {
        if (Test-Path -LiteralPath $tool) {
            $grants += @{ Target = $tool; Arguments = @($tool, '/grant', "${AgentAccount}:(OI)(CI)RX") }
        } else {
            Write-Warning "Tool folder not found, skipped: $tool"
        }
    }

    $failures = 0
    foreach ($grant in $grants) {
        if ($PSCmdlet.ShouldProcess($grant.Target, "icacls $($grant.Arguments[1..($grant.Arguments.Count - 1)] -join ' ')")) {
            $result = Invoke-AclCommand -Arguments $grant.Arguments
            if ($result.ExitCode -ne 0) {
                Write-Warning "Permissions on $($grant.Target) failed: $($result.Output)"
                $failures++
            }
        }
    }
    return $failures
}

# Writes KEY=value lines into the agent's .env, replacing those keys and keeping any other lines.
function Set-AgentEnvironmentFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Values
    )
    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        # Keep lines for other variables; ours are written fresh below.
        $lines = @(Get-Content -LiteralPath $Path | Where-Object {
                $key = ($_ -split '=', 2)[0]
                -not $Values.ContainsKey($key)
            })
    }
    foreach ($key in ($Values.Keys | Sort-Object)) {
        $lines += "$key=$($Values[$key])"
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write agent environment')) {
        Set-Content -LiteralPath $Path -Value $lines
        Write-Information "Wrote $Path"
    }
}

function Set-AgentPathFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Value
    )
    if ($PSCmdlet.ShouldProcess($Path, 'Write agent PATH')) {
        # The agent uses this file, one line, as PATH for every job.
        Set-Content -LiteralPath $Path -Value $Value -NoNewline
        Write-Information "Wrote $Path"
    }
}

function Initialize-AgentHost {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $AgentAccount,
        [Parameter(Mandatory)] [string] $AgentDirectory,
        [string[]] $ToolDirectories = @()
    )
    $layout = Get-HostLayout -Root $Root
    New-HostFolder -Layout $layout
    Copy-ExistingState -Layout $layout `
        -OldSecretFile (Join-Path -Path $script:RepoRoot -ChildPath '.secrets' -AdditionalChildPath 'db_password') `
        -OldHistory (Join-Path -Path $HOME -ChildPath '.releaseguard' -AdditionalChildPath 'history')

    $failures = Set-HostPermission -Layout $layout -AgentAccount $AgentAccount `
        -CurrentUser ([Environment]::UserName) -ToolDirectories $ToolDirectories

    $variables = @{ RELEASEGUARD_HOME = $layout.Root; SKSVC_DB_PASSWORD_FILE = $layout.SecretFile }
    if (Test-Path -LiteralPath $AgentDirectory) {
        Set-AgentEnvironmentFile -Path (Join-Path -Path $AgentDirectory -ChildPath '.env') -Values $variables
        # Machine PATH plus your user PATH: where pwsh 7, docker, terraform, trivy and promtool are.
        $path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        Set-AgentPathFile -Path (Join-Path -Path $AgentDirectory -ChildPath '.path') -Value $path
    } else {
        Write-Warning "Agent folder not found, skipped .env and .path: $AgentDirectory"
        $failures++
    }
    foreach ($name in $variables.Keys) {
        Set-UserVariable -Name $name -Value $variables[$name]
    }
    return $failures
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $InformationPreference = 'Continue'
    if (-not $IsWindows) {
        Write-Error 'Initialize-AgentHost.ps1 configures the Windows agent machine and runs on Windows only.' -ErrorAction Continue
        exit 1
    }
    $failed = Initialize-AgentHost -Root $Root -AgentAccount $AgentAccount -AgentDirectory $AgentDirectory -ToolDirectories $ToolDirectories
    if ($failed -gt 0) {
        Write-Error "$failed step(s) failed; see the warnings above." -ErrorAction Continue
        exit 1
    }
    Write-Output "Done. Restart the agent service so it reads $AgentDirectory\.env and .path, and open a new terminal for the new variables."
    exit 0
}
