<#
.SYNOPSIS
    Smoke-tests a running sk-svc environment.

.DESCRIPTION
    Three checks:
    1. GET /healthz returns status "ok".
    2. GET /version returns the expected commit SHA.
    3. N requests to GET /work all return 200. This catches a "bad release"
       (FAIL_RATE above 0) that /healthz alone would not show.
    Prints one line per check and exits 1 if any check fails, otherwise 0.

.PARAMETER BaseUrl
    Base URL of the environment, for example http://127.0.0.1:7311.

.PARAMETER ExpectedSha
    The commit SHA that /version must return.

.PARAMETER Requests
    How many /work requests to send. Default 20.

.EXAMPLE
    pwsh ./scripts/Test-Smoke.ps1 -BaseUrl http://127.0.0.1:7312 -ExpectedSha (git rev-parse HEAD)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $ExpectedSha,
    [ValidateRange(1, 1000)] [int] $Requests = 20
)

Set-StrictMode -Version Latest

# Runs the three checks and returns one result object per check: Name, Ok, Detail.
function Invoke-SmokeTest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $ExpectedSha,
        [int] $Requests = 20
    )
    # Avoid "//healthz" when the URL is given with a trailing slash.
    $base = $BaseUrl.TrimEnd('/')

    # 1. Health
    try {
        $health = Invoke-RestMethod -Uri "$base/healthz" -TimeoutSec 10
        $ok = $health.status -eq 'ok'
        [pscustomobject] @{ Name = 'healthz'; Ok = $ok; Detail = "status=$($health.status)" }
    } catch {
        [pscustomobject] @{ Name = 'healthz'; Ok = $false; Detail = $_.Exception.Message }
    }

    # 2. Version
    try {
        $version = Invoke-RestMethod -Uri "$base/version" -TimeoutSec 10
        $ok = $version.version -eq $ExpectedSha
        [pscustomobject] @{ Name = 'version'; Ok = $ok; Detail = "got $($version.version), expected $ExpectedSha" }
    } catch {
        [pscustomobject] @{ Name = 'version'; Ok = $false; Detail = $_.Exception.Message }
    }

    # 3. Work: every request must return 200.
    $failures = 0
    for ($i = 1; $i -le $Requests; $i++) {
        try {
            # -SkipHttpErrorCheck: a 500 comes back as a response we can count, not as an exception.
            $response = Invoke-WebRequest -Uri "$base/work" -TimeoutSec 10 -SkipHttpErrorCheck
            if ($response.StatusCode -ne 200) {
                $failures++
            }
        } catch {
            # Connection errors and timeouts count as failures too.
            $failures++
        }
    }
    [pscustomobject] @{ Name = 'work'; Ok = ($failures -eq 0); Detail = "$failures of $Requests requests failed" }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $results = @(Invoke-SmokeTest -BaseUrl $BaseUrl -ExpectedSha $ExpectedSha -Requests $Requests)
    foreach ($r in $results) {
        $state = if ($r.Ok) { 'PASS' } else { 'FAIL' }
        Write-Output ('{0} {1,-8} {2}' -f $state, $r.Name, $r.Detail)
    }
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Error -Message "Smoke test failed: $($failed.Count) check(s) failed against $BaseUrl." -ErrorAction Continue
        exit 1
    }
    exit 0
}
