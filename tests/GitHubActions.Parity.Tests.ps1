BeforeAll {
    # The GitHub Actions workflow mirrors the Azure pipeline templates. These tests fail when
    # one changes without the other: a check added on one side only, or a pinned version bumped on one side only.
    $root = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $script:checksYaml = Get-Content -Raw -Path (Join-Path -Path $root -ChildPath 'pipelines' -AdditionalChildPath 'templates', 'checks.yml')
    $script:buildYaml = Get-Content -Raw -Path (Join-Path -Path $root -ChildPath 'pipelines' -AdditionalChildPath 'templates', 'build.yml')
    $script:workflowYaml = Get-Content -Raw -Path (Join-Path -Path $root -ChildPath '.github' -AdditionalChildPath 'workflows', 'sk-svc-checks.yml')

    # Default value of an Azure template parameter, e.g. pesterVersion -> 5.9.1.
    function Get-TemplateDefault {
        param([string] $Yaml, [string] $Parameter)
        if ($Yaml -match "name:\s*$Parameter\s+type:\s*string\s+default:\s*'([^']+)'") { return $Matches[1] }
        return $null
    }

    # Value of a top-level env entry in the workflow, e.g. PESTER_VERSION -> 5.9.1.
    function Get-WorkflowEnv {
        param([string] $Name)
        if ($script:workflowYaml -match "(?m)^\s+$($Name):\s*'([^']+)'") { return $Matches[1] }
        return $null
    }

    # Every quoted step name: displayName in Azure, name in GitHub.
    function Get-StepName {
        param([string] $Yaml, [string] $Key)
        [regex]::Matches($Yaml, "(?m)^\s*-?\s*$($Key):\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    }
}

Describe 'GitHub Actions mirror of the PR gate' {
    It 'pins the same <Tool> version as the Azure templates' -ForEach @(
        @{ Tool = 'Pester'; Parameter = 'pesterVersion'; EnvName = 'PESTER_VERSION' }
        @{ Tool = 'PSScriptAnalyzer'; Parameter = 'scriptAnalyzerVersion'; EnvName = 'SCRIPT_ANALYZER_VERSION' }
        @{ Tool = 'Trivy'; Parameter = 'trivyImage'; EnvName = 'TRIVY_IMAGE' }
    ) {
        $azure = Get-TemplateDefault -Yaml $script:checksYaml -Parameter $Parameter
        $azure | Should -Not -BeNullOrEmpty
        Get-WorkflowEnv -Name $EnvName | Should -Be $azure
    }

    It 'uses the same Trivy image for the image scan as for the config scan' {
        Get-TemplateDefault -Yaml $script:buildYaml -Parameter 'trivyImage' |
            Should -Be (Get-TemplateDefault -Yaml $script:checksYaml -Parameter 'trivyImage')
    }

    It 'has a step for every check in the Azure templates' {
        $azureSteps = @(Get-StepName -Yaml $script:checksYaml -Key 'displayName') + @(Get-StepName -Yaml $script:buildYaml -Key 'displayName')
        $githubSteps = @(Get-StepName -Yaml $script:workflowYaml -Key 'name')
        $azureSteps.Count | Should -BeGreaterThan 5
        foreach ($step in $azureSteps) {
            $githubSteps | Should -Contain $step -Because "the Azure step '$step' needs a GitHub step of the same name"
        }
    }

    It 'only reads the repository' {
        $script:workflowYaml | Should -Match '(?m)^permissions:\s+contents:\s*read\s*$'
    }

    It 'pins every action to a full commit SHA' {
        $uses = [regex]::Matches($script:workflowYaml, '(?m)^\s*(?:-\s*)?uses:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value }
        $uses.Count | Should -BeGreaterThan 0
        foreach ($action in $uses) {
            $action | Should -Match '@[0-9a-f]{40}$' -Because "'$action' should be pinned to a commit, not a movable tag"
        }
    }
}
