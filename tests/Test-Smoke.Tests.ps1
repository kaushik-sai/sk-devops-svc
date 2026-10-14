BeforeAll {
    # Dot-source to get Invoke-SmokeTest without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Smoke.ps1') -BaseUrl 'unused' -ExpectedSha 'unused'
}

Describe 'Invoke-SmokeTest' {
    BeforeEach {
        # A healthy fake service running version "abc".
        Mock Invoke-RestMethod { [pscustomobject] @{ status = 'ok'; secret_loaded = $true } } -ParameterFilter { $Uri -like '*/healthz' }
        Mock Invoke-RestMethod { [pscustomobject] @{ version = 'abc' } } -ParameterFilter { $Uri -like '*/version' }
        Mock Invoke-WebRequest { [pscustomobject] @{ StatusCode = 200 } }
    }

    It 'passes all three checks against a healthy service' {
        $results = Invoke-SmokeTest -BaseUrl 'http://127.0.0.1:7311' -ExpectedSha 'abc' -Requests 5
        $results.Count | Should -Be 3
        $results.Ok | Should -Not -Contain $false
        Should -Invoke Invoke-WebRequest -Times 5 -Exactly -ParameterFilter { $Uri -eq 'http://127.0.0.1:7311/work' }
    }

    It 'handles a trailing slash in the base URL' {
        Invoke-SmokeTest -BaseUrl 'http://127.0.0.1:7311/' -ExpectedSha 'abc' -Requests 1 | Out-Null
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -eq 'http://127.0.0.1:7311/healthz' }
    }

    It 'fails the version check when the SHA does not match' {
        $results = Invoke-SmokeTest -BaseUrl 'http://x' -ExpectedSha 'def' -Requests 1
        ($results | Where-Object Name -EQ 'version').Ok | Should -BeFalse
    }

    It 'fails the work check when any request returns 500' {
        $script:count = 0
        Mock Invoke-WebRequest {
            $script:count++
            $status = if ($script:count -eq 3) { 500 } else { 200 }
            [pscustomobject] @{ StatusCode = $status }
        }
        $work = Invoke-SmokeTest -BaseUrl 'http://x' -ExpectedSha 'abc' -Requests 10 | Where-Object Name -EQ 'work'
        $work.Ok | Should -BeFalse
        $work.Detail | Should -Be '1 of 10 requests failed'
    }

    It 'fails the health check when the service is down' {
        Mock Invoke-RestMethod { throw 'connection refused' } -ParameterFilter { $Uri -like '*/healthz' }
        $health = Invoke-SmokeTest -BaseUrl 'http://x' -ExpectedSha 'abc' -Requests 1 | Where-Object Name -EQ 'healthz'
        $health.Ok | Should -BeFalse
        $health.Detail | Should -Match 'connection refused'
    }

    It 'fails the health check when status is not ok' {
        Mock Invoke-RestMethod { [pscustomobject] @{ status = 'degraded' } } -ParameterFilter { $Uri -like '*/healthz' }
        $health = Invoke-SmokeTest -BaseUrl 'http://x' -ExpectedSha 'abc' -Requests 1 | Where-Object Name -EQ 'healthz'
        $health.Ok | Should -BeFalse
    }

    It 'counts connection errors on /work as failures' {
        Mock Invoke-WebRequest { throw 'timeout' }
        $work = Invoke-SmokeTest -BaseUrl 'http://x' -ExpectedSha 'abc' -Requests 3 | Where-Object Name -EQ 'work'
        $work.Detail | Should -Be '3 of 3 requests failed'
    }
}

Describe 'Test-Smoke.ps1 exit code' {
    # Runs the real script in a child pwsh against a closed local port: nothing
    # listens there, so every check fails and the script must exit non-zero.
    It 'exits 1 when the service cannot be reached' {
        $pwsh = (Get-Process -Id $PID).Path
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Smoke.ps1'
        & $pwsh -NoProfile -NonInteractive -File $scriptPath -BaseUrl 'http://127.0.0.1:9' -ExpectedSha 'abc' -Requests 1 *> $null
        $LASTEXITCODE | Should -Be 1
    }
}
