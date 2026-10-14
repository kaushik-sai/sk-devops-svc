# The page served at GET /: service name, running version and the endpoints.
# Plain function with no Pode dependency, so Pester can test it directly.
#
# No Set-StrictMode here, unlike the other lib files: Use-PodeScript loads this file inside
# Pode's own loader, and with only one function in the file Pode reads .Length on a single
# value, which strict mode turns into an error and the server does not start.

<#
.SYNOPSIS
    Returns the HTML for the home page.
.DESCRIPTION
    Self-contained: inline CSS only, no external fonts, scripts or images, so it works
    offline and adds nothing for a security scan to worry about. The version is
    HTML-encoded because it comes from an environment variable.
#>
function Get-HomePage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ServiceName,
        [Parameter(Mandatory)] [string] $Version
    )

    $name = [System.Net.WebUtility]::HtmlEncode($ServiceName)
    $sha = [System.Net.WebUtility]::HtmlEncode($Version)
    # Short SHA for the badge; the full one is in the title attribute and on /version.
    $short = if ($Version.Length -gt 12) { [System.Net.WebUtility]::HtmlEncode($Version.Substring(0, 12)) } else { $sha }

    # Single-quoted here-string: PowerShell expands nothing inside, so CSS braces and $ are safe.
    # The three values are put in with -replace on placeholders afterwards.
    $html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{NAME}} | HelloVibe</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px;
    font-family: "Segoe UI", system-ui, -apple-system, Roboto, sans-serif;
    color: #e8e6f0;
    background: radial-gradient(1200px 600px at 20% 10%, #2a1150 0%, transparent 60%),
                radial-gradient(900px 500px at 90% 90%, #062c43 0%, transparent 60%), #0b0b14;
  }
  main { text-align: center; max-width: 720px; width: 100%; }
  .brand {
    margin: 0; line-height: 1; letter-spacing: -0.04em;
    font-family: "Segoe UI Black", "Arial Black", Impact, system-ui, sans-serif;
    font-weight: 900; font-size: clamp(56px, 14vw, 132px);
    background: linear-gradient(90deg, #ff6ec7, #a77bff, #4fd1ff, #6effc1, #ff6ec7);
    background-size: 300% 100%;
    -webkit-background-clip: text; background-clip: text; color: transparent;
    animation: flow 8s linear infinite;
    filter: drop-shadow(0 6px 30px rgba(167, 123, 255, 0.35));
  }
  .tagline { margin: 12px 0 32px; font-size: 18px; color: #b9b4cc; letter-spacing: 0.08em; text-transform: uppercase; }
  .card {
    text-align: left; padding: 24px; border-radius: 16px;
    background: rgba(255, 255, 255, 0.04); border: 1px solid rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(6px);
  }
  .row { display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; align-items: baseline; }
  .svc { font-size: 22px; font-weight: 700; }
  .badge { font-family: Consolas, "Cascadia Mono", monospace; font-size: 14px; padding: 4px 10px; border-radius: 999px; background: #1d1a33; color: #c9b8ff; }
  ul { list-style: none; padding: 0; margin: 20px 0 0; display: grid; gap: 8px; }
  a { color: #4fd1ff; text-decoration: none; font-family: Consolas, "Cascadia Mono", monospace; }
  a:hover { text-decoration: underline; }
  li span { color: #9a95ad; margin-left: 8px; }
  @keyframes flow { to { background-position: 300% 0; } }
  @media (prefers-reduced-motion: reduce) { .brand { animation: none; } }
</style>
</head>
<body>
<main>
  <h1 class="brand">HelloVibe</h1>
  <p class="tagline">ship it, watch it, roll it back</p>
  <section class="card">
    <div class="row">
      <span class="svc">{{NAME}}</span>
      <span class="badge" title="{{SHA}}">version {{SHORT}}</span>
    </div>
    <ul>
      <li><a href="/healthz">/healthz</a><span>liveness</span></li>
      <li><a href="/version">/version</a><span>commit this build came from</span></li>
      <li><a href="/work">/work</a><span>simulated request (obeys FAIL_RATE)</span></li>
      <li><a href="/metrics">/metrics</a><span>Prometheus metrics</span></li>
    </ul>
  </section>
</main>
</body>
</html>
'@
    # -replace treats $ in the replacement specially; the encoded values never contain $,
    # but escape it anyway so a strange GIT_SHA cannot change the page.
    $html = $html -replace '\{\{NAME\}\}', $name.Replace('$', '$$')
    $html = $html -replace '\{\{SHA\}\}', $sha.Replace('$', '$$')
    $html = $html -replace '\{\{SHORT\}\}', $short.Replace('$', '$$')
    return $html
}
