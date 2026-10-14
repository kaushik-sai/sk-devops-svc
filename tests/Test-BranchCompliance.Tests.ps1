BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseGuard.TestHelpers.ps1')
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard'
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module ReleaseGuard -ErrorAction SilentlyContinue
}

Describe 'Test-BranchCompliance: branch names' {
    BeforeAll {
        $repo = Initialize-GitFixture
        Add-FixtureCommit -RepoPath $repo -Message 'Initial commit' | Out-Null
        # No baseline tag here, so only branch names are checked.
        git -C $repo branch feature/login
        git -C $repo branch release/1.0
    }
    AfterAll { Remove-TempFolder -Path $repo }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'main' }
        @{ Name = 'feature/login-page' }
        @{ Name = 'release/1.2.0' }
        @{ Name = 'feature/fix_bug.2' }
        @{ Name = 'refs/heads/feature/login' }
    ) {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName $Name -NoThrow -InformationAction Ignore -WarningAction SilentlyContinue
        $result.Compliant | Should -BeTrue
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'bugfix/login' }
        @{ Name = 'feature/Login' }
        @{ Name = 'feature/' }
        @{ Name = 'feature/a/b' }
        @{ Name = 'hotfix' }
        @{ Name = 'refs/heads/dev' }
    ) {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName $Name -NoThrow -InformationAction Ignore -WarningAction SilentlyContinue
        $result.Compliant | Should -BeFalse
        $result.BranchViolations.Count | Should -Be 1
    }

    It 'strips refs/heads/ before reporting the branch' {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName 'refs/heads/Bad' -NoThrow -InformationAction Ignore -WarningAction SilentlyContinue
        $result.BranchViolations | Should -Be @('Bad')
    }

    It 'checks all local branches when -BranchName is not given' {
        git -C $repo branch Not-Allowed
        try {
            $result = Test-BranchCompliance -RepoPath $repo -NoThrow -InformationAction Ignore -WarningAction SilentlyContinue
            $result.BranchesChecked | Should -Contain 'feature/login'
            $result.BranchesChecked | Should -Contain 'release/1.0'
            $result.BranchViolations | Should -Be @('Not-Allowed')
        } finally {
            git -C $repo branch -D Not-Allowed --quiet
        }
    }

    It 'throws ReleaseGuard.PolicyViolation without -NoThrow' {
        { Test-BranchCompliance -RepoPath $repo -BranchName 'bad' -InformationAction Ignore -WarningAction SilentlyContinue } |
            Should -Throw -ErrorId 'ReleaseGuard.PolicyViolation*'
    }

    It 'throws ReleaseGuard.PolicyNotFound for a missing policy file' {
        { Test-BranchCompliance -RepoPath $repo -PolicyPath (Join-Path -Path $repo -ChildPath 'nope.json') } |
            Should -Throw -ErrorId 'ReleaseGuard.PolicyNotFound*'
    }
}

Describe 'Test-BranchCompliance: commits on main' {
    BeforeAll {
        $repo = Initialize-GitFixture
        # Bootstrap commits pushed directly, before the baseline: exempt.
        Add-FixtureCommit -RepoPath $repo -Message 'Bootstrap repo' | Out-Null
        Add-FixtureCommit -RepoPath $repo -Message 'Add checklist' | Out-Null
        git -C $repo tag governance-baseline
        Add-FixtureCommit -RepoPath $repo -Message 'Add login page (#1)' | Out-Null
        $script:directSha = Add-FixtureCommit -RepoPath $repo -Message 'Quick fix pushed directly'
        Add-FixtureCommit -RepoPath $repo -Message 'Add metrics (#2)' | Out-Null
    }
    AfterAll { Remove-TempFolder -Path $repo }

    It 'flags only the commit after the baseline that has no PR number' {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName 'main' -NoThrow -InformationAction Ignore
        $result.CommitsChecked | Should -BeTrue
        $result.CommitViolations.Count | Should -Be 1
        $result.CommitViolations[0].Sha | Should -Be $script:directSha
        $result.CommitViolations[0].Subject | Should -Be 'Quick fix pushed directly'
    }

    It 'passes when -Since starts after the bad commit' {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName 'main' -Since $script:directSha -NoThrow -InformationAction Ignore
        $result.Compliant | Should -BeTrue
    }

    It 'only follows the first parent of main (commits inside a merged branch are not checked)' {
        $repo2 = Initialize-GitFixture
        try {
            Add-FixtureCommit -RepoPath $repo2 -Message 'Bootstrap' | Out-Null
            git -C $repo2 tag governance-baseline
            git -C $repo2 checkout --quiet -b feature/x
            Add-FixtureCommit -RepoPath $repo2 -Message 'wip without PR number' | Out-Null
            git -C $repo2 checkout --quiet main
            git -C $repo2 merge --quiet --no-ff feature/x -m 'Merge feature/x (#3)'
            $result = Test-BranchCompliance -RepoPath $repo2 -BranchName 'main' -NoThrow -InformationAction Ignore
            $result.Compliant | Should -BeTrue
        } finally {
            Remove-TempFolder -Path $repo2
        }
    }

    It 'warns and skips the commit check when the baseline tag is missing' {
        $result = Test-BranchCompliance -RepoPath $repo -BranchName 'main' -Since 'no-such-tag' -NoThrow `
            -InformationAction Ignore -WarningVariable warnings -WarningAction SilentlyContinue
        $result.CommitsChecked | Should -BeFalse
        $result.Compliant | Should -BeTrue
        $warnings | Should -Match 'NOT checked'
    }

    It 'makes "pwsh -Command" exit non-zero on violations (what the pipeline relies on)' {
        $pwsh = (Get-Process -Id $PID).Path
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard'
        $command = "Import-Module '$modulePath'; Test-BranchCompliance -RepoPath '$repo' -BranchName 'refs/heads/feature/ok'"
        & $pwsh -NoProfile -NonInteractive -Command $command *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'makes "pwsh -Command" exit zero when compliant' {
        $pwsh = (Get-Process -Id $PID).Path
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard'
        $command = "Import-Module '$modulePath'; Test-BranchCompliance -RepoPath '$repo' -BranchName 'feature/ok' -Since '$script:directSha'"
        & $pwsh -NoProfile -NonInteractive -Command $command *> $null
        $LASTEXITCODE | Should -Be 0
    }
}
