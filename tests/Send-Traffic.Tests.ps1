BeforeAll {
    # Dot-source so we get the functions without running the main block.
    # BaseUrl is mandatory, so pass a dummy value; the main block does not run when dot-sourced.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Send-Traffic.ps1') -BaseUrl 'http://test'
}

Describe 'Invoke-TrafficRun' {
    BeforeEach {
        # Never really sleep in tests.
        Mock Wait-Interval { }
    }

    It 'sends DurationSeconds x RatePerSecond requests to /work' {
        Mock Invoke-WorkRequest { 200 }
        $counts = Invoke-TrafficRun -BaseUrl 'http://127.0.0.1:7312/' -DurationSeconds 5 -RatePerSecond 2
        $counts['200'] | Should -Be 10
        Should -Invoke Invoke-WorkRequest -Times 10 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:7312/work' }
    }

    It 'counts each status code separately' {
        # Every third request fails, like FAIL_RATE=0.33.
        $script:n = 0
        Mock Invoke-WorkRequest { $script:n++; if ($script:n % 3 -eq 0) { 500 } else { 200 } }
        $counts = Invoke-TrafficRun -BaseUrl 'http://x' -DurationSeconds 3 -RatePerSecond 3
        $counts['200'] | Should -Be 6
        $counts['500'] | Should -Be 3
    }

    It 'counts a request with no response as no-response' {
        Mock Invoke-WorkRequest { 0 }
        $counts = Invoke-TrafficRun -BaseUrl 'http://x' -DurationSeconds 1 -RatePerSecond 2
        $counts['no-response'] | Should -Be 2
    }

    It 'waits about 1000/RatePerSecond ms between requests, not after the last one' {
        Mock Invoke-WorkRequest { 200 }
        Invoke-TrafficRun -BaseUrl 'http://x' -DurationSeconds 2 -RatePerSecond 2 | Out-Null
        # 4 requests, so 3 waits; each at most 500 ms (the request time is subtracted).
        Should -Invoke Wait-Interval -Times 3 -Exactly
        Should -Invoke Wait-Interval -Times 0 -Exactly -ParameterFilter { $Milliseconds -gt 500 }
    }

    It 'sends at least one request for very short low-rate runs' {
        Mock Invoke-WorkRequest { 200 }
        $counts = Invoke-TrafficRun -BaseUrl 'http://x' -DurationSeconds 1 -RatePerSecond 0.1
        $counts['200'] | Should -Be 1
    }
}

Describe 'Invoke-WorkRequest' {
    It 'returns the status code, including 500, without throwing' {
        Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 500 } }
        Invoke-WorkRequest -Uri 'http://x/work' | Should -Be 500
    }

    It 'returns 0 when the service does not answer' {
        Mock Invoke-WebRequest { throw 'connection refused' }
        Invoke-WorkRequest -Uri 'http://x/work' | Should -Be 0
    }
}

Describe 'Format-TrafficSummary' {
    It 'prints the total and a line per status with its share' {
        $lines = Format-TrafficSummary -Counts @{ '200' = 6; '500' = 3; 'no-response' = 1 }
        $lines[0] | Should -Be 'Sent 10 request(s).'
        $lines | Should -Contain ('{0,-12} {1,6} ({2:N1}%)' -f '500', 3, 30)
        $lines.Count | Should -Be 4
    }
}
