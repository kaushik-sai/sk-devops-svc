BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Initialize-AgentHost.ps1')
}

Describe 'Get-HostLayout' {
    It 'puts history and the secret under the root' {
        $layout = Get-HostLayout -Root (Join-Path -Path $TestDrive -ChildPath 'svc-app')
        $layout.History | Should -Be (Join-Path -Path $TestDrive -ChildPath 'svc-app' -AdditionalChildPath 'history')
        $layout.SecretFile | Should -Be (Join-Path -Path $TestDrive -ChildPath 'svc-app' -AdditionalChildPath 'secrets', 'db_password')
    }
}

Describe 'New-HostFolder and Copy-ExistingState' {
    BeforeEach {
        $script:layout = Get-HostLayout -Root (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid()))
        $script:old = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path -Path $script:old -ChildPath 'history') -Force | Out-Null
        Set-Content -Path (Join-Path -Path $script:old -ChildPath 'pw') -Value 'existing-password' -NoNewline
        Set-Content -Path (Join-Path -Path $script:old -ChildPath 'history' -AdditionalChildPath 'prod.json') -Value '[]'
        New-HostFolder -Layout $script:layout -InformationAction SilentlyContinue
    }

    It 'creates root, history and secrets' {
        Test-Path -LiteralPath $script:layout.History | Should -BeTrue
        Test-Path -LiteralPath $script:layout.Secrets | Should -BeTrue
    }

    It 'copies the existing password and history' {
        Copy-ExistingState -Layout $script:layout -OldSecretFile (Join-Path -Path $script:old -ChildPath 'pw') `
            -OldHistory (Join-Path -Path $script:old -ChildPath 'history') -InformationAction SilentlyContinue
        Get-Content -LiteralPath $script:layout.SecretFile -Raw | Should -Be 'existing-password'
        Test-Path -LiteralPath (Join-Path -Path $script:layout.History -ChildPath 'prod.json') | Should -BeTrue
    }

    It 'never overwrites a password that is already in the shared folder' {
        Set-Content -LiteralPath $script:layout.SecretFile -Value 'shared-password' -NoNewline
        Copy-ExistingState -Layout $script:layout -OldSecretFile (Join-Path -Path $script:old -ChildPath 'pw') `
            -OldHistory (Join-Path -Path $script:old -ChildPath 'history') -InformationAction SilentlyContinue
        Get-Content -LiteralPath $script:layout.SecretFile -Raw | Should -Be 'shared-password'
    }
}

Describe 'Set-HostPermission' {
    BeforeEach {
        $script:layout = Get-HostLayout -Root (Join-Path -Path $TestDrive -ChildPath 'acl')
        Mock Invoke-AclCommand { [pscustomobject] @{ ExitCode = 0; Output = '' } }
    }

    It 'lets the agent modify the root and limits the secrets folder to four identities' {
        Set-HostPermission -Layout $script:layout -AgentAccount 'svc-azagent' -CurrentUser 'kaush' | Should -Be 0
        Should -Invoke Invoke-AclCommand -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq "$($script:layout.Root) /grant svc-azagent:(OI)(CI)M" }
        Should -Invoke Invoke-AclCommand -Times 1 -ParameterFilter {
            $joined = $Arguments -join ' '
            $joined -match '/inheritance:r' -and $joined -match 'SYSTEM:' -and $joined -match 'Administrators:' -and
            $joined -match 'kaush:\(OI\)\(CI\)M' -and $joined -match 'svc-azagent:\(OI\)\(CI\)M'
        }
    }

    It 'gives read-and-run on existing tool folders and skips missing ones' {
        $tool = Join-Path -Path $TestDrive -ChildPath 'tools'
        New-Item -ItemType Directory -Path $tool -Force | Out-Null
        $missing = Join-Path -Path $TestDrive -ChildPath 'nope'
        Set-HostPermission -Layout $script:layout -AgentAccount 'svc-azagent' -CurrentUser 'kaush' `
            -ToolDirectories @($tool, $missing) -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Invoke-AclCommand -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq "$tool /grant svc-azagent:(OI)(CI)RX" }
        Should -Invoke Invoke-AclCommand -Times 0 -ParameterFilter { $Arguments[0] -eq $missing }
    }

    It 'counts failures, for example an account that does not exist' {
        Mock Invoke-AclCommand { [pscustomobject] @{ ExitCode = 1332; Output = 'No mapping between account names' } }
        Set-HostPermission -Layout $script:layout -AgentAccount 'ghost' -CurrentUser 'kaush' -WarningAction SilentlyContinue | Should -Be 2
    }
}

Describe 'Set-AgentEnvironmentFile' {
    It 'writes our variables and keeps other lines' {
        $path = Join-Path -Path $TestDrive -ChildPath '.env'
        Set-Content -Path $path -Value @('OTHER=1', 'RELEASEGUARD_HOME=old')
        Set-AgentEnvironmentFile -Path $path -Values @{ RELEASEGUARD_HOME = 'C:\svc-app'; SKSVC_DB_PASSWORD_FILE = 'C:\svc-app\secrets\db_password' } -InformationAction SilentlyContinue
        $lines = Get-Content -Path $path
        $lines | Should -Contain 'OTHER=1'
        $lines | Should -Contain 'RELEASEGUARD_HOME=C:\svc-app'
        $lines | Should -Not -Contain 'RELEASEGUARD_HOME=old'
        $lines | Should -Contain 'SKSVC_DB_PASSWORD_FILE=C:\svc-app\secrets\db_password'
    }
}

Describe 'Set-AgentDockerConfig' {
    It 'points the Docker CLI at the plugin folder so the agent has docker compose' {
        $plugins = Join-Path -Path $TestDrive -ChildPath 'cli-plugins'
        New-Item -ItemType Directory -Path $plugins -Force | Out-Null
        $path = Join-Path -Path $TestDrive -ChildPath 'config-new.json'
        Set-AgentDockerConfig -Path $path -PluginDirectory $plugins -InformationAction SilentlyContinue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).cliPluginsExtraDirs | Should -Be @($plugins)
    }

    It 'keeps other settings already in the file' {
        $path = Join-Path -Path $TestDrive -ChildPath 'config-existing.json'
        Set-Content -LiteralPath $path -Value '{ "detachKeys": "ctrl-x" }'
        Set-AgentDockerConfig -Path $path -PluginDirectory $TestDrive -InformationAction SilentlyContinue
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $config.detachKeys | Should -Be 'ctrl-x'
        $config.cliPluginsExtraDirs | Should -Be @($TestDrive)
    }

    It 'warns when the plugin folder does not exist' {
        $path = Join-Path -Path $TestDrive -ChildPath 'config-warn.json'
        Set-AgentDockerConfig -Path $path -PluginDirectory (Join-Path -Path $TestDrive -ChildPath 'missing') `
            -WarningVariable warnings -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        $warnings | Should -Not -BeNullOrEmpty
    }
}

