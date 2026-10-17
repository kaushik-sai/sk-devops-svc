BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Remove-OldImages.ps1')

    # What the docker wrapper returns: an exit code and the output lines.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string[]] $Output = @())
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }

    # Writes a history file with these tags, all "deployed", oldest first.
    function Write-FakeHistory {
        param([string] $Environment, [string[]] $Tags, [string] $LastStatus = 'deployed')
        $entries = for ($i = 0; $i -lt $Tags.Count; $i++) {
            $status = if ($i -eq $Tags.Count - 1) { $LastStatus } else { 'deployed' }
            [pscustomobject] @{ tag = $Tags[$i]; deployedAtUtc = '2026-10-14T00:00:00Z'; status = $status; rolledBackFrom = $null }
        }
        Write-DeployHistory -Environment $Environment -Entries @($entries)
    }
}

Describe 'Remove-OldImage' {
    BeforeEach {
        $script:savedHome = $env:RELEASEGUARD_HOME
        $env:RELEASEGUARD_HOME = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        Mock Invoke-ImageCommand { Get-FakeResult -Output @() } -ParameterFilter { $Arguments[0] -eq 'ps' }
        Mock Invoke-ImageCommand { Get-FakeResult } -ParameterFilter { $Arguments[1] -eq 'rm' }
    }
    AfterEach {
        $env:RELEASEGUARD_HOME = $script:savedHome
    }

    It 'keeps the last N deployed releases of each environment and removes the rest' {
        Write-FakeHistory -Environment 'prod' -Tags @('p1', 'p2', 'p3', 'p4')
        Write-FakeHistory -Environment 'dev' -Tags @('d1', 'p4')
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('p1', 'p2', 'p3', 'p4', 'd1', 'old') } -ParameterFilter { $Arguments[1] -eq 'ls' }

        $result = Remove-OldImage -Keep 2
        $result.Removed | Sort-Object | Should -Be @('old', 'p1', 'p2')
        $result.Kept | Sort-Object | Should -Be @('d1', 'p3', 'p4')
        Should -Invoke Invoke-ImageCommand -Times 0 -ParameterFilter { $Arguments[1] -eq 'rm' -and $Arguments[2] -eq 'sk-svc:p3' }
    }

    It 'never removes the previous release, so a rollback still has its image' {
        # prod: A deployed, then B deployed. Rollback from B needs A.
        Write-FakeHistory -Environment 'prod' -Tags @('A', 'B')
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('A', 'B') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        (Remove-OldImage -Keep 2).Removed | Should -BeNullOrEmpty
    }

    It 'keeps images used by any container even if not in the history' {
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('manual') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('sk-svc:manual', 'postgres:16-alpine') } -ParameterFilter { $Arguments[0] -eq 'ps' }
        (Remove-OldImage -Keep 3).Kept | Should -Be @('manual')
    }

    It 'does not count failed releases as keepers' {
        Write-FakeHistory -Environment 'prod' -Tags @('good', 'bad') -LastStatus 'failed'
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('good', 'bad') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        (Remove-OldImage -Keep 2).Removed | Should -Be @('bad')
    }

    It 'counts distinct tags, so a repeated tag does not push out the rollback target' {
        # prod: A, then B, then B again (for example with another FAIL_RATE). Rollback needs A.
        Write-FakeHistory -Environment 'prod' -Tags @('old', 'A', 'B', 'B')
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('old', 'A', 'B') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        (Remove-OldImage -Keep 2).Removed | Should -Be @('old')
    }

    It 'refuses -Keep 1, which would delete the rollback target' {
        { Remove-OldImage -Keep 1 } | Should -Throw
    }

    It 'removes nothing with -WhatIf' {
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('old') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        Remove-OldImage -Keep 3 -WhatIf | Out-Null
        Should -Invoke Invoke-ImageCommand -Times 0 -ParameterFilter { $Arguments[1] -eq 'rm' }
    }

    It 'warns and carries on when an image cannot be removed' {
        Mock Invoke-ImageCommand { Get-FakeResult -Output @('x', 'y') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        Mock Invoke-ImageCommand { Get-FakeResult -ExitCode 1 -Output @('in use') } -ParameterFilter { $Arguments[2] -eq 'sk-svc:x' }
        $result = Remove-OldImage -Keep 3 -WarningAction SilentlyContinue
        $result.Removed | Should -Be @('y')
    }

    It 'fails clearly when Docker cannot list images' {
        Mock Invoke-ImageCommand { Get-FakeResult -ExitCode 1 -Output @('daemon down') } -ParameterFilter { $Arguments[1] -eq 'ls' }
        { Remove-OldImage -Keep 3 } | Should -Throw '*Docker running*'
    }
}
