BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseGuard.TestHelpers.ps1')
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard'
    Import-Module $modulePath -Force

    $repo = Initialize-GitFixture
    $script:firstSha = Add-FixtureCommit -RepoPath $repo -Message 'Bootstrap repo'
    $script:releaseA = Add-FixtureCommit -RepoPath $repo -Message 'Add login page (#1)'
    Add-FixtureCommit -RepoPath $repo -Message 'Quick fix | pushed directly' | Out-Null
    $script:releaseB = Add-FixtureCommit -RepoPath $repo -Message 'Add metrics (#2)'
    $script:outDir = Join-Path -Path (Initialize-TempFolder) -ChildPath 'audit'
}

AfterAll {
    Remove-TempFolder -Path $repo
    Remove-TempFolder -Path (Split-Path -Path $script:outDir -Parent)
    Remove-Module ReleaseGuard -ErrorAction SilentlyContinue
}

Describe 'New-ReleaseAudit' {
    It 'lists only the commits after -From, newest first, with PR numbers' {
        $audit = New-ReleaseAudit -RepoPath $repo -From $script:releaseA -To $script:releaseB -OutputDir $script:outDir
        $audit.CommitCount | Should -Be 2
        $audit.Commits[0].Sha | Should -Be $script:releaseB
        $audit.Commits[0].PrNumber | Should -Be 2
        $audit.Commits[0].Author | Should -Be 'Test User'
        $audit.Commits[1].PrNumber | Should -BeNullOrEmpty
    }

    It 'writes release-audit-SHA.md and .json with image tag and checks' {
        $audit = New-ReleaseAudit -RepoPath $repo -From $script:releaseA -To $script:releaseB -OutputDir $script:outDir `
            -ImageTag "sk-svc:$($script:releaseB)" -ChecksPassed 'lint', 'test', 'trivy'
        $audit.JsonPath | Should -Be (Join-Path -Path $script:outDir -ChildPath "release-audit-$($script:releaseB).json")
        $audit.JsonPath | Should -Exist
        $audit.MarkdownPath | Should -Exist

        $json = Get-Content -Path $audit.JsonPath -Raw | ConvertFrom-Json
        $json.ImageTag | Should -Be "sk-svc:$($script:releaseB)"
        $json.ChecksPassed | Should -Be @('lint', 'test', 'trivy')
        $json.Commits.Count | Should -Be 2

        $markdown = Get-Content -Path $audit.MarkdownPath -Raw
        $markdown | Should -Match 'Checks passed: lint, test, trivy'
        $markdown | Should -Match '\| #2 \| Add metrics \(#2\) \|'
        # The "|" in the subject is escaped so the table stays intact.
        $markdown | Should -Match 'Quick fix \\\| pushed directly'
    }

    It 'starts at the first commit when -From is not given' {
        $audit = New-ReleaseAudit -RepoPath $repo -To $script:releaseB -OutputDir $script:outDir
        $audit.CommitCount | Should -Be 4
        $audit.Commits[-1].Sha | Should -Be $script:firstSha
        $audit.From | Should -BeNullOrEmpty
        Get-Content -Path $audit.MarkdownPath -Raw | Should -Match 'From: \(first commit\)'
    }

    It 'accepts refs like HEAD and names the files by the full SHA' {
        $audit = New-ReleaseAudit -RepoPath $repo -From 'HEAD~1' -To 'HEAD' -OutputDir $script:outDir
        $audit.To | Should -Be $script:releaseB
        $audit.CommitCount | Should -Be 1
    }

    It 'returns an empty commit list when From equals To' {
        $audit = New-ReleaseAudit -RepoPath $repo -From $script:releaseB -To $script:releaseB -OutputDir $script:outDir
        $audit.CommitCount | Should -Be 0
    }

    It 'throws ReleaseGuard.UnknownRef for a ref that does not exist' {
        { New-ReleaseAudit -RepoPath $repo -To 'no-such-ref' -OutputDir $script:outDir } |
            Should -Throw -ErrorId 'ReleaseGuard.UnknownRef*'
    }

    It 'writes nothing with -WhatIf' {
        $whatIfDir = Join-Path -Path $script:outDir -ChildPath 'whatif'
        New-ReleaseAudit -RepoPath $repo -To $script:releaseB -OutputDir $whatIfDir -WhatIf | Out-Null
        $whatIfDir | Should -Not -Exist
    }
}
