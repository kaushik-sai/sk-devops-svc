<#
.SYNOPSIS
    Deletes old sk-svc images from the agent, keeping every image a rollback could need.

.DESCRIPTION
    Images stay local on the agent (no registry), and every merge to main builds a new
    sk-svc:<sha> of about 330 MB, so without cleanup the agent's disk slowly fills up.

    Kept:
      - the last -Keep distinct tags with a "deployed" entry in each environment (dev and prod),
        read from the ReleaseGuard deploy history. -Keep is at least 2, so the current release
        and the one Invoke-Rollback would go back to are always kept;
      - any image a container (running or stopped) was created from.
    Everything else named sk-svc is removed. Use -WhatIf to see the list without deleting.

.PARAMETER Keep
    How many recent distinct deployed tags to keep per environment. Default 3, minimum 2.

.EXAMPLE
    pwsh ./scripts/Remove-OldImages.ps1 -WhatIf

.EXAMPLE
    pwsh ./scripts/Remove-OldImages.ps1 -Keep 3
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(2, 50)] [int] $Keep = 3
)

Set-StrictMode -Version Latest

# The deploy history helpers: the one definition of where history lives and how it is read.
. (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard', 'Private', 'History.ps1')

# The one place that runs docker. Tests mock this function.
function Invoke-ImageCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $output = & docker @Arguments 2>&1
    [pscustomobject] @{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
}

# Tags that must stay: recent releases of each environment plus anything a container uses.
function Get-ProtectedTag {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [ValidateRange(2, 50)] [int] $Keep)

    $protected = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($environment in @('dev', 'prod')) {
        # Assign first: Read-DeployHistory returns the array as one object.
        $history = Read-DeployHistory -Environment $environment
        $deployed = @($history | Where-Object { $_.status -eq 'deployed' })
        # Newest first, counting distinct tags: a tag deployed twice in a row (for example with
        # another FAIL_RATE) must not push the previous release out of the kept set.
        $kept = [System.Collections.Generic.HashSet[string]]::new()
        for ($i = $deployed.Count - 1; $i -ge 0 -and $kept.Count -lt $Keep; $i--) {
            $kept.Add($deployed[$i].tag) | Out-Null
        }
        $protected.UnionWith($kept)
    }

    # Images used by containers, for example a stack started by hand outside the history.
    $containers = Invoke-ImageCommand -Arguments @('ps', '--all', '--format', '{{.Image}}')
    foreach ($image in $containers.Output) {
        if ($image -match '^sk-svc:(.+)$') {
            $protected.Add($Matches[1]) | Out-Null
        }
    }
    return [string[]] @($protected)
}

function Remove-OldImage {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [ValidateRange(2, 50)] [int] $Keep)

    $list = Invoke-ImageCommand -Arguments @('image', 'ls', 'sk-svc', '--format', '{{.Tag}}')
    if ($list.ExitCode -ne 0) {
        throw "Could not list images (is Docker running?): $($list.Output -join ' ')"
    }
    $protected = Get-ProtectedTag -Keep $Keep

    $removed = @()
    $kept = @()
    foreach ($tag in $list.Output) {
        if ($protected -contains $tag) {
            $kept += $tag
            continue
        }
        if ($PSCmdlet.ShouldProcess("sk-svc:$tag", 'Remove image')) {
            $result = Invoke-ImageCommand -Arguments @('image', 'rm', "sk-svc:$tag")
            if ($result.ExitCode -eq 0) {
                $removed += $tag
            } else {
                # Not fatal: report it and keep going with the rest.
                Write-Warning "Could not remove sk-svc:$tag : $($result.Output -join ' ')"
            }
        }
    }
    [pscustomobject] @{ Kept = $kept; Removed = $removed }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Remove-OldImage -Keep $Keep
        Write-Output "Kept $(@($result.Kept).Count) image(s): $($result.Kept -join ', ')"
        Write-Output "Removed $(@($result.Removed).Count) image(s): $($result.Removed -join ', ')"
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
