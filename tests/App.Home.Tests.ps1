BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'app', 'lib', 'Home.ps1')
}

Describe 'Get-HomePage' {
    It 'shows the service name, the HelloVibe brand and a short version' {
        $sha = 'a' * 40
        $html = Get-HomePage -ServiceName 'sk-svc' -Version $sha
        $html | Should -Match '<title>sk-svc \| HelloVibe</title>'
        $html | Should -Match 'class="brand">HelloVibe<'
        $html | Should -Match "version $('a' * 12)<"
        # The full SHA is still available in the badge's title.
        $html | Should -Match "title=`"$sha`""
    }

    It 'links every endpoint' {
        $html = Get-HomePage -ServiceName 'sk-svc' -Version 'x'
        foreach ($path in '/healthz', '/version', '/work', '/metrics') {
            $html | Should -Match "href=`"$path`""
        }
    }

    It 'HTML-encodes the version so a strange GIT_SHA cannot inject markup' {
        $html = Get-HomePage -ServiceName 'sk-svc' -Version '<script>alert(1)</script>'
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'keeps a $ in the version as text' {
        Get-HomePage -ServiceName 'sk-svc' -Version 'v$1' | Should -Match 'version v\$1<'
    }

    It 'loads nothing from outside (works offline)' {
        $html = Get-HomePage -ServiceName 'sk-svc' -Version 'x'
        $html | Should -Not -Match 'https?://'
        $html | Should -Not -Match '<script'
    }
}
