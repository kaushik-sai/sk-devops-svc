Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Checks branch names and main's commit history against the release policy.

.DESCRIPTION
    Reads the policy from policy.json (allowed branch name patterns, the PR-merge
    commit pattern and the baseline tag) and checks two things:

    1. Branch names: every local branch, or only -BranchName when given.
       A leading "refs/heads/" is removed, so Azure Pipelines can pass
       $(System.PullRequest.SourceBranch) as it is.
    2. Commits on main: walks main's first-parent history after the baseline
       tag and flags every commit whose subject does not end with "(#<PR number>)".
       Commits at or before the baseline are exempt (bootstrap commits were
       pushed directly). If the baseline tag does not exist, a warning is shown
       and commits are not checked; branch names are still checked.

    Prints a readable report (information stream) and returns a result object.
    When there are violations it then throws a terminating error with ID
    ReleaseGuard.PolicyViolation, so "pwsh -Command" and pipeline steps exit
    non-zero. Use -NoThrow to only get the result object (for tests or scripts
    that want to inspect it).

.PARAMETER RepoPath
    Path to the Git repository to check.

.PARAMETER BranchName
    Check only this branch name instead of all local branches.
    "refs/heads/feature/foo" and "feature/foo" are treated the same.

.PARAMETER PolicyPath
    Path to the policy JSON file. Defaults to policy.json next to the module.

.PARAMETER Since
    Check main's commits after this ref instead of the policy's baseline tag.

.PARAMETER NoThrow
    Return the result object without throwing when there are violations.

.EXAMPLE
    Test-BranchCompliance -RepoPath .

    Checks all local branches and main's commits after the governance-baseline tag.

.EXAMPLE
    pwsh -NoProfile -Command "Import-Module ./modules/ReleaseGuard; Test-BranchCompliance -RepoPath . -BranchName refs/heads/feature/login"

    The PR pipeline step: exits non-zero when the branch or main's history breaks the policy.

.EXAMPLE
    $result = Test-BranchCompliance -RepoPath . -NoThrow
    $result.CommitViolations

    Inspects the violations without stopping the script.
#>
function Test-BranchCompliance {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [string] $BranchName,
        [string] $PolicyPath = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'policy.json'),
        [string] $Since,
        [switch] $NoThrow
    )

    # Show the report by default; a caller can still hide it with -InformationAction Ignore.
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
        $InformationPreference = 'Continue'
    }

    if (-not (Test-Path -Path $PolicyPath -PathType Leaf)) {
        Write-Error -Message "Policy file not found: $PolicyPath" -ErrorId 'ReleaseGuard.PolicyNotFound' `
            -Category ObjectNotFound -ErrorAction Stop
    }
    $policy = Get-Content -Path $PolicyPath -Raw | ConvertFrom-Json

    # --- 1. Branch names -------------------------------------------------------
    if ($BranchName) {
        # Azure Pipelines passes "refs/heads/feature/foo"; the policy talks about "feature/foo".
        $branches = @($BranchName -replace '^refs/heads/', '')
    } else {
        $git = Invoke-Git -RepoPath $RepoPath -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads')
        if ($git.ExitCode -ne 0) {
            Write-Error -Message "git failed in '$RepoPath': $($git.Output -join ' ')" -ErrorId 'ReleaseGuard.GitFailed' `
                -Category InvalidResult -ErrorAction Stop
        }
        $branches = $git.Output
    }

    $branchViolations = @()
    foreach ($branch in $branches) {
        $allowed = $false
        foreach ($pattern in $policy.allowedBranchPatterns) {
            # -cmatch is case-sensitive: "feature/Login" must fail (lowercase only).
            if ($branch -cmatch $pattern) {
                $allowed = $true
            }
        }
        if (-not $allowed) {
            $branchViolations += $branch
        }
    }

    # --- 2. Commits on main after the baseline ----------------------------------
    $startRef = if ($Since) { $Since } else { $policy.baseline }
    $commitViolations = @()
    $baselineFound = (Invoke-Git -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', "$startRef^{commit}")).ExitCode -eq 0
    $mainRef = Get-MainBranchRef -RepoPath $RepoPath -MainBranch $policy.mainBranch

    if (-not $baselineFound) {
        Write-Warning "Baseline '$startRef' not found: commit history on $($policy.mainBranch) was NOT checked. Create the tag to start enforcing."
    } elseif (-not $mainRef) {
        Write-Warning "Branch '$($policy.mainBranch)' not found: commit history was NOT checked."
    } else {
        # <baseline>..main = commits on main after the baseline (the baseline itself is exempt).
        # --first-parent follows main's own line only, which is one commit per squash-merged PR.
        # %x09 is a tab, used to split the SHA from the subject.
        $logArgs = @('log', '--first-parent', '--format=%H%x09%s', "$startRef..$mainRef")
        $git = Invoke-Git -RepoPath $RepoPath -Arguments $logArgs
        if ($git.ExitCode -ne 0) {
            Write-Error -Message "git log failed: $($git.Output -join ' ')" -ErrorId 'ReleaseGuard.GitFailed' `
                -Category InvalidResult -ErrorAction Stop
        }
        foreach ($line in $git.Output) {
            $sha, $subject = $line -split "`t", 2
            if ($subject -notmatch $policy.prMergeCommitPattern) {
                $commitViolations += [pscustomobject] @{ Sha = $sha; Subject = $subject }
            }
        }
    }

    $result = [pscustomobject] @{
        Compliant        = ($branchViolations.Count -eq 0 -and $commitViolations.Count -eq 0)
        BranchesChecked  = @($branches)
        BranchViolations = $branchViolations
        CommitsChecked   = $baselineFound -and [bool] $mainRef
        CommitViolations = $commitViolations
    }

    # --- Report -----------------------------------------------------------------
    Write-Information "Branch policy: $($policy.allowedBranchPatterns -join ', ')"
    foreach ($branch in $branches) {
        $state = if ($branchViolations -contains $branch) { 'FAIL' } else { 'OK  ' }
        Write-Information "  $state branch $branch"
    }
    if ($result.CommitsChecked) {
        Write-Information "Commits on $($policy.mainBranch) after '$startRef' must end with a PR number like (#12):"
        foreach ($commit in $commitViolations) {
            Write-Information "  FAIL commit $($commit.Sha.Substring(0, 12)) $($commit.Subject)"
        }
        if ($commitViolations.Count -eq 0) {
            Write-Information '  OK   all commits came from pull requests'
        }
    }
    $summary = if ($result.Compliant) { 'COMPLIANT' } else { "NOT COMPLIANT: $($branchViolations.Count) branch and $($commitViolations.Count) commit violation(s)" }
    Write-Information "Result: $summary"

    # Return the result first, then fail if needed. A terminating error is what
    # makes "pwsh -Command ..." and the pipeline step exit non-zero.
    $result
    if (-not $result.Compliant -and -not $NoThrow) {
        Write-Error -Message "Release policy violated: $summary" -ErrorId 'ReleaseGuard.PolicyViolation' `
            -Category InvalidData -ErrorAction Stop
    }
}
