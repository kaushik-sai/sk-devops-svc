BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'app', 'lib', 'Work.ps1')
}

Describe 'Get-WorkOutcome' {
    It 'never fails when FAIL_RATE is 0' {
        $random = [System.Random]::new(42)
        $codes = 1..200 | ForEach-Object { (Get-WorkOutcome -FailRate 0 -Random $random).StatusCode }
        $codes | Should -Not -Contain 500
    }

    It 'always fails when FAIL_RATE is 1' {
        $random = [System.Random]::new(42)
        $codes = 1..200 | ForEach-Object { (Get-WorkOutcome -FailRate 1 -Random $random).StatusCode }
        $codes | Should -Not -Contain 200
    }

    It 'fails roughly a third of the time when FAIL_RATE is 0.33' {
        # Seeded, so the result is the same on every run.
        $random = [System.Random]::new(42)
        $failures = @(1..1000 | ForEach-Object { Get-WorkOutcome -FailRate 0.33 -Random $random } |
                Where-Object StatusCode -EQ 500).Count
        $failures | Should -BeGreaterThan 280
        $failures | Should -BeLessThan 380
    }

    It 'waits between 10 and 200 ms' {
        $random = [System.Random]::new(7)
        $delays = 1..500 | ForEach-Object { (Get-WorkOutcome -FailRate 0 -Random $random).DelayMilliseconds }
        ($delays | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 10
        ($delays | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 200
    }

    It 'rejects a FAIL_RATE outside 0 to 1' {
        { Get-WorkOutcome -FailRate 2 -Random ([System.Random]::new(1)) } | Should -Throw
    }
}

Describe 'Test-CountedPath' {
    It 'counts user traffic: <Path>' -ForEach @(
        @{ Path = '/work' }
        @{ Path = '/' }
    ) {
        Test-CountedPath -Path $Path | Should -BeTrue
    }

    It 'does not count probes or unknown paths: <Path>' -ForEach @(
        @{ Path = '/metrics' }
        @{ Path = '/healthz' }
        @{ Path = '/version' }
        @{ Path = '/unknown' }
        @{ Path = '/WORK' }
    ) {
        Test-CountedPath -Path $Path | Should -BeFalse
    }
}
