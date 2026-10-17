# Logic for GET /work: a simulated request that can be told to fail.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Decides how one /work request behaves: how long it waits and which status it returns.
.DESCRIPTION
    Waits a random 10 to 200 ms. Returns 500 with probability FailRate, otherwise 200.
    The random source is a parameter so tests can pass a seeded one and get repeatable results.
#>
function Get-WorkOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateRange(0, 1)] [double] $FailRate,
        [Parameter(Mandatory)] [System.Random] $Random
    )

    # Next(10, 201) returns 10..200 inclusive.
    $delayMs = $Random.Next(10, 201)
    # NextDouble() is in [0, 1), so FailRate 0 never fails and FailRate 1 always fails.
    $statusCode = if ($Random.NextDouble() -lt $FailRate) { 500 } else { 200 }

    [pscustomobject] @{
        DelayMilliseconds = $delayMs
        StatusCode        = $statusCode
    }
}

<#
.SYNOPSIS
    Returns $true for paths that count as user traffic in http_requests_total.
.DESCRIPTION
    Only the user-facing routes count: / and /work. Everything else is left out:
    /metrics (Prometheus scrapes), /healthz (Docker health checks) and /version (deploy and
    smoke-test polls) are machine probes, and unknown paths (404s from scanners) are noise.
    Counting them would add steady non-5xx requests and hide a real error ratio.
#>
function Test-CountedPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Path)
    return $Path -cin @('/', '/work')
}
