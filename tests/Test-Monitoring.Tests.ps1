BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Monitoring.ps1')
    $script:monitoring = Join-Path -Path $TestDrive -ChildPath 'monitoring'
}

Describe 'Get-MonitoringCheck' {
    It 'runs check config, check rules and test rules on the right files' {
        $checks = Get-MonitoringCheck -MonitoringPath $script:monitoring
        $checks.Count | Should -Be 3
        $checks[0].Arguments | Should -Be @('check', 'config', (Join-Path -Path $script:monitoring -ChildPath 'prometheus.yml'))
        $checks[1].Arguments | Should -Be @('check', 'rules', (Join-Path -Path $script:monitoring -ChildPath 'alerts.yml'))
        $checks[2].Arguments | Should -Be @('test', 'rules', (Join-Path -Path $script:monitoring -ChildPath 'alerts.test.yml'))
    }
}

Describe 'Invoke-MonitoringCheck' {
    It 'marks every check OK when promtool exits 0' {
        Mock Invoke-Promtool { [pscustomobject] @{ ExitCode = 0; Output = 'SUCCESS' } }
        $results = Invoke-MonitoringCheck -MonitoringPath $script:monitoring
        $results.Count | Should -Be 3
        $results.Ok | Should -Not -Contain $false
        Should -Invoke Invoke-Promtool -Times 3 -Exactly
    }

    It 'marks only the failing check as not OK' {
        Mock Invoke-Promtool { [pscustomobject] @{ ExitCode = 1; Output = 'FAILED' } } -ParameterFilter { $Arguments[0] -eq 'test' }
        Mock Invoke-Promtool { [pscustomobject] @{ ExitCode = 0; Output = 'SUCCESS' } }
        $results = Invoke-MonitoringCheck -MonitoringPath $script:monitoring
        ($results | Where-Object { -not $_.Ok }).Name | Should -Be 'test rules'
    }

    It 'throws a clear message when promtool is missing' {
        Mock Invoke-Promtool { $null }
        { Invoke-MonitoringCheck -MonitoringPath $script:monitoring } | Should -Throw '*promtool not found on PATH*'
    }
}

Describe 'Format-MonitoringReport' {
    It 'prints PASS and FAIL with the promtool output indented' {
        $results = @(
            [pscustomobject] @{ Name = 'check rules'; Ok = $true; Output = "  SUCCESS: 1 rules found`n" }
            [pscustomobject] @{ Name = 'test rules'; Ok = $false; Output = "  FAILED:`n" }
        )
        $lines = Format-MonitoringReport -Results $results
        $lines[0] | Should -Be 'PASS promtool check rules'
        $lines[1] | Should -Match '^\s+SUCCESS: 1 rules found'
        $lines[2] | Should -Be 'FAIL promtool test rules'
    }
}

Describe 'Test-Monitoring.ps1 exit code' {
    # Runs the real script in a child pwsh so we can see its exit code.
    It 'exits 1 with a clear message when promtool is not on PATH' {
        $script = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Monitoring.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $savedPath = $env:PATH
        try {
            # An empty PATH hides promtool from the child process.
            $env:PATH = ''
            $output = & $pwsh -NoProfile -File $script -MonitoringPath $script:monitoring 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
        }
        $exitCode | Should -Be 1
        $output | Should -Match 'promtool not found on PATH'
    }
}
