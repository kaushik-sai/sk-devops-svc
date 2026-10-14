# PSScriptAnalyzer settings for the whole repo.
# Error and Warning findings fail the build (lint step and pre-commit habit).
# Information findings are reported but do not fail anything.
@{
    Severity     = @('Error', 'Warning', 'Information')

    # All default rules stay on. We add a few that are off by default but
    # cheap to follow and make the code easier to read on the follow-up call.
    IncludeDefaultRules = $true
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # Code must run on PowerShell 7 on Windows and Linux.
            TargetVersions = @('7.0')
        }
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
    }
}
