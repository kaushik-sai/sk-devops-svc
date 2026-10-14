BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseGuard.TestHelpers.ps1')
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard'
    Import-Module $modulePath -Force
    # History helpers, used here to seed and read the history file.
    . (Join-Path -Path $modulePath -ChildPath 'Private' -AdditionalChildPath 'History.ps1')

    $script:oldHome = $env:RELEASEGUARD_HOME
    $script:tempHome = Initialize-TempFolder
    $env:RELEASEGUARD_HOME = $script:tempHome
}

AfterAll {
    $env:RELEASEGUARD_HOME = $script:oldHome
    Remove-TempFolder -Path $script:tempHome
    Remove-Module ReleaseGuard -ErrorAction SilentlyContinue
}

Describe 'Invoke-Rollback' {
    BeforeEach {
        Remove-Item -Path (Join-Path -Path $script:tempHome -ChildPath 'history') -Recurse -Force -ErrorAction SilentlyContinue

        # Fake Docker: "docker info" and "compose up" succeed. The fake app then
        # reports whatever IMAGE_TAG Compose was started with on /version.
        $script:runningTag = 'tag-b'
        Mock -ModuleName ReleaseGuard Invoke-DockerCommand {
            if ($Arguments[0] -eq 'compose') {
                $script:runningTag = $env:IMAGE_TAG
                $script:composeFailRate = $env:FAIL_RATE
            }
            [pscustomobject] @{ ExitCode = 0; Output = '' }
        }
        Mock -ModuleName ReleaseGuard Invoke-RestMethod { [pscustomobject] @{ version = $script:runningTag } }
        Mock -ModuleName ReleaseGuard Start-Sleep { }
    }

    Context 'with tag-a then tag-b deployed' {
        BeforeEach {
            Add-DeployHistoryEntry -Environment 'prod' -Tag 'tag-a' -Status 'deployed' | Out-Null
            Add-DeployHistoryEntry -Environment 'prod' -Tag 'tag-b' -Status 'deployed' | Out-Null
        }

        It 'redeploys the previous tag with FAIL_RATE=0 on the prod project' {
            $result = Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationAction Ignore
            $result.Action | Should -Be 'RolledBack'
            $result.FromTag | Should -Be 'tag-b'
            $result.ToTag | Should -Be 'tag-a'
            $script:runningTag | Should -Be 'tag-a'
            $script:composeFailRate | Should -Be '0'
            Should -Invoke -ModuleName ReleaseGuard Invoke-DockerCommand -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -eq 'compose -f compose.yml -p sksvc-prod --profile prod up -d --no-build app-prod'
            }
        }

        It 'polls /version on the prod port' {
            Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationAction Ignore | Out-Null
            Should -Invoke -ModuleName ReleaseGuard Invoke-RestMethod -ParameterFilter { $Uri -eq 'http://127.0.0.1:7312/version' }
        }

        It 'marks the bad release rolled_back and records the rollback' {
            Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationAction Ignore | Out-Null
            $entries = Read-DeployHistory -Environment 'prod'
            $entries.Count | Should -Be 3
            $entries[1].tag | Should -Be 'tag-b'
            $entries[1].status | Should -Be 'rolled_back'
            $entries[2].tag | Should -Be 'tag-a'
            $entries[2].status | Should -Be 'deployed'
            $entries[2].rolledBackFrom | Should -Be 'tag-b'
        }

        It 'is a no-op the second time ("already rolled back")' {
            Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationAction Ignore | Out-Null
            $second = Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationVariable info -InformationAction Ignore
            $second.Action | Should -Be 'AlreadyRolledBack'
            $second.ToTag | Should -Be 'tag-a'
            ($info -join ' ') | Should -Match 'Already rolled back'
            # Only the first run called compose; history did not grow.
            Should -Invoke -ModuleName ReleaseGuard Invoke-DockerCommand -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'compose' }
            (Read-DeployHistory -Environment 'prod').Count | Should -Be 3
        }

        It 'throws ReleaseGuard.DockerNotRunning when docker info fails, and leaves history alone' {
            Mock -ModuleName ReleaseGuard Invoke-DockerCommand { [pscustomobject] @{ ExitCode = 1; Output = 'daemon not running' } }
            { Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -InformationAction Ignore } |
                Should -Throw -ErrorId 'ReleaseGuard.DockerNotRunning*'
            (Read-DeployHistory -Environment 'prod').status | Should -Be @('deployed', 'deployed')
        }

        It 'throws ReleaseGuard.HealthCheckTimeout when /version never shows the target, and leaves history alone' {
            Mock -ModuleName ReleaseGuard Invoke-RestMethod { [pscustomobject] @{ version = 'tag-b' } }
            { Invoke-Rollback -Environment 'prod' -ComposeFile 'compose.yml' -TimeoutSeconds 4 -InformationAction Ignore } |
                Should -Throw -ErrorId 'ReleaseGuard.HealthCheckTimeout*'
            (Read-DeployHistory -Environment 'prod').status | Should -Be @('deployed', 'deployed')
        }
    }

    It 'throws ReleaseGuard.NoPreviousRelease when there is no history' {
        { Invoke-Rollback -Environment 'dev' -ComposeFile 'compose.yml' -InformationAction Ignore } |
            Should -Throw -ErrorId 'ReleaseGuard.NoPreviousRelease*'
    }

    It 'throws ReleaseGuard.NoPreviousRelease when only one release was deployed' {
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-a' -Status 'deployed' | Out-Null
        { Invoke-Rollback -Environment 'dev' -ComposeFile 'compose.yml' -InformationAction Ignore } |
            Should -Throw -ErrorId 'ReleaseGuard.NoPreviousRelease*'
        Should -Invoke -ModuleName ReleaseGuard Invoke-DockerCommand -Times 0 -Exactly
    }

    It 'skips failed and rolled_back entries when choosing the target' {
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-a' -Status 'deployed' | Out-Null
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-x' -Status 'rolled_back' | Out-Null
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-y' -Status 'failed' | Out-Null
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-b' -Status 'deployed' | Out-Null
        $result = Invoke-Rollback -Environment 'dev' -ComposeFile 'compose.yml' -InformationAction Ignore
        $result.ToTag | Should -Be 'tag-a'
    }

    It 'rolls back a failed deploy to the last good release' {
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-a' -Status 'deployed' | Out-Null
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'tag-c' -Status 'failed' | Out-Null
        $result = Invoke-Rollback -Environment 'dev' -ComposeFile 'compose.yml' -InformationAction Ignore
        $result.FromTag | Should -Be 'tag-c'
        $result.ToTag | Should -Be 'tag-a'
        (Read-DeployHistory -Environment 'dev')[1].status | Should -Be 'rolled_back'
    }
}

Describe 'ReleaseGuard module surface' {
    It 'exports exactly the three public commands' {
        $commands = (Get-Command -Module ReleaseGuard).Name | Sort-Object
        $commands | Should -Be @('Invoke-Rollback', 'New-ReleaseAudit', 'Test-BranchCompliance')
    }

    It '<_> has synopsis, description, parameter help and examples' -ForEach @('Test-BranchCompliance', 'New-ReleaseAudit', 'Invoke-Rollback') {
        $help = Get-Help -Name $_ -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
        # -WhatIf and -Confirm come from SupportsShouldProcess and have no help of their own.
        $ownParameters = $help.Parameters.Parameter | Where-Object { $_.Name -notin 'WhatIf', 'Confirm' }
        foreach ($parameter in $ownParameters) {
            $parameter.Description | Should -Not -BeNullOrEmpty -Because "-$($parameter.Name) needs help text"
        }
    }
}
