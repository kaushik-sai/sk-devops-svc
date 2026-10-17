Set-StrictMode -Version Latest

# Deploy history helpers. Plain functions in one file so both the module
# (Invoke-Rollback) and scripts/Invoke-Deploy.ps1 can dot-source them.
#
# One JSON file per environment: <history folder>/<env>.json, an array of
#   { tag, failRate, deployedAtUtc, status, rolledBackFrom }
# status is deployed | rolled_back | failed. rolledBackFrom is the bad tag when
# the entry was written by a rollback, otherwise null. Oldest entry first.
# A release is the tag plus its FAIL_RATE: the same image with another FAIL_RATE is
# a different release. Entries written before failRate existed count as 0.
#
# The folder is outside the repo and the pipeline workspace, so it survives
# fresh checkouts: $HOME/.releaseguard/history, or $env:RELEASEGUARD_HOME/history.

function Get-DeployHistoryPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment)

    $root = if ($env:RELEASEGUARD_HOME) { $env:RELEASEGUARD_HOME } else { Join-Path -Path $HOME -ChildPath '.releaseguard' }
    return Join-Path -Path $root -ChildPath 'history' -AdditionalChildPath "$Environment.json"
}

# Returns the entries as an array (empty when there is no history yet).
function Read-DeployHistory {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment)

    $path = Get-DeployHistoryPath -Environment $Environment
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        return , @()
    }
    # @() keeps a one-entry history an array. The leading comma stops PowerShell
    # from unrolling the array when it is returned.
    $entries = @(Get-Content -Path $path -Raw | ConvertFrom-Json)
    return , $entries
}

# Replaces the whole history file with the given entries.
function Write-DeployHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entries
    )
    $path = Get-DeployHistoryPath -Environment $Environment
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    # -InputObject (not the pipeline) so a single entry is still written as a JSON array.
    ConvertTo-Json -InputObject @($Entries) -Depth 5 | Set-Content -Path $path -Encoding utf8
}

# Appends one entry and saves. Returns the new entry.
function Add-DeployHistoryEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [ValidateSet('deployed', 'rolled_back', 'failed')] [string] $Status,
        [string] $RolledBackFrom,
        [ValidateRange(0, 1)] [double] $FailRate = 0
    )
    $entry = [pscustomobject] @{
        tag            = $Tag
        failRate       = $FailRate
        # Stored as an ISO 8601 UTC string, readable by people and tools.
        deployedAtUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        status         = $Status
        rolledBackFrom = if ($RolledBackFrom) { $RolledBackFrom } else { $null }
    }
    $entries = Read-DeployHistory -Environment $Environment
    Write-DeployHistory -Environment $Environment -Entries (@($entries) + $entry)
    return $entry
}

# The FAIL_RATE an entry was deployed with; 0 for entries written before it was recorded.
function Get-EntryFailRate {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [object] $Entry)
    $property = $Entry.PSObject.Properties['failRate']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [double] 0
    }
    return [double] $property.Value
}

# True when two entries are the same release: same tag and same FAIL_RATE.
function Test-SameRelease {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [object] $Entry,
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [double] $FailRate
    )
    return $Entry.tag -eq $Tag -and (Get-EntryFailRate -Entry $Entry) -eq $FailRate
}
