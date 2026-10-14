# Walkthrough

Plain-English notes on how the repo fits together, one section per build phase, with likely follow-up questions.

## 0. Environment and foundations

**Environment used to build this:** Windows 11 laptop, PowerShell 7.6.7, Git 2.52, Docker Desktop 29.8.2 (Compose v5.5.1), Terraform 1.16.5, Pester 5.9.1, PSScriptAnalyzer 1.25.0, promtool 3.15.0, Trivy 0.75.0. Docker was running, so this is **full mode**: every Docker-based check was run for real, not just written down.

**Files**
- `PSScriptAnalyzerSettings.psd1`: the lint rules for the whole repo. All default rules, plus consistent indentation, brace placement and a PowerShell 7 syntax check. Error and Warning findings fail the build; Information is only reported.
- `scripts/Test-Prereqs.ps1`: checks every tool and its minimum version, and prints the exact install command for anything missing. Docker and Trivy are reported as "optional here, required on the agent", because you can lint and test without them but the pipeline agent cannot build or scan without them.
- `tests/Test-Prereqs.Tests.ps1`: Pester tests. External commands go through one function (`Invoke-ToolCommand`), so the tests mock it and never depend on what is installed.
- `.gitignore`: adds `.secrets/` (where the local database password lives) and the generated release-audit files.

**How the pieces connect:** every script follows the same shape: functions at the top, and a small "main" block at the bottom that only runs when the script is executed (not when a test dot-sources it). That keeps every script testable.

**Likely questions**
1. *Why does Test-Prereqs not fail when Docker is missing?* Lint, unit tests and Terraform tests don't need Docker. It fails only for what the developer needs to work; the agent's own run fails at the Docker step if Docker is missing.
2. *Why one wrapper function for external commands?* So tests can mock exactly one thing and stay fast and deterministic.
3. *Why is Terraform's minimum 1.7?* `mock_provider` in `terraform test` arrived in 1.7.
