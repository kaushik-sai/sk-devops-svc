Set-StrictMode -Version Latest

# The one place the module runs git. Returns the exit code and the output lines
# so callers decide what a failure means.
function Invoke-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    # -C runs git inside the repo without changing our current directory.
    # 2>&1 so error text ends up in Output instead of on the console.
    $output = & git -C $RepoPath @Arguments 2>&1
    [pscustomobject] @{
        ExitCode = $LASTEXITCODE
        # Turn stderr records into plain strings and drop empty lines.
        Output   = @($output | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
    }
}

# Finds main locally, or as origin/main on a CI checkout where no local main exists.
function Get-MainBranchRef {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $MainBranch
    )
    foreach ($ref in @("refs/heads/$MainBranch", "refs/remotes/origin/$MainBranch")) {
        if ((Invoke-Git -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', $ref)).ExitCode -eq 0) {
            return $ref
        }
    }
    return $null
}
