Set-StrictMode -Version Latest

# Turns a ref (tag, branch, short SHA, HEAD) into a full commit SHA, or fails clearly.
function Resolve-CommitSha {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Ref
    )
    # ^{commit} makes an annotated tag resolve to the commit it points at.
    $git = Invoke-Git -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($git.ExitCode -ne 0) {
        Write-Error -Message "Unknown Git ref '$Ref' in '$RepoPath'." -ErrorId 'ReleaseGuard.UnknownRef' `
            -Category ObjectNotFound -ErrorAction Stop
    }
    return $git.Output[0]
}

# Builds the Markdown version of the audit as one string.
function ConvertTo-AuditMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [pscustomobject] $Audit)

    $from = if ($Audit.From) { $Audit.From } else { '(first commit)' }
    $checks = if ($Audit.ChecksPassed.Count -gt 0) { $Audit.ChecksPassed -join ', ' } else { '(none recorded)' }
    $lines = @(
        "# Release audit $($Audit.To)"
        ''
        "- From: $from"
        "- To: $($Audit.To)"
        "- Image tag: $($Audit.ImageTag)"
        "- Checks passed: $checks"
        "- Generated (UTC): $($Audit.GeneratedAtUtc)"
        "- Commits: $($Audit.CommitCount)"
        ''
        '| SHA | Author | PR | Subject |'
        '|-----|--------|----|---------|'
    )
    foreach ($commit in $Audit.Commits) {
        $pr = if ($commit.PrNumber) { "#$($commit.PrNumber)" } else { '(none)' }
        # A "|" inside a subject would break the table, so escape it.
        $subject = $commit.Subject -replace '\|', '\|'
        $lines += "| $($commit.Sha.Substring(0, 12)) | $($commit.Author) | $pr | $subject |"
    }
    return ($lines -join "`n") + "`n"
}
