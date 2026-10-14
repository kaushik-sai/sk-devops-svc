BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseGuard.TestHelpers.ps1')
    $privatePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'modules', 'ReleaseGuard', 'Private'
    # Dot-source the private files directly, the same way scripts/Invoke-Deploy.ps1 does.
    . (Join-Path -Path $privatePath -ChildPath 'History.ps1')
    . (Join-Path -Path $privatePath -ChildPath 'Deployment.ps1')

    # Point the history at a temp folder so tests never touch the real $HOME/.releaseguard.
    $script:oldHome = $env:RELEASEGUARD_HOME
    $script:tempHome = Initialize-TempFolder
    $env:RELEASEGUARD_HOME = $script:tempHome
}

AfterAll {
    $env:RELEASEGUARD_HOME = $script:oldHome
    Remove-TempFolder -Path $script:tempHome
}

Describe 'Deploy history helpers' {
    BeforeEach {
        Remove-Item -Path (Join-Path -Path $script:tempHome -ChildPath 'history') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'puts the file under RELEASEGUARD_HOME/history/prod.json' {
        Get-DeployHistoryPath -Environment 'prod' |
            Should -Be (Join-Path -Path $script:tempHome -ChildPath 'history' -AdditionalChildPath 'prod.json')
    }

    It 'defaults to $HOME/.releaseguard when RELEASEGUARD_HOME is not set' {
        $env:RELEASEGUARD_HOME = $null
        try {
            Get-DeployHistoryPath -Environment 'dev' |
                Should -Be (Join-Path -Path $HOME -ChildPath '.releaseguard' -AdditionalChildPath 'history', 'dev.json')
        } finally {
            $env:RELEASEGUARD_HOME = $script:tempHome
        }
    }

    It 'returns an empty array when there is no history yet' {
        $entries = Read-DeployHistory -Environment 'dev'
        $entries.GetType().IsArray | Should -BeTrue
        $entries.Count | Should -Be 0
    }

    It 'keeps a one-entry history as a JSON array' {
        Add-DeployHistoryEntry -Environment 'dev' -Tag 'aaa' -Status 'deployed' | Out-Null
        $raw = Get-Content -Path (Get-DeployHistoryPath -Environment 'dev') -Raw
        $raw.TrimStart() | Should -Match '^\['
        $entries = Read-DeployHistory -Environment 'dev'
        $entries.Count | Should -Be 1
        $entries[0].tag | Should -Be 'aaa'
        $entries[0].status | Should -Be 'deployed'
        $entries[0].rolledBackFrom | Should -BeNullOrEmpty
    }

    It 'appends entries in order and keeps environments separate' {
        Add-DeployHistoryEntry -Environment 'prod' -Tag 'aaa' -Status 'deployed' | Out-Null
        Add-DeployHistoryEntry -Environment 'prod' -Tag 'bbb' -Status 'failed' | Out-Null
        $entries = Read-DeployHistory -Environment 'prod'
        $entries.tag | Should -Be @('aaa', 'bbb')
        (Read-DeployHistory -Environment 'dev').Count | Should -Be 0
    }
}

Describe 'Invoke-ComposeUp' {
    BeforeEach {
        $script:seen = @{}
        Mock Invoke-DockerCommand {
            # Record what Compose would have seen in the environment during the call.
            $script:seen.ImageTag = $env:IMAGE_TAG
            $script:seen.FailRate = $env:FAIL_RATE
            [pscustomobject] @{ ExitCode = 0; Output = '' }
        }
    }

    It 'runs docker compose for one environment with the right project, profile and service' {
        Invoke-ComposeUp -Environment 'prod' -ImageTag 'abc' -ComposeFile 'compose.yml'
        Should -Invoke Invoke-DockerCommand -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq 'compose -f compose.yml -p sksvc-prod --profile prod up -d --no-build app-prod'
        }
    }

    It 'sets IMAGE_TAG and FAIL_RATE only for the call, then restores them' {
        $env:IMAGE_TAG = 'before'
        $env:FAIL_RATE = $null
        try {
            Invoke-ComposeUp -Environment 'dev' -ImageTag 'abc' -FailRate 0.5 -ComposeFile 'compose.yml'
            $script:seen.ImageTag | Should -Be 'abc'
            $script:seen.FailRate | Should -Be '0.5'
            $env:IMAGE_TAG | Should -Be 'before'
            $env:FAIL_RATE | Should -BeNullOrEmpty
        } finally {
            $env:IMAGE_TAG = $null
        }
    }

    It 'throws ReleaseGuard.ComposeFailed when compose fails' {
        Mock Invoke-DockerCommand { [pscustomobject] @{ ExitCode = 1; Output = 'no such image' } }
        { Invoke-ComposeUp -Environment 'dev' -ImageTag 'abc' -ComposeFile 'compose.yml' } |
            Should -Throw -ErrorId 'ReleaseGuard.ComposeFailed*'
    }

    It 'defaults to docker-compose.yml at the repo root' {
        $expected = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'docker-compose.yml'
        [System.IO.Path]::GetFullPath((Get-DefaultComposeFile)) | Should -Be ([System.IO.Path]::GetFullPath($expected))
    }
}

Describe 'Wait-EndpointValue' {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'returns true as soon as the property matches' {
        Mock Invoke-RestMethod { [pscustomobject] @{ version = 'abc' } }
        Wait-EndpointValue -Url 'http://x/version' -Property 'version' -ExpectedValue 'abc' -TimeoutSeconds 10 | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'keeps polling through connection errors' {
        $script:calls = 0
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 3) { throw 'connection refused' }
            [pscustomobject] @{ status = 'ok' }
        }
        Wait-EndpointValue -Url 'http://x/healthz' -Property 'status' -ExpectedValue 'ok' -TimeoutSeconds 10 | Should -BeTrue
        $script:calls | Should -Be 3
    }

    It 'returns false after TimeoutSeconds / IntervalSeconds attempts' {
        Mock Invoke-RestMethod { [pscustomobject] @{ version = 'old' } }
        Wait-EndpointValue -Url 'http://x/version' -Property 'version' -ExpectedValue 'new' -TimeoutSeconds 10 -IntervalSeconds 2 |
            Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 5 -Exactly
    }
}

Describe 'Test-DockerRunning' {
    It 'is true when docker info succeeds' {
        Mock Invoke-DockerCommand { [pscustomobject] @{ ExitCode = 0; Output = '' } }
        Test-DockerRunning | Should -BeTrue
        Should -Invoke Invoke-DockerCommand -ParameterFilter { $Arguments[0] -eq 'info' }
    }

    It 'is false when docker info fails' {
        Mock Invoke-DockerCommand { [pscustomobject] @{ ExitCode = 1; Output = 'Cannot connect to the Docker daemon' } }
        Test-DockerRunning | Should -BeFalse
    }
}
