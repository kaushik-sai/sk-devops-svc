Set-StrictMode -Version Latest

# Shared helpers for the ReleaseGuard tests. Not a test file itself
# (Pester only runs *.Tests.ps1); test files dot-source it in BeforeAll.

# Creates an empty folder under the system temp folder and returns its path.
function Initialize-TempFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('releaseguard-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

# Creates a throwaway Git repo with branch main and a local test identity,
# so tests never depend on (or change) the machine's git config.
function Initialize-GitFixture {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Initialize-TempFolder
    git -C $path init --quiet --initial-branch=main
    git -C $path config user.name 'Test User'
    git -C $path config user.email 'test@example.com'
    git -C $path config commit.gpgsign false
    return $path
}

# Adds an empty commit (no files needed for history checks) and returns its full SHA.
function Add-FixtureCommit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Message
    )
    git -C $RepoPath commit --quiet --allow-empty -m $Message
    return (git -C $RepoPath rev-parse HEAD)
}

# Deletes a temp folder. -Force because git marks object files read-only on Windows.
function Remove-TempFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path)
    if ((Test-Path -Path $Path) -and $PSCmdlet.ShouldProcess($Path, 'Delete temp folder')) {
        Remove-Item -Path $Path -Recurse -Force
    }
}
