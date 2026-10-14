# sk-svc: tiny HTTP service on Pode.
# This file only wires routes to the plain functions in ./lib, which hold the logic and are unit tested.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Pode -RequiredVersion 2.14.1

$libPath = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
# Load the functions here for the startup code below; Use-PodeScript (inside the server block)
# loads the same files into each of Pode's request runspaces.
. (Join-Path -Path $libPath -ChildPath 'Config.ps1')
. (Join-Path -Path $libPath -ChildPath 'Metrics.ps1')
. (Join-Path -Path $libPath -ChildPath 'Work.ps1')

# Read configuration (including whether the secret file is there) once, at startup.
$config = Get-AppConfig

Start-PodeServer -Threads 4 -ScriptBlock {
    # Pode runs routes in separate runspaces; Use-PodeScript loads our functions into each of them.
    Use-PodeScript -Path (Join-Path -Path $libPath -ChildPath 'Config.ps1')
    Use-PodeScript -Path (Join-Path -Path $libPath -ChildPath 'Metrics.ps1')
    Use-PodeScript -Path (Join-Path -Path $libPath -ChildPath 'Work.ps1')

    Add-PodeEndpoint -Address * -Port $config.Port -Protocol Http

    # One request log line per request on stdout, so `docker logs` shows traffic.
    # Pode's built-in -Terminal method only prints when a TTY is attached, which containers
    # normally do not have, so we write each formatted line to stdout ourselves.
    New-PodeLoggingMethod -Custom -ScriptBlock {
        param($item)
        [Console]::Out.WriteLine($item)
    } | Enable-PodeRequestLogging

    # Shared state: the same objects are visible from every runspace.
    Set-PodeState -Name 'config' -Value $config | Out-Null
    Set-PodeState -Name 'metrics' -Value (New-MetricStore -Version $config.Version) | Out-Null

    # Start a stopwatch for every request, and record the metric when the response is done.
    Add-PodeMiddleware -Name 'start-timer' -ScriptBlock {
        $WebEvent.Metadata['Stopwatch'] = [System.Diagnostics.Stopwatch]::StartNew()
        return $true
    }
    Add-PodeEndware -ScriptBlock {
        if (Test-CountedPath -Path $WebEvent.Path) {
            $elapsed = $WebEvent.Metadata['Stopwatch'].Elapsed.TotalSeconds
            Add-RequestMetric -Store (Get-PodeState -Name 'metrics') `
                -StatusCode $WebEvent.Response.StatusCode -DurationSeconds $elapsed
        }
    }

    # Liveness: never affected by FAIL_RATE, so Docker's health check does not flap.
    Add-PodeRoute -Method Get -Path '/healthz' -ScriptBlock {
        $cfg = Get-PodeState -Name 'config'
        # Only a true/false: the secret value is never returned or logged.
        Write-PodeJsonResponse -Value @{ status = 'ok'; secret_loaded = $cfg.SecretLoaded }
    }

    Add-PodeRoute -Method Get -Path '/version' -ScriptBlock {
        $cfg = Get-PodeState -Name 'config'
        Write-PodeJsonResponse -Value @{ version = $cfg.Version }
    }

    # Simulated work. The only endpoint that obeys FAIL_RATE.
    Add-PodeRoute -Method Get -Path '/work' -ScriptBlock {
        $cfg = Get-PodeState -Name 'config'
        # Random.Shared is thread-safe, unlike a plain new Random().
        $outcome = Get-WorkOutcome -FailRate $cfg.FailRate -Random ([System.Random]::Shared)
        Start-Sleep -Milliseconds $outcome.DelayMilliseconds
        if ($outcome.StatusCode -eq 500) {
            Write-PodeJsonResponse -StatusCode 500 -Value @{ status = 'error'; reason = 'simulated failure (FAIL_RATE)' }
        } else {
            Write-PodeJsonResponse -Value @{ status = 'ok'; took_ms = $outcome.DelayMilliseconds }
        }
    }

    Add-PodeRoute -Method Get -Path '/metrics' -ScriptBlock {
        $text = Get-MetricText -Store (Get-PodeState -Name 'metrics')
        Write-PodeTextResponse -Value $text -ContentType 'text/plain; version=0.0.4; charset=utf-8'
    }
}
