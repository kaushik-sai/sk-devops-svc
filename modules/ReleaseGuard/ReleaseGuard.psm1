Set-StrictMode -Version Latest

# Load private helpers first, then the public commands that use them.
# One function (or one small group of helpers) per file keeps each file easy to read.
$privateFiles = Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1'
$publicFiles = Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1'

foreach ($file in @($privateFiles) + @($publicFiles)) {
    . $file.FullName
}

# Only the three public commands leave the module (also listed in ReleaseGuard.psd1).
Export-ModuleMember -Function 'Test-BranchCompliance', 'New-ReleaseAudit', 'Invoke-Rollback'
