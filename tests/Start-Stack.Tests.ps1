BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Start-Stack.ps1')
}

Describe 'New-RandomSecret' {
    It 'returns letters and digits of the requested length' {
        $secret = New-RandomSecret -Length 32
        $secret.Length | Should -Be 32
        $secret | Should -Match '^[A-Za-z0-9]+$'
    }

    It 'returns a different value each time' {
        New-RandomSecret | Should -Not -Be (New-RandomSecret)
    }

    It 'refuses passwords shorter than 24 characters' {
        { New-RandomSecret -Length 10 } | Should -Throw
    }
}

Describe 'Initialize-SecretFile' {
    It 'creates the folder and a 32-character password with no newline' {
        $path = Join-Path -Path $TestDrive -ChildPath '.secrets' -AdditionalChildPath 'db_password'
        Initialize-SecretFile -Path $path -InformationAction SilentlyContinue | Out-Null
        $content = Get-Content -LiteralPath $path -Raw
        $content.Length | Should -Be 32
        $content | Should -Not -Match "`n"
    }

    It 'creates the password file readable by its owner only on Linux and macOS' -Skip:$IsWindows {
        $path = Join-Path -Path $TestDrive -ChildPath 'private' -AdditionalChildPath 'db_password'
        Initialize-SecretFile -Path $path -InformationAction SilentlyContinue | Out-Null
        [System.IO.File]::GetUnixFileMode($path) | Should -Be ([System.IO.UnixFileMode] 'UserRead, UserWrite')
    }

    It 'keeps an existing password' {
        $path = Join-Path -Path $TestDrive -ChildPath 'existing'
        Set-Content -LiteralPath $path -Value 'keep-me' -NoNewline
        Initialize-SecretFile -Path $path -InformationAction SilentlyContinue | Out-Null
        Get-Content -LiteralPath $path -Raw | Should -Be 'keep-me'
    }
}

Describe 'Get-SecretFilePath' {
    BeforeEach { $script:saved = $env:SKSVC_DB_PASSWORD_FILE }
    AfterEach { $env:SKSVC_DB_PASSWORD_FILE = $script:saved }

    It 'uses SKSVC_DB_PASSWORD_FILE when set (shared location on the agent machine)' {
        $env:SKSVC_DB_PASSWORD_FILE = Join-Path -Path $TestDrive -ChildPath 'shared'
        Get-SecretFilePath | Should -Be (Join-Path -Path $TestDrive -ChildPath 'shared')
    }

    It 'falls back to .secrets/db_password in the repo' {
        $env:SKSVC_DB_PASSWORD_FILE = $null
        Get-SecretFilePath | Should -BeLike '*.secrets*db_password'
    }
}

Describe 'Get-CommitSha' {
    It 'returns the full 40-character SHA' {
        Mock Invoke-StackCommand { 'a' * 40 }
        Get-CommitSha -RepoPath 'x' | Should -Be ('a' * 40)
    }

    It 'fails on anything that is not a full SHA' {
        Mock Invoke-StackCommand { 'abc123' }
        { Get-CommitSha -RepoPath 'x' } | Should -Throw '*full commit SHA*'
    }
}

Describe 'New-StackNetwork' {
    It 'creates the network when it is missing' {
        Mock Invoke-StackCommand { @() } -ParameterFilter { $Arguments[1] -eq 'ls' }
        Mock Invoke-StackCommand { 'created' } -ParameterFilter { $Arguments[1] -eq 'create' }
        New-StackNetwork -Name 'sksvc-net' -InformationAction SilentlyContinue
        Should -Invoke Invoke-StackCommand -Times 1 -ParameterFilter { $Arguments[1] -eq 'create' -and $Arguments[2] -eq 'sksvc-net' }
    }

    It 'does nothing when the network exists' {
        Mock Invoke-StackCommand { 'sksvc-net' } -ParameterFilter { $Arguments[1] -eq 'ls' }
        Mock Invoke-StackCommand { } -ParameterFilter { $Arguments[1] -eq 'create' }
        New-StackNetwork -Name 'sksvc-net' -InformationAction SilentlyContinue
        Should -Invoke Invoke-StackCommand -Times 0 -ParameterFilter { $Arguments[1] -eq 'create' }
    }
}

