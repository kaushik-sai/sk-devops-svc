# sk-devops-svc

A tiny containerised service (`sk-svc`) shipped through Azure Pipelines on a self-hosted agent, with:

- **Release governance in PowerShell**: the ReleaseGuard module checks branch and PR policy, writes a release audit for every prod deploy, and rolls back automatically.
- **Promotion of one image**: built once, tagged with the commit SHA, promoted from dev to prod.
- **Terraform for Azure Container Apps**: tested with a mocked provider, never applied.
- **Prometheus, Alertmanager and Grafana**, with a unit-tested alert rule.

| Part | Where |
|---|---|
| Service (PowerShell 7 + Pode): `/healthz`, `/version`, `/work`, `/metrics` | [app/](app/), [Dockerfile](Dockerfile) |
| Local environments (dev, prod, Postgres, monitoring) | [docker-compose.yml](docker-compose.yml), [scripts/](scripts/) |
| Pipelines: PR gate `sk-svc-pr`, release `sk-svc-main` | [pipelines/](pipelines/) |
| ReleaseGuard module: `Test-BranchCompliance`, `New-ReleaseAudit`, `Invoke-Rollback` | [modules/ReleaseGuard/](modules/ReleaseGuard/) |
| Database migrations | [migrations/](migrations/), [scripts/Invoke-Migrations.ps1](scripts/Invoke-Migrations.ps1) |
| Terraform (Container Apps, managed identity, Key Vault) | [terraform/](terraform/) |
| Monitoring | [monitoring/](monitoring/) |
| Design, runbook | [DESIGN.md](DESIGN.md), [RUNBOOK.md](RUNBOOK.md) |
| Decisions, walkthrough, evidence, time | [docs/](docs/) |

## Prerequisites

Windows with PowerShell 7 (the code also runs on Linux pwsh 7) and:

| Tool | Version used | Needed for |
|---|---|---|
| PowerShell | 7.4+ (built with 7.6.7) | everything |
| Git | 2.30+ | everything |
| Docker Desktop (Linux containers) with Compose v2 | built with 29.8 / Compose 5.5 | running the stack, the agent |
| Pester | 5.x (5.9.1) | tests |
| PSScriptAnalyzer | 1.20+ (1.25.0) | lint |
| Terraform | 1.7+ (1.16.5) | Terraform checks (`mock_provider` needs 1.7) |
| promtool | from Prometheus 3.x (3.15.0) | alert rule tests |
| Trivy | 0.50+ (0.75.0), optional locally | security scans (the pipeline runs the `aquasec/trivy:0.75.0` image) |

Check them all, with install commands for anything missing:

```powershell
pwsh ./scripts/Test-Prereqs.ps1
```

## Bring everything up (one command)

```powershell
pwsh ./scripts/Start-Stack.ps1
```

This command:
1. Creates the Docker network `sksvc-net`.
2. Generates a random database password into the git-ignored `.secrets/db_password`.
3. Builds `sk-svc:<full commit SHA>`.
4. Starts Postgres.
5. Runs the migrations and deploys dev and prod. Each deploy is recorded in `~/.releaseguard/history/`.
6. Starts monitoring.

It is safe to run again.

| What | URL |
|---|---|
| dev | http://127.0.0.1:7311/version |
| prod | http://127.0.0.1:7312/version |
| Prometheus | http://127.0.0.1:7390 |
| Grafana dashboard (anonymous, read-only) | http://127.0.0.1:7391/d/sk-svc |
| Alertmanager | http://127.0.0.1:7393 |

All ports are bound to `127.0.0.1`. Postgres publishes no port.

- Opening a service port shows a small HelloVibe page with the service name, the running version and links to `/healthz`, `/version`, `/work` and `/metrics`.
- Grafana has no login on purpose (no password in the repo): open the dashboard link; "Sign in" returns Unauthorized.
- Alertmanager showing "No alert groups found" means nothing is firing. Run the alert demo below to see one.

## Tear down (one command)

```powershell
pwsh ./scripts/Stop-Stack.ps1          # stop and remove all four Compose projects and the network
pwsh ./scripts/Stop-Stack.ps1 -Purge   # also delete the database volume and the deploy history
```

## Lint and tests

