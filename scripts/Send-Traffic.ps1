<#
.SYNOPSIS
    Sends steady traffic to <BaseUrl>/work and prints how many responses came back with each status code.

.DESCRIPTION
    Used for the alert demo: with prod restarted at FAIL_RATE=0.33, this traffic makes the
    ProdHighErrorRate alert go pending and then firing.
    Sends DurationSeconds x RatePerSecond requests one after another, pausing between them
    so the rate is roughly RatePerSecond. A request that gets no response (service down,
    timeout) is counted as "no-response".
    Exits 1 if no request got a response, otherwise 0.

.PARAMETER BaseUrl
    Base URL of the service, for example http://127.0.0.1:7312 for prod.

.PARAMETER DurationSeconds
    How long to send traffic. Default 300 (5 minutes, enough for the alert to fire).

.PARAMETER RatePerSecond
    Requests per second to aim for. Default 2 (well above the alert's 0.2/s traffic guard).

.EXAMPLE
    pwsh ./scripts/Send-Traffic.ps1 -BaseUrl http://127.0.0.1:7312 -DurationSeconds 300 -RatePerSecond 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [ValidateRange(1, 3600)] [int] $DurationSeconds = 300,
    [ValidateRange(0.1, 50)] [double] $RatePerSecond = 2
)

Set-StrictMode -Version Latest

# The one place that makes an HTTP call. Tests mock it.
# Returns the HTTP status code, or 0 when there was no response at all.
function Invoke-WorkRequest {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [string] $Uri)
    try {
        # -SkipHttpErrorCheck: a 500 is a normal answer here, not an exception.
        $response = Invoke-WebRequest -Uri $Uri -SkipHttpErrorCheck -TimeoutSec 5
        return [int] $response.StatusCode
    } catch {
        return 0
    }
}

# The one place that sleeps. Tests mock it so they run instantly.
function Wait-Interval {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

# Sends the requests and returns a hashtable: status code (or "no-response") -> count.
function Invoke-TrafficRun {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [int] $DurationSeconds,
        [Parameter(Mandatory)] [double] $RatePerSecond
    )
    # A URL, not a file path, so "/" is correct here.
    $uri = $BaseUrl.TrimEnd('/') + '/work'
    # A fixed number of requests keeps the run predictable (and testable).
    $total = [math]::Max(1, [int] [math]::Round($DurationSeconds * $RatePerSecond))
    $intervalMs = [int] (1000 / $RatePerSecond)
    $counts = @{}

    for ($i = 1; $i -le $total; $i++) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = Invoke-WorkRequest -Uri $uri
        $key = if ($status -eq 0) { 'no-response' } else { [string] $status }
        $counts[$key] = 1 + $(if ($counts.ContainsKey($key)) { $counts[$key] } else { 0 })

        # Sleep only for the rest of the interval: /work itself takes 10-200 ms.
        $remaining = $intervalMs - [int] $stopwatch.ElapsedMilliseconds
        if ($i -lt $total -and $remaining -gt 0) {
            Wait-Interval -Milliseconds $remaining
        }
    }
    return $counts
}

# Turns the counts into readable lines. Returns strings so tests can check them.
function Format-TrafficSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [hashtable] $Counts)
    $total = ($Counts.Values | Measure-Object -Sum).Sum
    "Sent $total request(s)."
    foreach ($key in ($Counts.Keys | Sort-Object)) {
        $percent = 100 * $Counts[$key] / $total
        '{0,-12} {1,6} ({2:N1}%)' -f $key, $Counts[$key], $percent
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Output "Sending ~$RatePerSecond request(s)/s to $($BaseUrl.TrimEnd('/'))/work for $DurationSeconds s..."
    $counts = Invoke-TrafficRun -BaseUrl $BaseUrl -DurationSeconds $DurationSeconds -RatePerSecond $RatePerSecond
    Format-TrafficSummary -Counts $counts | Write-Output
    $answered = @($counts.Keys | Where-Object { $_ -ne 'no-response' })
    if ($answered.Count -eq 0) {
        Write-Error "No request got a response from $BaseUrl. Is the service running?" -ErrorAction Continue
        exit 1
    }
    exit 0
}
