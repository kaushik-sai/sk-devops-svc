@{
    RootModule           = 'ReleaseGuard.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6d2b1f3e-8c4a-4e7b-9a51-2f0c7d9e4b18'
    Author               = 'Sai Kaushik'
    Description          = 'Release governance for sk-svc: branch/PR policy checks, release audit reports and one-step rollback.'
    # PowerShell 7 only (Windows and Linux).
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    # The public surface is exactly these three commands. Everything else is private.
    FunctionsToExport    = @('Test-BranchCompliance', 'New-ReleaseAudit', 'Invoke-Rollback')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
