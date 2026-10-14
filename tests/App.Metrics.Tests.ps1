BeforeAll {
    $script:metricsLib = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'app', 'lib', 'Metrics.ps1'
    . $script:metricsLib
}

Describe 'Get-MetricText' {
    It 'prints the three metrics in Prometheus text format' {
        $store = New-MetricStore -Version 'abc123'
        Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 0.02
        Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 0.15
        Add-RequestMetric -Store $store -StatusCode 500 -DurationSeconds 0.07

        $text = Get-MetricText -Store $store
        $text | Should -Match '# TYPE http_requests_total counter'
        $text | Should -Match 'http_requests_total\{status="200"\} 2'
        $text | Should -Match 'http_requests_total\{status="500"\} 1'
        $text | Should -Match 'app_info\{version="abc123"\} 1'
        $text | Should -Match '# TYPE http_request_duration_seconds histogram'
        $text | Should -Match 'http_request_duration_seconds_count 3'
        $text | Should -Match '(?m)^http_request_duration_seconds_sum 0\.24'
    }

    It 'makes histogram buckets cumulative and ends with +Inf equal to the count' {
        $store = New-MetricStore -Version 'x'
        Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 0.004   # fits 0.005
        Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 0.04    # fits 0.05
        Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 9       # above every bucket

        $text = Get-MetricText -Store $store
        $text | Should -Match 'http_request_duration_seconds_bucket\{le="0.005"\} 1'
        $text | Should -Match 'http_request_duration_seconds_bucket\{le="0.05"\} 2'
        $text | Should -Match 'http_request_duration_seconds_bucket\{le="5"\} 2'
        $text | Should -Match 'http_request_duration_seconds_bucket\{le="\+Inf"\} 3'
    }

    It 'ends with a newline, as Prometheus expects' {
        Get-MetricText -Store (New-MetricStore -Version 'x') | Should -Match "`n$"
    }

    It 'formats numbers with a dot on any machine culture' {
        $original = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = 'de-DE'
            $store = New-MetricStore -Version 'x'
            Add-RequestMetric -Store $store -StatusCode 200 -DurationSeconds 0.5
            $text = Get-MetricText -Store $store
            $text | Should -Match 'le="0.005"'
            $text | Should -Match '(?m)^http_request_duration_seconds_sum 0\.5$'
        } finally {
            [Globalization.CultureInfo]::CurrentCulture = $original
        }
    }
}

Describe 'Add-RequestMetric thread safety' {
    It 'loses no updates when many threads write at once' {
        $store = New-MetricStore -Version 'x'
        $lib = $script:metricsLib
        # 8 threads x 250 requests each. Without the lock, concurrent += would drop some.
        1..8 | ForEach-Object -ThrottleLimit 8 -Parallel {
            . $using:lib
            $s = $using:store
            for ($i = 0; $i -lt 250; $i++) {
                Add-RequestMetric -Store $s -StatusCode 200 -DurationSeconds 0.01
            }
        }
        $store.Count | Should -Be 2000
        $store.Requests['200'] | Should -Be 2000
    }
}