Describe 'Initialize-AgentHost' {
    It 'with -WhatIf changes nothing' {
        Mock Invoke-AclCommand { [pscustomobject] @{ ExitCode = 0; Output = '' } }
        Mock Set-UserVariable { }
        $root = Join-Path -Path $TestDrive -ChildPath 'whatif-root'
        $agent = Join-Path -Path $TestDrive -ChildPath 'agent'
        New-Item -ItemType Directory -Path $agent | Out-Null
        Initialize-AgentHost -Root $root -AgentAccount 'svc-azagent' -AgentDirectory $agent -WhatIf | Out-Null
        Test-Path -LiteralPath $root | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $agent -ChildPath '.env') | Should -BeFalse
        Should -Invoke Invoke-AclCommand -Times 0
    }

    It 'sets both variables for the user and writes the agent files' {
        Mock Invoke-AclCommand { [pscustomobject] @{ ExitCode = 0; Output = '' } }
        Mock Set-UserVariable { }
        $root = Join-Path -Path $TestDrive -ChildPath 'real-root'
        $agent = Join-Path -Path $TestDrive -ChildPath 'agent2'
        New-Item -ItemType Directory -Path $agent | Out-Null
        $plugins = Join-Path -Path $TestDrive -ChildPath 'plugins'
        New-Item -ItemType Directory -Path $plugins -Force | Out-Null
        Initialize-AgentHost -Root $root -AgentAccount 'svc-azagent' -AgentDirectory $agent `
            -DockerPluginDirectory $plugins -InformationAction SilentlyContinue | Should -Be 0
        # The agent gets its own Docker settings, found through DOCKER_CONFIG in .env.
        $dockerDir = Join-Path -Path $root -ChildPath 'docker'
        Test-Path -LiteralPath (Join-Path -Path $dockerDir -ChildPath 'config.json') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path -Path $agent -ChildPath '.env') | Should -Contain "DOCKER_CONFIG=$dockerDir"
        Should -Invoke Set-UserVariable -Times 1 -ParameterFilter { $Name -eq 'RELEASEGUARD_HOME' -and $Value -eq $root }
        Should -Invoke Set-UserVariable -Times 1 -ParameterFilter { $Name -eq 'SKSVC_DB_PASSWORD_FILE' -and $Value -like '*secrets*db_password' }
        # PATH goes into .env (the agent does not read a .path file); the user variables stay two.
        $envLines = Get-Content -LiteralPath (Join-Path -Path $agent -ChildPath '.env')
        @($envLines | Where-Object { $_ -like 'PATH=*' }).Count | Should -Be 1
        $envLines | Should -Contain "RELEASEGUARD_HOME=$root"
        Should -Invoke Set-UserVariable -Times 0 -ParameterFilter { $Name -eq 'PATH' }
    }

    It 'reports a missing agent folder as a failure' {
        Mock Invoke-AclCommand { [pscustomobject] @{ ExitCode = 0; Output = '' } }
        Mock Set-UserVariable { }
        $root = Join-Path -Path $TestDrive -ChildPath 'root3'
        Initialize-AgentHost -Root $root -AgentAccount 'svc-azagent' -AgentDirectory (Join-Path -Path $TestDrive -ChildPath 'no-agent') `
            -WarningAction SilentlyContinue -InformationAction SilentlyContinue | Should -Be 1
    }
}
