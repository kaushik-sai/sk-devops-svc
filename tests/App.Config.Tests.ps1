BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'app', 'lib', 'Config.ps1')
}

Describe 'ConvertTo-FailRate' {
    It 'parses <Value> as <Expected>' -ForEach @(
        @{ Value = '0'; Expected = 0 }
        @{ Value = '0.33'; Expected = 0.33 }
        @{ Value = '1'; Expected = 1 }
        @{ Value = ''; Expected = 0 }
        @{ Value = $null; Expected = 0 }
    ) {
        ConvertTo-FailRate -Value $Value | Should -Be $Expected
    }

    It 'falls back to 0 with a warning for <Value>' -ForEach @(
        @{ Value = 'abc' }
        @{ Value = '-0.1' }
        @{ Value = '1.5' }
    ) {
        ConvertTo-FailRate -Value $Value -WarningVariable warnings -WarningAction SilentlyContinue | Should -Be 0
        $warnings | Should -Not -BeNullOrEmpty
    }

    It 'uses a dot as decimal separator on any machine culture' {
        $original = [Globalization.CultureInfo]::CurrentCulture
        try {
            # German culture uses a comma for decimals; FAIL_RATE must still parse "0.5" as one half.
            [Globalization.CultureInfo]::CurrentCulture = 'de-DE'
            ConvertTo-FailRate -Value '0.5' | Should -Be 0.5
        } finally {
            [Globalization.CultureInfo]::CurrentCulture = $original
        }
    }
}

Describe 'Test-SecretFile' {
    It 'is true when the file has content' {
        $path = Join-Path -Path $TestDrive -ChildPath 'pw'
        Set-Content -Path $path -Value 's3cret-value'
        Test-SecretFile -Path $path | Should -BeTrue
    }

    It 'is false when the file is empty' {
        $path = Join-Path -Path $TestDrive -ChildPath 'empty'
        Set-Content -Path $path -Value ''
        Test-SecretFile -Path $path | Should -BeFalse
    }

    It 'is false when the file is missing or no path is set' {
        Test-SecretFile -Path (Join-Path -Path $TestDrive -ChildPath 'nope') | Should -BeFalse
        Test-SecretFile -Path '' | Should -BeFalse
    }
}

Describe 'Get-AppConfig' {
    BeforeEach {
        $script:saved = @{ GIT_SHA = $env:GIT_SHA; FAIL_RATE = $env:FAIL_RATE; PORT = $env:PORT; DB_PASSWORD_FILE = $env:DB_PASSWORD_FILE }
    }
    AfterEach {
        foreach ($name in $script:saved.Keys) {
            Set-Item -Path "env:$name" -Value $script:saved[$name]
        }
    }

    It 'reads all settings from the environment' {
        $secret = Join-Path -Path $TestDrive -ChildPath 'db_password'
        Set-Content -Path $secret -Value 'pw'
        $env:GIT_SHA = 'abc123'
        $env:FAIL_RATE = '0.25'
        $env:PORT = '9000'
        $env:DB_PASSWORD_FILE = $secret

        $config = Get-AppConfig
        $config.Version | Should -Be 'abc123'
        $config.FailRate | Should -Be 0.25
        $config.Port | Should -Be 9000
        $config.SecretLoaded | Should -BeTrue
    }

    It 'uses safe defaults when nothing is set' {
        $env:GIT_SHA = $null
        $env:FAIL_RATE = $null
        $env:PORT = $null
        $env:DB_PASSWORD_FILE = $null

        $config = Get-AppConfig
        $config.Version | Should -Be 'unknown'
        $config.FailRate | Should -Be 0
        $config.Port | Should -Be 8080
        $config.SecretLoaded | Should -BeFalse
    }

    It 'never exposes the secret value' {
        $secret = Join-Path -Path $TestDrive -ChildPath 'db_password'
        Set-Content -Path $secret -Value 'do-not-leak-me'
        $env:DB_PASSWORD_FILE = $secret
        (Get-AppConfig | ConvertTo-Json) | Should -Not -Match 'do-not-leak-me'
    }
}