```powershell
# Lint: Error and Warning findings fail; Information is only shown
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Unit tests (no Docker needed: every docker call goes through one mocked wrapper per script)
Invoke-Pester -Path ./tests -Output Detailed

# Terraform (from terraform/; see terraform/README.md for why the quotes and the backslash)
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
terraform test '-var-file=envs/dev.tfvars'  '-filter=tests\dev.tftest.hcl'
terraform test '-var-file=envs/prod.tfvars' '-filter=tests\prod.tftest.hcl'

# Monitoring: promtool check config, check rules, and the alert rule unit tests
pwsh ./scripts/Test-Monitoring.ps1
```

## Deploy, smoke test and roll back by hand

These are the same commands the pipeline runs:

```powershell
$sha = git rev-parse HEAD
pwsh ./scripts/Invoke-Deploy.ps1 -Environment dev -ImageTag $sha        # migrations, compose up, health wait, history
pwsh ./scripts/Test-Smoke.ps1 -BaseUrl http://127.0.0.1:7311 -ExpectedSha $sha

Import-Module ./modules/ReleaseGuard
Invoke-Rollback -Environment prod                                       # previous release; safe to run twice
Test-BranchCompliance -RepoPath . -BranchName feature/my-change
New-ReleaseAudit -From <old-sha> -To $sha -ImageTag "sk-svc:$sha" -ChecksPassed lint, pester -OutputDir ./out
```

The branch policy is in [modules/ReleaseGuard/policy.json](modules/ReleaseGuard/policy.json):
- Branches must be `main`, `feature/<name>` or `release/<name>`, where the name uses lowercase letters, digits, `.`, `_` and `-`.
- PRs are squash-merged, so every commit on `main` after the `governance-baseline` tag must end with `(#<PR number>)`.

## Alert demo

1. Bring the stack up (above).
2. Restart prod with a third of `/work` requests failing:
   ```powershell
   pwsh ./scripts/Invoke-Deploy.ps1 -Environment prod -ImageTag (git rev-parse HEAD) -FailRate 0.33
   ```
3. Send traffic for about 5 minutes:
   ```powershell
   pwsh ./scripts/Send-Traffic.ps1 -BaseUrl http://127.0.0.1:7312 -DurationSeconds 300 -RatePerSecond 2
   ```
4. Watch http://127.0.0.1:7390/alerts. `ProdHighErrorRate` turns **pending** after about a minute, then **firing** about 2 minutes later. A local run went pending at about 1 minute and firing at about 3 minutes.
5. The alert then shows in Alertmanager (http://127.0.0.1:7393) with `severity="page"`, and the Grafana dashboard shows the 5xx ratio above the 5% line.
6. Recover with `Invoke-Rollback -Environment prod` or a deploy with `-FailRate 0`, as in [RUNBOOK.md](RUNBOOK.md).

## Pipelines and the self-hosted agent

- **`pipelines/pr.yml` (`sk-svc-pr`)** runs on every PR to `main`. It runs:
  - lint and Pester
  - `Test-BranchCompliance`
  - Terraform fmt, validate and test
  - a Trivy config scan
  - the image build and a Trivy image scan
  - promtool tests, which are non-blocking

  What fails and what only warns is set out in [DESIGN.md](DESIGN.md).
- **`pipelines/main.yml` (`sk-svc-main`)** runs on merge to `main`:
  - **Build** the image once, as `sk-svc:<sha>`.
  - **Dev:** deploy and smoke test.
  - **Prod:** an approval, the release audit artifact, deploy, smoke test, and `Invoke-Rollback` if the smoke test fails.

  The queue-time parameter `prodFailRate` creates a deliberately bad prod-only release.
- Both use the templates in `pipelines/templates/`, configured by template parameters.

To register the agent (Windows, run interactively so it can reach Docker Desktop) and set up the Azure DevOps project, follow [docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md). Use pool `sk-local`, pipelines `sk-svc-pr` and `sk-svc-main`, and environments `sk-svc-dev` and `sk-svc-prod`, with an approval on prod.

## Registry

There is no registry. Images stay **local on the agent**: dev and prod run on the same machine, so the image built in the Build stage is the exact image both deploys use, and no registry credentials are needed. [DESIGN.md](DESIGN.md) explains what changes with a real registry (ACR).

## Verification status

What was verified locally, and what can only be checked on the Azure DevOps agent, is listed in [docs/VERIFY_LOCALLY.md](docs/VERIFY_LOCALLY.md).
