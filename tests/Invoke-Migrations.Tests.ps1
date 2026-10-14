BeforeAll {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Invoke-Migrations.ps1'
    # Dot-source so we get the functions without running the main block.
    . $scriptPath -Environment dev

    # A fake Postgres: remembers whether the database exists and which files are recorded.
    # The mock of Invoke-DockerCommand below reads and changes this state.
    function Get-FakeDb {
        param([bool] $DatabaseExists = $true, [string[]] $Applied = @())
        [pscustomobject] @{
            DatabaseExists = $DatabaseExists
            Applied        = [System.Collections.Generic.List[string]] $Applied
            Created        = $false
            FailOn         = ''
            AllArguments   = [System.Collections.Generic.List[string]]::new()
        }
    }

    # Pretends to be "docker exec ... psql". Recognises the few queries the script sends.
    function Invoke-FakeDocker {
        param($Db, [string[]] $Arguments, [string] $InputText)
        $Db.AllArguments.Add($Arguments -join ' ')
        $sql = $Arguments[-1]
        if ($InputText) {
            # A migration file: record it, unless this test wants it to fail.
            if ($Db.FailOn -and $InputText -match [regex]::Escape($Db.FailOn)) {
                throw 'docker exec failed (exit 3): ERROR: syntax error'
            }
            if ($InputText -match "VALUES \('([^']+)'\)") {
                $Db.Applied.Add($Matches[1])
            }
            return @()
        }
        if ($sql -like '*FROM pg_database*') {
            if ($Db.DatabaseExists) { return @('1') } else { return @() }
        }
        if ($sql -like 'CREATE DATABASE*') {
            $Db.DatabaseExists = $true
            $Db.Created = $true
            return @()
        }
        if ($sql -like 'SELECT filename*') {
            return @($Db.Applied)
        }
        return @()
    }

    # Three migration files in a temp folder. 010 must sort after 002 (numeric, not text, order).
    $script:migrations = Join-Path -Path $TestDrive -ChildPath 'migrations'
    New-Item -ItemType Directory -Path $script:migrations | Out-Null
    Set-Content -Path (Join-Path -Path $script:migrations -ChildPath '010_third.sql') -Value 'SELECT 10;'
    Set-Content -Path (Join-Path -Path $script:migrations -ChildPath '001_first.sql') -Value 'SELECT 1;'
    Set-Content -Path (Join-Path -Path $script:migrations -ChildPath '002_second.sql') -Value 'SELECT 2;'

    # Dummy password, only used by the tests.
    $script:secretFile = Join-Path -Path $TestDrive -ChildPath 'db_password'
    Set-Content -Path $script:secretFile -Value 'test-only-password'

    $script:common = @{
        Environment    = 'dev'
        MigrationsPath = $script:migrations
        ContainerName  = 'fake-db'
        SecretFile     = $script:secretFile
    }
}

Describe 'Get-DatabaseName' {
    It 'maps <Environment> to <Expected>' -ForEach @(
        @{ Environment = 'dev'; Expected = 'svc_dev' }
        @{ Environment = 'prod'; Expected = 'svc_prod' }
    ) {
        Get-DatabaseName -Environment $Environment | Should -Be $Expected
    }
}

Describe 'Get-MigrationFile' {
    It 'sorts files by their number, so 010 comes after 002' {
        (Get-MigrationFile -Path $script:migrations).Name |
            Should -Be @('001_first.sql', '002_second.sql', '010_third.sql')
    }

    It 'rejects a badly named file' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'bad'
        New-Item -ItemType Directory -Path $bad | Out-Null
        Set-Content -Path (Join-Path -Path $bad -ChildPath 'add-column.sql') -Value 'SELECT 1;'
        { Get-MigrationFile -Path $bad } | Should -Throw '*Bad migration file name*'
    }

    It 'fails when the folder does not exist' {
        { Get-MigrationFile -Path (Join-Path -Path $TestDrive -ChildPath 'nope') } | Should -Throw '*not found*'
    }
}

