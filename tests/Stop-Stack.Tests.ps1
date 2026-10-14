BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Stop-Stack.ps1')
}

Describe 'Stop-Stack' {
    BeforeEach {
        $script:savedHome = $env:RELEASEGUARD_HOME
        $env:RELEASEGUARD_HOME = Join-Path -Path $TestDrive -ChildPath 'rg'
        Mock Invoke-StackCommand { 0 }
    }
    AfterEach {
        $env:RELEASEGUARD_HOME = $script:savedHome
    }

    It 'brings down all four projects with their profiles' {
        Stop-Stack | Should -Be 0
        foreach ($pair in @(@('sksvc-dev', 'dev'), @('sksvc-prod', 'prod'), @('sksvc-data', 'data'), @('sksvc-mon', 'monitoring'))) {
            $project = $pair[0]
            $profileName = $pair[1]
            Should -Invoke Invoke-StackCommand -Times 1 -ParameterFilter {
                $joined = $Arguments -join ' '
                $joined -match "-p $project --profile $profileName down" -and $joined -notmatch ' -v'
            }
        }
    }

    It 'removes the network when it exists' {
        Stop-Stack | Out-Null
        Should -Invoke Invoke-StackCommand -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'network rm sksvc-net' }
    }

    It 'skips removing the network when it is already gone' {
        Mock Invoke-StackCommand { 1 } -ParameterFilter { $Arguments[1] -eq 'inspect' }
        Stop-Stack | Should -Be 0
        Should -Invoke Invoke-StackCommand -Times 0 -ParameterFilter { $Arguments[1] -eq 'rm' }
    }

    It '-Purge also removes volumes and the deploy history' {
        $history = Join-Path -Path $env:RELEASEGUARD_HOME -ChildPath 'history'
        New-Item -ItemType Directory -Path $history -Force | Out-Null
        Set-Content -Path (Join-Path -Path $history -ChildPath 'prod.json') -Value '[]'

        Stop-Stack -Purge -InformationAction SilentlyContinue | Should -Be 0
        Should -Invoke Invoke-StackCommand -Times 4 -ParameterFilter { ($Arguments -join ' ') -match 'down --remove-orphans -v$' }
        Test-Path -LiteralPath $history | Should -BeFalse
    }

    It 'keeps going and reports a count when a step fails' {
        Mock Invoke-StackCommand { 1 } -ParameterFilter { $Arguments -contains 'sksvc-dev' }
        Stop-Stack | Should -Be 1
        Should -Invoke Invoke-StackCommand -Times 1 -ParameterFilter { $Arguments -contains 'sksvc-data' }
    }
}

Describe 'Get-HistoryFolder' {
    It 'uses RELEASEGUARD_HOME when set' {
        $saved = $env:RELEASEGUARD_HOME
        try {
            $env:RELEASEGUARD_HOME = Join-Path -Path $TestDrive -ChildPath 'custom'
            Get-HistoryFolder | Should -Be (Join-Path -Path $TestDrive -ChildPath 'custom' -AdditionalChildPath 'history')
        } finally {
            $env:RELEASEGUARD_HOME = $saved
        }
    }
}
