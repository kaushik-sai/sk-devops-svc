# Verification

The build machine was a Windows 11 laptop with Docker Desktop running (full mode), so the Docker-based checks were run for real. This page lists what was verified, and the steps still to run on the agent or by hand.

## Verified on the build machine (2026-10-14)

| Check | How | Result |
|---|---|---|
| Lint | `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` | 0 findings |
| Unit tests | `Invoke-Pester -Path ./tests` | 194 passed, 0 failed |
| Terraform | `fmt -check`, `init -backend=false`, `validate`, `test` with dev and prod tfvars | all pass, 2 + 2 runs |
| Alert rules | `scripts/Test-Monitoring.ps1` (promtool check config, check rules, test rules) | all pass |
| Alertmanager config | `amtool check-config monitoring/alertmanager.yml` | pass |
| YAML / JSON | Parsed all 13 YAML files and the dashboard JSON; checked every pipeline template path and parameter name | 0 errors |
| Image | `docker build`, non-root user (`id` shows uid 1654 `app`), `/version` returns the SHA, `/healthz` ok with `secret_loaded: true`, `/metrics` shows the three metrics, `FAIL_RATE=1` makes `/work` return 500 | as expected |
| Trivy | Config scan of Terraform and Dockerfile: 0 HIGH/CRITICAL. Image scan: 0 fixable HIGH/CRITICAL after the scoped exceptions in `.trivyignore.yaml` | gate passes |
| Pipeline steps | Every `pwsh` step of `checks.yml`, `build.yml` and the prod audit step of `main.yml` executed locally, with pipeline variables replaced by local paths. A simulated agent job from a fresh clone (no `.secrets`) with the agent's `.env` and `.path`: build, prepare, deploy dev and prod, smoke tests, image clean-up | pass |
| Bring-up / tear-down | `Stop-Stack.ps1 -Purge` (twice), then `Start-Stack.ps1` (twice) from a clean state | up; second run reuses everything and adds no history entries |
| Migrations | Against `sksvc-db`: first run applies 2 files, second run applies nothing; wrong password fails | as expected |
| Rollback drill | Deploy A (image built from the previous commit), deploy B with `FAIL_RATE=0.5`, smoke test fails, `Invoke-Rollback -Environment prod`, `/version` shows A, run it again | rolled back; second run "Already rolled back", no docker call |
| Alert drill | Prod at `FAIL_RATE=0.33` with `Send-Traffic.ps1` at 2 requests/s | pending after ~1 min, firing at ~3 min, visible in Alertmanager with `severity="page"` |
| Monitoring | Prometheus targets `sk-svc-dev` and `sk-svc-prod` UP; `app_info` carries the SHA; Grafana dashboard `sk-svc` provisioned | as expected |
| First real pipeline runs (Azure DevOps agent `sk-local`, account `svc-azagent`) | `sk-svc-pr` on PR #1 and PR #2; `sk-svc-main` run #6 for the merge of PR #2 | PR checks green; main run green through Build, Dev, the prod approval and Prod (audit artifact `release-audit-prod`, smoke tests, image clean-up); dev and prod `/version` = the merge commit |
| Branch policy with the baseline tag | `governance-baseline` on the last bootstrap commit; `Test-BranchCompliance -RepoPath .` after two squash-merged PRs | `COMPLIANT`; the commit check runs (no baseline warning) |
| Evidence runs on the agent | Run 1: PR #4 (`sk-svc-pr` build 8). Run 2: PR #3 merge (`sk-svc-main` build 9). Run 3: `sk-svc-main` build 10 with `prodFailRate=1` | Run 1 failed at Pester and GitHub blocked the merge; run 2 green to prod; run 3 failed the prod smoke test, `Invoke-Rollback` restored `ed4fb2f`, and a second rollback was a no-op. Details in [EVIDENCE.md](EVIDENCE.md) |

## Still to verify

1. **"Docker not running" error, for real.** Stop Docker Desktop, then run `Invoke-Rollback -Environment prod` after an A/B deploy. Expected: it fails with error ID `ReleaseGuard.DockerNotRunning`. So far this case has only been tested with mocked Docker.
2. **Linux.** All scripts are written for pwsh 7 on Linux too (Join-Path everywhere, no Windows-only calls), but they were only run on Windows. To check, run `Invoke-Pester -Path ./tests` on Linux pwsh 7 and expect all tests to pass. On Linux the Terraform test filter uses `tests/dev.tftest.hcl`; the pipeline builds the path with `Join-Path`, so it adapts.
3. **Terraform against Azure.** Not possible (no subscription) and out of scope. See [terraform/README.md](../terraform/README.md) for what to add before a real apply.
