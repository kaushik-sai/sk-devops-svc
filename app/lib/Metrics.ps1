# In-memory Prometheus metrics for the service.
# Pode serves requests on several threads at once, so every update takes one lock.
# No Pode dependency: Pester tests these functions directly.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Creates the metrics store: request counts by status code and a latency histogram.
#>
function New-MetricStore {
    # Only builds an in-memory object; nothing outside the process changes, so ShouldProcess adds nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Version)

    # Histogram bucket upper bounds, in seconds. /work sleeps 10 to 200 ms,
    # so most buckets sit around that range.
    $buckets = [double[]] @(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5)

    return @{
        Lock         = [object]::new()
        Version      = $Version
        Requests     = @{}                         # status code (string) -> count
        Buckets      = $buckets
        BucketCounts = [long[]]::new($buckets.Count) # per bucket, not cumulative
        Sum          = [double] 0
        Count        = [long] 0
    }
}

<#
.SYNOPSIS
    Records one finished request: its status code and how long it took.
#>
function Add-RequestMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Store,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [double] $DurationSeconds
    )

    # Monitor is a plain .NET lock. try/finally makes sure it is always released.
    [System.Threading.Monitor]::Enter($Store.Lock)
    try {
        $key = [string] $StatusCode
        if ($Store.Requests.ContainsKey($key)) {
            $Store.Requests[$key] += 1
        } else {
            $Store.Requests[$key] = [long] 1
        }

        # Count the request in the first bucket it fits. Cumulative totals are built when printing.
        for ($i = 0; $i -lt $Store.Buckets.Count; $i++) {
            if ($DurationSeconds -le $Store.Buckets[$i]) {
                $Store.BucketCounts[$i] += 1
                break
            }
        }
        $Store.Sum += $DurationSeconds
        $Store.Count += 1
    } finally {
        [System.Threading.Monitor]::Exit($Store.Lock)
    }
}

<#
.SYNOPSIS
    Formats a number the way Prometheus expects (dot decimal separator on every locale).
#>
function Format-MetricNumber {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double] $Value)
    return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
    Returns all metrics in the Prometheus text exposition format.
#>
function Get-MetricText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [hashtable] $Store)

    $lines = [System.Collections.Generic.List[string]]::new()

    # Copy the numbers under the lock, then format outside it.
    [System.Threading.Monitor]::Enter($Store.Lock)
    try {
        $requests = $Store.Requests.Clone()
        $bucketCounts = $Store.BucketCounts.Clone()
        $sum = $Store.Sum
        $count = $Store.Count
    } finally {
        [System.Threading.Monitor]::Exit($Store.Lock)
    }

    $lines.Add('# HELP http_requests_total Total HTTP requests by status code.')
    $lines.Add('# TYPE http_requests_total counter')
    foreach ($status in ($requests.Keys | Sort-Object)) {
        $lines.Add("http_requests_total{status=`"$status`"} $($requests[$status])")
    }

    $lines.Add('# HELP app_info Build information. The value is always 1.')
    $lines.Add('# TYPE app_info gauge')
    $lines.Add("app_info{version=`"$($Store.Version)`"} 1")

    $lines.Add('# HELP http_request_duration_seconds Request duration in seconds.')
    $lines.Add('# TYPE http_request_duration_seconds histogram')
    $cumulative = [long] 0
    for ($i = 0; $i -lt $Store.Buckets.Count; $i++) {
        $cumulative += $bucketCounts[$i]
        $le = Format-MetricNumber -Value $Store.Buckets[$i]
        $lines.Add("http_request_duration_seconds_bucket{le=`"$le`"} $cumulative")
    }
    # +Inf always equals the total count.
    $lines.Add("http_request_duration_seconds_bucket{le=`"+Inf`"} $count")
    $lines.Add("http_request_duration_seconds_sum $(Format-MetricNumber -Value $sum)")
    $lines.Add("http_request_duration_seconds_count $count")

    # Prometheus expects a trailing newline.
    return ($lines -join "`n") + "`n"
}
