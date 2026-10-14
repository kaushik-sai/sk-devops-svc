<#
.SYNOPSIS
    Validates the Prometheus config and alert rules with promtool, and runs the alert rule unit tests.

.DESCRIPTION
    Runs three promtool commands against the monitoring folder:
      promtool check config monitoring/prometheus.yml
      promtool check rules  monitoring/alerts.yml
      promtool test rules   monitoring/alerts.test.yml
    No Docker needed. Prints PASS or FAIL per check with promtool's output.
    Exits 1 if any check fails or if promtool is not on PATH, otherwise 0.

.PARAMETER MonitoringPath
    Folder that holds prometheus.yml, alerts.yml and alerts.test.yml. Defaults to the repo's monitoring folder.

.EXAMPLE
    pwsh ./scripts/Test-Monitoring.ps1
#>
[CmdletBinding()]
param(
    [string] $MonitoringPath = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'monitoring')
)

Set-StrictMode -Version Latest

# The one place that runs promtool. Tests mock this function,
# so they never depend on promtool being installed.
# Returns $null when promtool is not on PATH, otherwise the exit code and output.
function Invoke-Promtool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)
    if (-not (Get-Command 'promtool' -ErrorAction SilentlyContinue)) {
        return $null
    }
    # 2>&1 because promtool prints some results and all errors on stderr.
    $output = & promtool @Arguments 2>&1
    [pscustomobject] @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

# The three checks, in the order we run them. Returned as data so tests can check the arguments.
function Get-MonitoringCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $MonitoringPath)
    @(
        [pscustomobject] @{ Name = 'check config'; Arguments = @('check', 'config', (Join-Path -Path $MonitoringPath -ChildPath 'prometheus.yml')) }
        [pscustomobject] @{ Name = 'check rules'; Arguments = @('check', 'rules', (Join-Path -Path $MonitoringPath -ChildPath 'alerts.yml')) }
        [pscustomobject] @{ Name = 'test rules'; Arguments = @('test', 'rules', (Join-Path -Path $MonitoringPath -ChildPath 'alerts.test.yml')) }
    )
}

# Runs each check and returns one result per check: Name, Ok, Output.
# Throws a clear error if promtool is missing, so we do not report three confusing failures.
function Invoke-MonitoringCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $MonitoringPath)
    foreach ($check in (Get-MonitoringCheck -MonitoringPath $MonitoringPath)) {
        $result = Invoke-Promtool -Arguments $check.Arguments
        if ($null -eq $result) {
            throw 'promtool not found on PATH. Download the prometheus archive from https://github.com/prometheus/prometheus/releases and put promtool on PATH.'
        }
        [pscustomobject] @{
            Name   = $check.Name
            Ok     = ($result.ExitCode -eq 0)
            Output = $result.Output
        }
    }
}

# Turns the results into readable lines. Returns strings so tests can check them.
function Format-MonitoringReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object[]] $Results)
    foreach ($r in $Results) {
        $state = if ($r.Ok) { 'PASS' } else { 'FAIL' }
        "$state promtool $($r.Name)"
        # Indent promtool's own output under each line so it is easy to read.
        foreach ($line in ($r.Output -split "\r?\n")) {
            if ($line.Trim()) { "     $line" }
        }
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $results = @(Invoke-MonitoringCheck -MonitoringPath $MonitoringPath)
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    Format-MonitoringReport -Results $results | Write-Output
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Error "$($failed.Count) of $($results.Count) promtool check(s) failed." -ErrorAction Continue
        exit 1
    }
    Write-Output "All $($results.Count) promtool checks passed."
    exit 0
}