Describe 'Invoke-Migration' {
    BeforeEach {
        $script:db = Get-FakeDb
        Mock Invoke-DockerCommand { Invoke-FakeDocker -Db $script:db -Arguments $Arguments -InputText $InputText }
    }

    It 'applies all files in numeric order on an empty database' {
        $result = Invoke-Migration @script:common
        $result | Should -Be @('001_first.sql', '002_second.sql', '010_third.sql')
        $script:db.Applied | Should -Be @('001_first.sql', '002_second.sql', '010_third.sql')
    }

    It 'skips files that are already recorded' {
        $script:db = Get-FakeDb -Applied @('001_first.sql')
        $result = Invoke-Migration @script:common
        $result | Should -Be @('002_second.sql', '010_third.sql')
    }

    It 'applies nothing when run a second time' {
        Invoke-Migration @script:common | Out-Null
        $second = @(Invoke-Migration @script:common)
        $second.Count | Should -Be 0
        # Each file was sent to psql exactly once across both runs.
        Should -Invoke Invoke-DockerCommand -Times 3 -Exactly -ParameterFilter { $InputText }
    }

    It 'creates the database when it is missing' {
        $script:db = Get-FakeDb -DatabaseExists $false
        Invoke-Migration @script:common | Out-Null
        $script:db.Created | Should -BeTrue
    }

    It 'does not create the database when it already exists' {
        Invoke-Migration @script:common | Out-Null
        $script:db.Created | Should -BeFalse
    }

    It 'creates schema_migrations if missing' {
        Invoke-Migration @script:common | Out-Null
        Should -Invoke Invoke-DockerCommand -ParameterFilter {
            $Arguments[-1] -like 'CREATE TABLE IF NOT EXISTS schema_migrations*'
        }
    }

    It 'sends each file with its schema_migrations insert, in one transaction, stopping on errors' {
        Invoke-Migration @script:common | Out-Null
        Should -Invoke Invoke-DockerCommand -Times 1 -Exactly -ParameterFilter {
            $InputText -match 'SELECT 1;' -and
            $InputText -match "INSERT INTO schema_migrations \(filename\) VALUES \('001_first.sql'\)" -and
            $Arguments -contains '--single-transaction' -and
            $Arguments -contains 'ON_ERROR_STOP=1'
        }
    }

    It 'uses the right container and database, over TCP' {
        Invoke-Migration @script:common | Out-Null
        Should -Invoke Invoke-DockerCommand -ParameterFilter {
            $Arguments[0] -eq 'exec' -and $Arguments -contains 'fake-db' -and
            $Arguments -contains 'svc_dev' -and $Arguments -contains '127.0.0.1'
        }
    }

    It 'never puts the password on the docker command line' {
        Invoke-Migration @script:common | Out-Null
        $script:db.AllArguments | Should -Not -BeNullOrEmpty
        $script:db.AllArguments | ForEach-Object { $_ | Should -Not -Match 'test-only-password' }
        $script:db.AllArguments | ForEach-Object { $_ | Should -Match ' -e PGPASSWORD ' }
    }

    It 'clears PGPASSWORD from the environment afterwards' {
        $env:PGPASSWORD = $null
        Invoke-Migration @script:common | Out-Null
        $env:PGPASSWORD | Should -BeNullOrEmpty
    }

    It 'stops at a failing file, names it, and does not run later files' {
        $script:db.FailOn = 'SELECT 2;'
        { Invoke-Migration @script:common } | Should -Throw '*002_second.sql failed*'
        $script:db.Applied | Should -Be @('001_first.sql')
        Should -Invoke Invoke-DockerCommand -Times 0 -ParameterFilter { $InputText -match 'SELECT 10;' }
    }

    It 'fails clearly when the password file is missing' {
        $params = $script:common.Clone()
        $params.SecretFile = Join-Path -Path $TestDrive -ChildPath 'missing'
        { Invoke-Migration @params } | Should -Throw '*Password file not found*'
        Should -Invoke Invoke-DockerCommand -Times 0
    }
}

Describe 'Script exit code' {
    It 'exits 1 on failure' {
        # Run the real script in a child pwsh. The password file is missing, so it fails
        # before calling docker; this proves the main block turns errors into exit 1.
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing'
        & (Join-Path -Path $PSHOME -ChildPath 'pwsh') -NoProfile -File $scriptPath -Environment dev `
            -MigrationsPath $script:migrations -SecretFile $missing 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}
