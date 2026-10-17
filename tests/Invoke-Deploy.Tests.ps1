BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseGuard.TestHelpers.ps1')
    # Dot-source to get the functions without running the main block. The mandatory
    # parameters need values, but they are not used by the tests.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Invoke-Deploy.ps1') -Environment 'dev' -ImageTag 'unused'

    $script:oldHome = $env:RELEASEGUARD_HOME
    $script:tempHome = Initialize-TempFolder
    $env:RELEASEGUARD_HOME = $script:tempHome
}

AfterAll {
    $env:RELEASEGUARD_HOME = $script:oldHome
    Remove-TempFolder -Path $script:tempHome
}

Describe 'Invoke-Deployment' {
    BeforeEach {
        Remove-Item -Path (Join-Path -Path $script:tempHome -ChildPath 'history') -Recurse -Force -ErrorAction SilentlyContinue

        # Record the order of the steps to prove migrations run before compose.
        $script:steps = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MigrationScript { $script:steps.Add("migrate $Environment") }
        Mock Invoke-DockerCommand {
            $script:steps.Add("docker $($Arguments -join ' ') IMAGE_TAG=$env:IMAGE_TAG FAIL_RATE=$env:FAIL_RATE")
            [pscustomobject] @{ ExitCode = 0; Output = '' }
        }
        Mock Invoke-RestMethod { [pscustomobject] @{ status = 'ok'; secret_loaded = $true } }
        Mock Start-Sleep { }
    }

    It 'runs migrations first, then compose up for the environment' {
        Invoke-Deployment -Environment 'dev' -ImageTag 'sha1' -FailRate 0.25 -ComposeFile 'compose.yml' | Out-Null
        $script:steps.Count | Should -Be 2
        $script:steps[0] | Should -Be 'migrate dev'
        $script:steps[1] | Should -Be 'docker compose -f compose.yml -p sksvc-dev --profile dev up -d --no-build app-dev IMAGE_TAG=sha1 FAIL_RATE=0.25'
    }

    It 'waits for /healthz on the environment port' {
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml' | Out-Null
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -eq 'http://127.0.0.1:7312/healthz' }
    }

    It 'appends a deployed entry to the history' {
        $result = Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml'
        $result.Recorded | Should -BeTrue
        $entries = Read-DeployHistory -Environment 'prod'
        $entries.Count | Should -Be 1
        $entries[0].tag | Should -Be 'sha1'
        $entries[0].status | Should -Be 'deployed'
    }

    It 'does not add a duplicate entry when the same tag is deployed again' {
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml' | Out-Null
        $second = Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml'
        $second.Recorded | Should -BeFalse
        (Read-DeployHistory -Environment 'prod').Count | Should -Be 1
    }

    It 'adds a new entry for a different tag' {
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml' | Out-Null
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha2' -ComposeFile 'compose.yml' | Out-Null
        (Read-DeployHistory -Environment 'prod').tag | Should -Be @('sha1', 'sha2')
    }

    It 'records the FAIL_RATE with the entry' {
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -FailRate 0.5 -ComposeFile 'compose.yml' | Out-Null
        (Read-DeployHistory -Environment 'prod')[0].failRate | Should -Be 0.5
    }

    It 'adds a new entry when the same tag is deployed with another FAIL_RATE' {
        Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml' | Out-Null
        $second = Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -FailRate 1 -ComposeFile 'compose.yml'
        $second.Recorded | Should -BeTrue
        $entries = Read-DeployHistory -Environment 'prod'
        $entries.tag | Should -Be @('sha1', 'sha1')
        $entries.failRate | Should -Be @(0, 1)
    }

    It 'treats an old entry without failRate as FAIL_RATE 0' {
        Write-DeployHistory -Environment 'prod' -Entries @([pscustomobject] @{
                tag = 'sha1'; deployedAtUtc = '2026-01-01T00:00:00Z'; status = 'deployed'; rolledBackFrom = $null })
        (Invoke-Deployment -Environment 'prod' -ImageTag 'sha1' -ComposeFile 'compose.yml').Recorded | Should -BeFalse
    }

    It 'records a failed entry when docker compose fails' {
        Mock Invoke-DockerCommand { [pscustomobject] @{ ExitCode = 1; Output = 'No such image' } }
        { Invoke-Deployment -Environment 'dev' -ImageTag 'sha1' -ComposeFile 'compose.yml' } |
            Should -Throw -ErrorId 'ReleaseGuard.ComposeFailed*'
        $entries = Read-DeployHistory -Environment 'dev'
        $entries.Count | Should -Be 1
        $entries[0].status | Should -Be 'failed'
    }

    It 'stops before compose when migrations fail' {
        Mock Invoke-MigrationScript { throw 'migration 002 failed' }
        { Invoke-Deployment -Environment 'dev' -ImageTag 'sha1' -ComposeFile 'compose.yml' } | Should -Throw '*migration 002 failed*'
        Should -Invoke Invoke-DockerCommand -Times 0 -Exactly
        (Read-DeployHistory -Environment 'dev').Count | Should -Be 0
    }

    It 'records a failed entry and throws ReleaseGuard.HealthCheckTimeout when /healthz never gets ok' {
        Mock Invoke-RestMethod { throw 'connection refused' }
        { Invoke-Deployment -Environment 'dev' -ImageTag 'sha1' -ComposeFile 'compose.yml' -TimeoutSeconds 4 } |
            Should -Throw -ErrorId 'ReleaseGuard.HealthCheckTimeout*'
        $entries = Read-DeployHistory -Environment 'dev'
        $entries[-1].status | Should -Be 'failed'
    }
}

