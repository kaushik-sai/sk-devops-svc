# Reads the service settings from environment variables.
# Plain functions with no Pode dependency, so Pester can test them directly.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Parses FAIL_RATE. Returns a number between 0 and 1; anything invalid becomes 0.
.DESCRIPTION
    A bad value must never make the service fail on its own, so invalid input falls back
    to 0 (healthy) and a warning is written.
#>
function ConvertTo-FailRate {
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [double] 0
    }
    $rate = 0.0
    # InvariantCulture so "0.33" parses the same on every machine locale.
    $parsed = [double]::TryParse($Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref] $rate)
    if (-not $parsed -or $rate -lt 0) {
        Write-Warning "FAIL_RATE '$Value' is not a number between 0 and 1. Using 0."
        return [double] 0
    }
    return $rate
}

<#
.SYNOPSIS
    Returns $true if the secret file exists and is not empty. Never returns or logs the secret.
#>
function Test-SecretFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    # We only check that a value is there. The content stays in the file.
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    return -not [string]::IsNullOrWhiteSpace($content)
}

<#
.SYNOPSIS
    Builds the service configuration from environment variables.
.DESCRIPTION
    GIT_SHA          commit the image was built from (baked in at build time)
    FAIL_RATE        0 to 1, share of /work requests that return 500 (default 0)
    DB_PASSWORD_FILE path to the database password file (Docker secret or Key Vault volume)
    PORT             port to listen on (default 8080)
#>
function Get-AppConfig {
    [CmdletBinding()]
    param()

    $port = 8080
    if ($env:PORT) {
        $port = [int] $env:PORT
    }

    [pscustomobject] @{
        Version       = if ($env:GIT_SHA) { $env:GIT_SHA } else { 'unknown' }
        FailRate      = ConvertTo-FailRate -Value $env:FAIL_RATE
        Port          = $port
        SecretLoaded  = Test-SecretFile -Path $env:DB_PASSWORD_FILE
    }
}
