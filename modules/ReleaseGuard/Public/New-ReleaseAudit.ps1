Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Writes a release audit report (Markdown and JSON) for the commits in a release.

.DESCRIPTION
    Lists the commits between two refs (-From exclusive, -To inclusive) with SHA,
    author, subject and PR number (taken from "(#<n>)" at the end of the subject).
    Writes release-audit-<to SHA>.md and release-audit-<to SHA>.json to -OutputDir,
    including the image tag and the checks that passed. Returns an object with
    the report data and the two file paths.

    If -From is not given (for example, the first deploy has no previous release),
    the report starts at the repository's first commit.

.PARAMETER From
    The previous release (commit SHA, tag or branch). Not included in the report.

.PARAMETER To
    The release being shipped (commit SHA, tag or branch). Included in the report.
    The file names use its full commit SHA.

.PARAMETER ImageTag
    The container image tag that was deployed, for example sk-svc:<sha>.

.PARAMETER ChecksPassed
    Names of the checks that passed, for example lint, test, trivy.

.PARAMETER OutputDir
    Folder for the report files. Created if missing. Defaults to the current folder.

.PARAMETER RepoPath
    Path to the Git repository. Defaults to the current folder.

.EXAMPLE
    New-ReleaseAudit -From 1a2b3c4 -To HEAD -ImageTag "sk-svc:$(git rev-parse HEAD)" -ChecksPassed lint, test, trivy

    Writes the audit for everything after 1a2b3c4 up to HEAD into the current folder.

.EXAMPLE
    New-ReleaseAudit -To main -OutputDir ./out

    First release: lists every commit from the first one up to main.
#>
function New-ReleaseAudit {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $From,
        [Parameter(Mandatory)] [string] $To,
        [string] $ImageTag = '',
        [string[]] $ChecksPassed = @(),
        [string] $OutputDir = (Get-Location).Path,
        [string] $RepoPath = (Get-Location).Path
    )

    # Resolve -To to a full SHA: it validates the ref and gives a stable file name.
    $toSha = Resolve-CommitSha -RepoPath $RepoPath -Ref $To

    # No -From means "everything up to -To", which is the same as starting at the first commit.
    if ($From) {
        $fromSha = Resolve-CommitSha -RepoPath $RepoPath -Ref $From
        $range = "$fromSha..$toSha"
    } else {
        $fromSha = $null
        $range = $toSha
    }

    # %x1f (unit separator) cannot appear in names or subjects, so splitting on it is safe.
    $git = Invoke-Git -RepoPath $RepoPath -Arguments @('log', '--format=%H%x1f%an%x1f%s', $range)
    if ($git.ExitCode -ne 0) {
        Write-Error -Message "git log failed: $($git.Output -join ' ')" -ErrorId 'ReleaseGuard.GitFailed' `
            -Category InvalidResult -ErrorAction Stop
    }

    $commits = @(
        foreach ($line in $git.Output) {
            $sha, $author, $subject = $line -split [char] 0x1f, 3
            # Squash-merged PRs end with "(#12)"; direct commits have no PR number.
            $prNumber = if ($subject -match '\(#(\d+)\)$') { [int] $Matches[1] } else { $null }
            [pscustomobject] @{
                Sha      = $sha
                Author   = $author
                Subject  = $subject
                PrNumber = $prNumber
            }
        }
    )

    $audit = [pscustomobject] @{
        From           = $fromSha
        To             = $toSha
        ImageTag       = $ImageTag
        ChecksPassed   = @($ChecksPassed)
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        CommitCount    = $commits.Count
        Commits        = $commits
    }

    $jsonPath = Join-Path -Path $OutputDir -ChildPath "release-audit-$toSha.json"
    $markdownPath = Join-Path -Path $OutputDir -ChildPath "release-audit-$toSha.md"

    if ($PSCmdlet.ShouldProcess($OutputDir, "Write release audit for $toSha")) {
        if (-not (Test-Path -Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir | Out-Null
        }
        $audit | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding utf8
        ConvertTo-AuditMarkdown -Audit $audit | Set-Content -Path $markdownPath -Encoding utf8
    }

    $audit | Add-Member -NotePropertyName JsonPath -NotePropertyValue $jsonPath
    $audit | Add-Member -NotePropertyName MarkdownPath -NotePropertyValue $markdownPath
    return $audit
}