Describe 'Invoke-MigrationScript' {
    BeforeAll {
        $script:fakeScripts = Initialize-TempFolder
    }
    AfterAll {
        Remove-TempFolder -Path $script:fakeScripts
    }

    It 'passes -Environment to the migrations script' {
        $fake = Join-Path -Path $script:fakeScripts -ChildPath 'ok.ps1'
        $marker = Join-Path -Path $script:fakeScripts -ChildPath 'ran.txt'
        Set-Content -Path $fake -Value "param(`$Environment) Set-Content -Path '$marker' -Value `$Environment; exit 0"
        Invoke-MigrationScript -Environment 'prod' -ScriptPath $fake
        Get-Content -Path $marker | Should -Be 'prod'
    }

    It 'throws ReleaseGuard.MigrationsFailed when the migrations script exits non-zero' {
        $fake = Join-Path -Path $script:fakeScripts -ChildPath 'fail.ps1'
        Set-Content -Path $fake -Value 'param($Environment) exit 3'
        { Invoke-MigrationScript -Environment 'dev' -ScriptPath $fake } | Should -Throw -ErrorId 'ReleaseGuard.MigrationsFailed*'
    }
}

Describe 'Invoke-Deploy.ps1 exit codes' {
    It 'exits 2 when migrations fail, so the pipeline skips the rollback' {
        Remove-Item -Path (Join-Path -Path $script:tempHome -ChildPath 'history') -Recurse -Force -ErrorAction SilentlyContinue
        # No password file: Invoke-Migrations.ps1 fails before it touches Docker.
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Invoke-Deploy.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $oldSecret = $env:SKSVC_DB_PASSWORD_FILE
        try {
            $env:SKSVC_DB_PASSWORD_FILE = Join-Path -Path $script:tempHome -ChildPath 'no-such-password-file'
            & $pwsh -NoProfile -NonInteractive -File $scriptPath -Environment 'dev' -ImageTag 'sha1' 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 2
        } finally {
            $env:SKSVC_DB_PASSWORD_FILE = $oldSecret
        }
        (Read-DeployHistory -Environment 'dev').Count | Should -Be 0
    }
}