Describe 'Build-ServiceImage' {
    It 'tags the image with the full SHA and passes it as GIT_SHA' {
        Mock Invoke-StackCommand { }
        $sha = 'b' * 40
        Build-ServiceImage -Sha $sha -RepoPath 'repo' -InformationAction SilentlyContinue | Should -Be "sk-svc:$sha"
        Should -Invoke Invoke-StackCommand -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -eq "build --build-arg GIT_SHA=$sha -t sk-svc:$sha repo"
        }
    }
}

Describe 'Wait-ContainerHealthy' {
    It 'returns once the container reports healthy' {
        $script:calls = 0
        Mock Invoke-StackCommand {
            $script:calls++
            if ($script:calls -lt 3) { 'starting' } else { 'healthy' }
        }
        Mock Start-Sleep { }
        Wait-ContainerHealthy -ContainerName 'sksvc-db' -TimeoutSeconds 30
        $script:calls | Should -Be 3
    }

    It 'throws when the container never becomes healthy' {
        Mock Invoke-StackCommand { 'unhealthy' }
        Mock Start-Sleep { }
        { Wait-ContainerHealthy -ContainerName 'sksvc-db' -TimeoutSeconds 0 } | Should -Throw '*did not become healthy*'
    }
}

Describe 'Start-Stack' {
    BeforeEach {
        Mock Assert-DockerRunning { }
        Mock New-StackNetwork { }
        Mock Initialize-SecretFile { 'path' }
        Mock Get-CommitSha { 'c' * 40 }
        Mock Build-ServiceImage { "sk-svc:$('c' * 40)" }
        Mock Start-ComposeProject { }
        Mock Wait-ContainerHealthy { }
        Mock Invoke-EnvironmentDeploy { }
    }

    It 'starts the database, deploys dev then prod with the commit SHA, then monitoring' {
        $output = Start-Stack
        Should -Invoke Start-ComposeProject -Times 1 -ParameterFilter { $Project -eq 'sksvc-data' -and $ProfileName -eq 'data' }
        Should -Invoke Wait-ContainerHealthy -Times 1 -ParameterFilter { $ContainerName -eq 'sksvc-db' }
        Should -Invoke Invoke-EnvironmentDeploy -Times 1 -ParameterFilter { $Environment -eq 'dev' -and $ImageTag -eq ('c' * 40) }
        Should -Invoke Invoke-EnvironmentDeploy -Times 1 -ParameterFilter { $Environment -eq 'prod' -and $ImageTag -eq ('c' * 40) }
        Should -Invoke Start-ComposeProject -Times 1 -ParameterFilter { $Project -eq 'sksvc-mon' -and $ProfileName -eq 'monitoring' }
        ($output -join "`n") | Should -Match '7311'
    }

    It 'skips monitoring when asked' {
        Start-Stack -SkipMonitoring | Out-Null
        Should -Invoke Start-ComposeProject -Times 0 -ParameterFilter { $Project -eq 'sksvc-mon' }
    }

    It '-DataOnly prepares network, password and Postgres, and builds or deploys nothing' {
        $output = Start-Stack -DataOnly
        Should -Invoke New-StackNetwork -Times 1
        Should -Invoke Initialize-SecretFile -Times 1
        Should -Invoke Start-ComposeProject -Times 1 -ParameterFilter { $Project -eq 'sksvc-data' }
        Should -Invoke Wait-ContainerHealthy -Times 1 -ParameterFilter { $ContainerName -eq 'sksvc-db' }
        Should -Invoke Build-ServiceImage -Times 0
        Should -Invoke Invoke-EnvironmentDeploy -Times 0
        Should -Invoke Start-ComposeProject -Times 0 -ParameterFilter { $Project -eq 'sksvc-mon' }
        ($output -join "`n") | Should -Match 'Postgres are ready'
    }

    It 'stops before building when Docker is not running' {
        Mock Assert-DockerRunning { throw 'Docker is not running.' }
        { Start-Stack } | Should -Throw '*Docker is not running*'
        Should -Invoke Build-ServiceImage -Times 0
    }
}
