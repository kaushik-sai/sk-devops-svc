BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-Prereqs.ps1')
}

Describe 'Get-VersionFromText' {
    It 'reads <Text>' -ForEach @(
        @{ Text = 'git version 2.47.1.windows.1'; Expected = '2.47.1' }
        @{ Text = 'Terraform v1.9.8'; Expected = '1.9.8' }
        @{ Text = 'Version: 0.56.2'; Expected = '0.56.2' }
        @{ Text = 'Docker Compose version v2.29.1'; Expected = '2.29.1' }
    ) {
        Get-VersionFromText -Text $Text | Should -Be ([version] $Expected)
    }

    It 'returns null when there is no version' {
        Get-VersionFromText -Text 'command not found' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PrereqStatus' {
    It 'marks a tool OK when the version is new enough' {
        Mock Invoke-ToolCommand { 'Terraform v1.9.0' } -ParameterFilter { $Command -eq 'terraform' }
        Mock Invoke-ToolCommand { $null }
        $tf = Get-PrereqStatus | Where-Object Name -EQ 'terraform'
        $tf.Ok | Should -BeTrue
        $tf.Version | Should -Be '1.9.0'
    }

    It 'marks terraform too old below 1.9 (cross-variable validation needs 1.9)' {
        Mock Invoke-ToolCommand { 'Terraform v1.8.5' } -ParameterFilter { $Command -eq 'terraform' }
        Mock Invoke-ToolCommand { $null }
        $tf = Get-PrereqStatus | Where-Object Name -EQ 'terraform'
        $tf.Found | Should -BeTrue
        $tf.Ok | Should -BeFalse
    }

    It 'reports docker and trivy as not required' {
        Mock Invoke-ToolCommand { $null }
        $optional = Get-PrereqStatus | Where-Object { -not $_.Required }
        $optional.Name | Should -Contain 'docker'
        $optional.Name | Should -Contain 'trivy'
    }

    It 'always checks pwsh itself' {
        Mock Invoke-ToolCommand { $null }
        (Get-PrereqStatus).Name | Should -Contain 'pwsh'
    }
}

Describe 'Format-PrereqReport' {
    It 'prints the install command for a missing required tool' {
        $r = ConvertTo-PrereqResult -Name 'terraform' -Version $null -MinVersion '1.7' -Required $true -Install 'winget install terraform'
        $line = Format-PrereqReport -Results @($r)
        $line | Should -Match '^MISSING'
        $line | Should -Match 'winget install terraform'
    }

    It 'says "optional here, required on the agent" for docker' {
        $r = ConvertTo-PrereqResult -Name 'docker' -Version $null -MinVersion '20.10' -Required $false -Install 'x'
        Format-PrereqReport -Results @($r) | Should -Match 'optional here, required on the agent'
    }

    It 'prints OK without an install hint when the tool is fine' {
        $r = ConvertTo-PrereqResult -Name 'git' -Version ([version] '2.47.0') -MinVersion '2.30' -Required $true -Install 'x'
        $line = Format-PrereqReport -Results @($r)
        $line | Should -Match '^OK'
        $line | Should -Not -Match 'Install'
    }
}
