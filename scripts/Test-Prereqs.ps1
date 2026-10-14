<#
.SYNOPSIS
    Checks that the tools this repo needs are installed, and prints how to install what is missing.

.DESCRIPTION
    Checks PowerShell 7+, Git, Terraform 1.7+, Pester 5+, PSScriptAnalyzer and promtool.
    Docker (with Compose) and Trivy are reported as "optional here, required on the agent":
    you can lint and test without them, but the pipeline agent needs them.
    Exits 1 if a required tool is missing or too old, otherwise 0.

.EXAMPLE
    pwsh ./scripts/Test-Prereqs.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# The one place that runs external commands. Tests mock this function,
# so they never depend on what is installed on the test machine.
function Invoke-ToolCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string[]] $Arguments = @()
    )
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return $null
    }
    # 2>&1 because some tools print their version on stderr.
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return ($output | Out-String)
}

# Pulls the first "1.2.3" style number out of a tool's version text.
function Get-VersionFromText {
    [CmdletBinding()]
    [OutputType([version])]
    param([string] $Text)
    if ($Text -match '(\d+\.\d+(\.\d+)?)') {
        return [version] $Matches[1]
    }
    return $null
}

# Returns one result object per tool: Name, Found, Version, MinVersion, Required, Ok, Install.
function Get-PrereqStatus {
    [CmdletBinding()]
    param()

    # One row per external tool. MinVersion is the lowest version we accept.
    $tools = @(
        @{ Name = 'git'; Command = 'git'; Arguments = @('--version'); MinVersion = '2.30'; Required = $true
            Install = 'winget install --id Git.Git -e' }
        @{ Name = 'terraform'; Command = 'terraform'; Arguments = @('version'); MinVersion = '1.7'; Required = $true
            Install = 'winget install --id Hashicorp.Terraform -e' }
        @{ Name = 'promtool'; Command = 'promtool'; Arguments = @('--version'); MinVersion = '2.0'; Required = $true
            Install = 'Download the prometheus zip from https://github.com/prometheus/prometheus/releases and put promtool on PATH' }
        @{ Name = 'docker'; Command = 'docker'; Arguments = @('--version'); MinVersion = '20.10'; Required = $false
            Install = 'winget install --id Docker.DockerDesktop -e' }
        @{ Name = 'docker compose'; Command = 'docker'; Arguments = @('compose', 'version'); MinVersion = '2.0'; Required = $false
            Install = 'Included with Docker Desktop' }
        @{ Name = 'trivy'; Command = 'trivy'; Arguments = @('--version'); MinVersion = '0.50'; Required = $false
            Install = 'Download from https://github.com/aquasecurity/trivy/releases and put trivy on PATH' }
    )

    $results = foreach ($tool in $tools) {
        $text = Invoke-ToolCommand -Command $tool.Command -Arguments $tool.Arguments
        $version = Get-VersionFromText -Text $text
        ConvertTo-PrereqResult -Name $tool.Name -Version $version -MinVersion $tool.MinVersion `
            -Required $tool.Required -Install $tool.Install
    }

    # PowerShell itself and the two modules are checked in-process, not with an external command.
    $results += ConvertTo-PrereqResult -Name 'pwsh' -Version $PSVersionTable.PSVersion -MinVersion '7.0' `
        -Required $true -Install 'winget install --id Microsoft.PowerShell -e'

    foreach ($module in @(
            @{ Name = 'Pester'; MinVersion = '5.0'; Install = 'Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck' }
            @{ Name = 'PSScriptAnalyzer'; MinVersion = '1.20'; Install = 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force' }
        )) {
        $installed = Get-Module -ListAvailable -Name $module.Name |
            Sort-Object Version -Descending | Select-Object -First 1
        $version = if ($installed) { $installed.Version } else { $null }
        $results += ConvertTo-PrereqResult -Name $module.Name -Version $version -MinVersion $module.MinVersion `
            -Required $true -Install $module.Install
    }

    return $results
}

function ConvertTo-PrereqResult {
    [CmdletBinding()]
    param(
        [string] $Name,
        [AllowNull()] $Version,
        [string] $MinVersion,
        [bool] $Required,
        [string] $Install
    )
    $found = $null -ne $Version
    # SemanticVersion (PowerShell's own version) is converted to [version] so the comparison works.
    $ok = $found -and ([version] ('{0}.{1}' -f $Version.Major, $Version.Minor)) -ge [version] $MinVersion
    [pscustomobject] @{
        Name       = $Name
        Found      = $found
        Version    = if ($found) { $Version.ToString() } else { '' }
        MinVersion = $MinVersion
        Required   = $Required
        Ok         = $ok
        Install    = $Install
    }
}

# Turns the results into readable lines. Returns strings so tests can check them.
function Format-PrereqReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object[]] $Results)
    foreach ($r in $Results) {
        $state = if ($r.Ok) { 'OK     ' } elseif ($r.Required) { 'MISSING' } else { 'OPTIONAL' }
        $line = '{0} {1,-17} {2}' -f $state, $r.Name, $r.Version
        if (-not $r.Ok) {
            $note = if ($r.Required) { "needs >= $($r.MinVersion)" } else { 'optional here, required on the agent' }
            $line += " ($note). Install: $($r.Install)"
        }
        $line
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $results = Get-PrereqStatus
    Format-PrereqReport -Results $results | Write-Output
    $missing = @($results | Where-Object { $_.Required -and -not $_.Ok })
    if ($missing.Count -gt 0) {
        Write-Error "$($missing.Count) required tool(s) missing or too old." -ErrorAction Continue
        exit 1
    }
    exit 0
}
