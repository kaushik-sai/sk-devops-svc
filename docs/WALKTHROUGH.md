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

## 1. Service, container, Compose

**Files**
- `app/lib/Config.ps1`: reads settings from environment variables. `GIT_SHA` gives the version. `FAIL_RATE` is parsed with the invariant culture, and anything invalid falls back to 0 with a warning. `PORT` defaults to 8080. `DB_PASSWORD_FILE` is only checked for existence and non-empty content; the value is never returned.
- `app/lib/Metrics.ps1`: an in-memory metrics store, with Prometheus text output for `http_requests_total{status}`, `app_info{version}` and the `http_request_duration_seconds` histogram. Pode serves requests on several threads, so every update takes one .NET `Monitor` lock. A test hammers it from 8 threads and loses no updates.
- `app/lib/Work.ps1`: decides what one `/work` request does. It waits 10-200 ms, then returns 500 with probability `FAIL_RATE`. The random source is a parameter, so tests pass a seeded one. `Test-CountedPath` keeps `/metrics` and `/healthz` out of the request counter.
- `app/server.ps1`: the thin Pode wiring.
  - Middleware starts a stopwatch, and "endware" records the metric when each response is done.
  - The routes call the lib functions.
  - Request logs go to stdout.
- `Dockerfile`: multi-stage.
  - **Stage 1** downloads pwsh 7.6.7 (SHA-256 checked) and Pode 2.14.1, and deletes Pode's library folders for other .NET versions.
  - **Stage 2** is the small, patched `runtime-deps` Alpine image, with `apk upgrade` and ICU, running as the non-root `app` user. `GIT_SHA` becomes both an env var and the `org.opencontainers.image.revision` label.
- `docker-compose.yml`: one file, four profiles (`dev`, `prod`, `data`, `monitoring`), each run as its own project (`sksvc-dev`, `sksvc-prod`, `sksvc-data`, `sksvc-mon`) on the shared network `sksvc-net`.
  - The apps share one YAML anchor; only the profile and port differ.
  - Hardening: no capabilities, `no-new-privileges`, localhost-only ports.
  - The DB password comes from the Docker secret `.secrets/db_password`.
- `scripts/Start-Stack.ps1` / `Stop-Stack.ps1`: one command up, one command down (see README).

**How the pieces connect**
`Start-Stack` builds `sk-svc:<sha>` and starts Postgres, then calls `Invoke-Deploy.ps1` for dev and prod. That is the same script the pipeline uses, so local and CI deploys behave identically. Compose reads `IMAGE_TAG` and `FAIL_RATE` from the environment. Prometheus scrapes `app-dev:8080` and `app-prod:8080` by service name on `sksvc-net`.

**Likely questions**
1. *Why does only `/work` obey FAIL_RATE?* `/healthz` must stay reliable, or Docker's health check would flap and restart containers. `/work` stands in for real user traffic, which is what a bad release breaks.
2. *Why separate Compose projects instead of one?* Each environment can be redeployed or rolled back with `-p sksvc-<env>` without touching the others, and the database outlives app deploys.
3. *Why not the official PowerShell image?* That repository stopped at 7.5 on an old Alpine. The .NET runtime-deps image is patched regularly and already has a non-root user; the pwsh tarball is checksum-verified.

## 2. ReleaseGuard module

ReleaseGuard (`modules/ReleaseGuard`) is a small module with exactly three exported commands, plus two scripts that share its helpers.

**Files**
- `ReleaseGuard.psd1` / `.psm1`: the manifest and loader. It dot-sources `Private/*.ps1`, then `Public/*.ps1`, and exports three commands.
- `policy.json`: the rules as data.
  - Allowed branches: `^main$`, `^feature/[a-z0-9._-]+$`, `^release/[a-z0-9._-]+$`.
  - The PR-merge pattern `\(#\d+\)$`.
  - The baseline tag `governance-baseline`.
- `Public/Test-BranchCompliance.ps1`:
  - Checks branch names case-sensitively. A leading `refs/heads/` is removed, so the pipeline can pass `$(System.PullRequest.SourceBranch)` as it is.
  - Walks `main`'s first-parent history after the baseline tag and flags subjects without `(#n)`. Without the tag it warns and skips that part.
  - Prints a report and returns an object. On violations it throws `ReleaseGuard.PolicyViolation`, so the pipeline step fails.
- `Public/New-ReleaseAudit.ps1`: lists the commits in `From..To` (SHA, author, subject, PR number). It writes `release-audit-<sha>.md` and `.json`, including the image tag and checks passed. Without `-From` it starts at the first commit.
- `Public/Invoke-Rollback.ps1`:
  - Reads the history and picks the previous `deployed` tag.
  - Checks Docker, then redeploys that tag with `FAIL_RATE=0`.
  - Waits for `/version` to return the tag, then marks the bad entry `rolled_back` and appends the rollback.
  - A second run sees `rolledBackFrom` on the latest entry and does nothing.
  - Error IDs: `NoPreviousRelease`, `DockerNotRunning`, `HealthCheckTimeout`, `ComposeFailed`.
- `Private/History.ps1`: plain functions for `~/.releaseguard/history/<env>.json` (or under `RELEASEGUARD_HOME`). `Invoke-Deploy.ps1`, `Stop-Stack.ps1` and the prod audit step dot-source the same file.
- `Private/Deployment.ps1`: `Invoke-DockerCommand`, the only place docker runs in the module. Also `Test-DockerRunning`, `Invoke-ComposeUp` (sets `IMAGE_TAG`/`FAIL_RATE` only for the call) and `Wait-EndpointValue`.
- `Private/Git.ps1`, `Private/Audit.ps1`: the git wrapper, finding `main` (local or `origin/main`), and building the Markdown.
- `scripts/Invoke-Deploy.ps1`:
  - Runs migrations first (in a child pwsh), then `docker compose up`, then waits for `/healthz`.
  - Appends `deployed` unless that tag is already the latest deployed. A health timeout is recorded as `failed`.
- `scripts/Test-Smoke.ps1`: `/healthz` ok, `/version` equals the SHA, and N `/work` requests all 200. The `/work` batch is what catches a `FAIL_RATE` bad release.

**How it connects**
- The PR pipeline runs `Test-BranchCompliance`.
- The main pipeline runs `Invoke-Deploy.ps1` and `Test-Smoke.ps1` for dev, then for prod, with `New-ReleaseAudit` before the prod deploy and `Invoke-Rollback` if prod fails.
- Deploy and rollback share the history file and the Docker wrapper, so they always agree on what is running.
- Tests mock that wrapper, and git logic runs against a throwaway repo in a temp folder.

**Likely questions**
1. *How is rollback idempotent?* Each rollback appends an entry with `rolledBackFrom`. If the latest entry has it, the environment is already rolled back, and the command returns "AlreadyRolledBack" without touching Docker. History only changes after `/version` confirms the target, so a partial failure is safe to retry.
2. *Why does rollback force `FAIL_RATE=0`?* The bad release in the drill is the same image with a high `FAIL_RATE`. Restoring the old tag with the bad setting would fix nothing.
3. *Why first-parent history and a baseline tag?* With squash merges, each commit on `main`'s first-parent line is one PR, so one regex checks "no direct pushes". The bootstrap commits before the tag were pushed directly, so they are exempt.

## 3. Migrations

**Files**
- `migrations/001_create_greetings.sql`: a small example table.
- `migrations/002_add_greetings_language.sql`: adds `language text NOT NULL DEFAULT 'en'`. This is an "expand" change: the previous app version ignores the column and keeps working.
- `scripts/Invoke-Migrations.ps1 -Environment dev|prod` brings `svc_dev` / `svc_prod` up to date:
  1. Reads the password from `.secrets/db_password`.
  2. Creates the database if it is missing.
  3. Creates `schema_migrations(filename PRIMARY KEY, applied_at)` if it is missing.
  4. Applies each unrecorded `NNN_name.sql` in numeric order. Each file is sent on stdin together with its `INSERT INTO schema_migrations`, using `psql --single-transaction -v ON_ERROR_STOP=1`.
  5. Exits 1 on any failure.

**How it connects**
`Invoke-Deploy.ps1` calls it before switching containers. It reaches Postgres with `docker exec sksvc-db psql -h 127.0.0.1`, because the database publishes no port. The password is passed as `-e PGPASSWORD`, by name only, so it never appears on a command line. The `db` service is initialised with `--auth-host=scram-sha-256`, so the password is really checked; the official image trusts loopback by default. A wrong password was verified to fail.

**Likely questions**
1. *What if a migration fails halfway?* The file and its record are one transaction, so Postgres rolls back both. The deploy stops, and the next run retries that file.
2. *Why doesn't a rollback undo migrations?* Down-migrations can lose data. Instead every migration is backward compatible (expand/contract), so the previous image still works on the new schema.
3. *Why is the second run a no-op?* Applied filenames are recorded in the same transaction, and the script skips recorded files. This was proven in tests and against the real `sksvc-db`.

## 4. Azure Pipelines

**Files**
- `pipelines/templates/checks.yml`: the code checks, each switchable by a parameter.
  - Installs the pinned Pester and PSScriptAnalyzer.
  - Lint fails on Error or Warning.
  - Pester publishes NUnit results, even on failure.
  - `Test-BranchCompliance` runs only in PRs.
  - Terraform runs fmt, init, validate and a test per environment, and fails if 0 tests ran.
  - Trivy config runs twice: LOW/MEDIUM warn, HIGH/CRITICAL fail.
  - promtool runs, but is non-blocking.
- `pipelines/templates/build.yml`: builds `sk-svc:<sha>` once and checks the SHA label. It saves the image to a tar and scans it with the pinned Trivy image. The scan runs twice: everything is shown, and only fixable HIGH/CRITICAL fail. It honours `.trivyignore.yaml`.
- `pipelines/templates/deploy.yml`: runs `Invoke-Deploy.ps1` for one environment and marks `deployStarted`.
- `pipelines/templates/smoke.yml`: runs `Test-Smoke.ps1` against one environment's port.
- `pipelines/pr.yml` (`sk-svc-pr`): runs every check plus the image build and scan, then removes the PR image.
- `pipelines/main.yml` (`sk-svc-main`):
  - **Build:** the cheap checks, build once, scan.
  - **Dev:** a deployment job on Environment `sk-svc-dev`, deploy, smoke test.
  - **Prod:** a deployment job on `sk-svc-prod` with the approval check. It writes the release audit, publishes it as an artifact, deploys with `prodFailRate`, and smoke-tests. On failure after the deploy started, it runs `Invoke-Rollback`.

**How the pieces connect**
The same templates serve dev and prod with different parameters (environment, port, Compose project, fail rate). The image tag is `$(Build.SourceVersion)` from Build through Prod, so the image is never rebuilt. GitHub branch protection requires `sk-svc-pr` to pass, and that check is where `Test-BranchCompliance` enforces the naming and squash policy.

**Likely questions**
1. *How do you prove prod gets the same image as dev?* There is no rebuild after the Build stage. Both deploys use `sk-svc:$(Build.SourceVersion)` with `--no-build`, and the smoke test checks that `/version` equals that SHA.
2. *Why does the rollback step check `deployStarted`?* `failed()` is true for any earlier failure. Without the flag, a failed audit step would roll back a perfectly healthy prod.
3. *Why does the bad-release run end red if it self-healed?* The release did fail. Red means someone looks at it, and the rollback step's log shows prod is back on the previous SHA.

## 5. Terraform

**Files**
- `terraform/versions.tf`: Terraform `>= 1.7`, azurerm `~> 4.81` (4.81.0 locked for Windows and Linux). No backend block, because nothing is applied.
- `terraform/variables.tf`, `main.tf`, `outputs.tf`: the root config. `env` must be dev or prod. `db_password` is sensitive, has no default and is never in tfvars.
- `terraform/envs/dev.tfvars`, `prod.tfvars`: dev has 1 replica and purge protection off; prod has 2 replicas and purge protection on.
- `terraform/modules/service/main.tf`:
  - Resource group, Container Apps environment and managed identity, named `rg-`, `cae-` and `id-sk-svc-<env>`.
  - Key Vault `kv-…` in RBAC mode, with purge protection from a variable.
  - A "Key Vault Secrets User" role for the identity on that vault only.
  - The `db-password` secret.
  - Container App `ca-…`:
    - Runs as the identity.
    - Its secret references Key Vault through the identity.
    - Mounts that secret as a file at `/mnt/secrets`, and sets `DB_PASSWORD_FILE` and `FAIL_RATE`.
    - Ingress goes to 8080, and probes use `/healthz`.
- `terraform/tests/dev.tftest.hcl`, `prod.tftest.hcl`: plan-only tests with `mock_provider "azurerm"`, each run with its real tfvars. A root run checks the names; a module run checks the resources inside.
- `terraform/tests/mocks/azurerm.tfmock.hcl`: fake Azure IDs, so the wiring can be compared at plan time.
- `terraform/README.md`: the commands, and "Before a real apply".

**Likely questions**
1. *Where does the password live, and who can see it?* Pipeline secret, then `TF_VAR_db_password`, then Key Vault. The app reads it through its identity and only ever sees a file. Terraform state also holds it, so state must be remote, encrypted and restricted.
2. *Why a user-assigned identity?* It exists before the app, so the role assignment is in place before the app first pulls the secret. It also survives the app being recreated.
3. *How do you know the tests read the real tfvars?* The env-specific variables have no defaults. Running prod values against the dev test file makes the replica, purge-protection and name assertions fail.

## 6. Monitoring

**Files**
- `monitoring/prometheus.yml`: scrapes `app-dev:8080` (job `sk-svc-dev`) and `app-prod:8080` (job `sk-svc-prod`) every 15 s, evaluates rules every 15 s, and sends alerts to `alertmanager:9093`.
- `monitoring/alerts.yml`: `ProdHighErrorRate`.
  - Fires when the prod 5xx ratio is above 5% over 5 minutes, but only when prod gets more than 0.2 requests/s, and only after holding for 2 minutes.
  - Severity `page`, with a summary, a description showing the live percentage, and the runbook link.
- `monitoring/alerts.test.yml`: `promtool test rules` cases, with no Docker needed.
  - About a third failing with healthy traffic: pending at 3 minutes, firing at 4 minutes.
  - Everything failing at near-zero traffic: no page.
  - 3.8% failing: no page.
- `monitoring/alertmanager.yml`: one route to a UI-only receiver, plus a commented Slack/email example whose credentials are read from secret files.
- `monitoring/grafana/...`: the provisioned Prometheus datasource and the "sk-svc" dashboard. Panels show requests/s, 5xx ratio with a 5% line, p95 latency from the histogram, and the running version from `app_info`.
- `scripts/Test-Monitoring.ps1`: runs the three promtool commands. `scripts/Send-Traffic.ps1`: steady `/work` traffic for the demo.

**How it connects**
The app exposes `/metrics`. Prometheus scrapes it and evaluates the rule. When the rule has held for 2 minutes, Prometheus sends the alert to Alertmanager, which shows it in its UI. Grafana queries Prometheus. In the live drill on this machine, the alert went pending at about 1 minute and fired at about 3.

**Likely questions**
1. *Why the 0.2 requests/s guard?* At very low traffic, one failed request is 100%. The guard means the alert only pages when enough users are affected.
2. *Why `for: 2m` and a 5-minute window?* The window smooths noise, and the 2-minute wait ignores blips like a restart. The cost is that the page arrives about 2-3 minutes after trouble starts.
3. *How would you page for real?* Add a Slack or PagerDuty receiver that reads its key from a mounted secret file (`api_url_file`), and point the route at it. The credential never goes in Git.

## 7. Documentation and operations

- `README.md`: what the repo is, prerequisites, one-command bring-up and teardown, how to run each check, the alert demo, pipelines, and the registry choice.
- `DESIGN.md`: the Compose to Container Apps mapping, the secrets and identity flow (and the Terraform state caveat), the PR gate fail/warn table, fifteen pipelines on shared agents, cost control, migrations and rollback, and a real registry.
- `RUNBOOK.md`: the 02:00 scenario. A minute-by-minute first 15 minutes, rollback-vs-fix-forward criteria, exact commands, who to tell and when, and a blameless post-mortem outline.
- `docs/DECISIONS.md`: every ambiguous call, with the reason. `docs/VERIFY_LOCALLY.md`: what was verified and how, and what is left for the agent.

**Likely questions**
1. *Why roll back by default?* It is one tested command, verified by `/version`, and safe because migrations are backward compatible. Fix-forward is only for a known, tested, faster fix, or when rollback is unsafe.
2. *What would wake you at 02:00, and what wouldn't?* More than 5% of prod requests failing for 2 minutes, with real traffic. Not dev, not a single failed request at night, not CPU.
3. *Where does the Terraform state risk come from?* The Key Vault secret's value is stored in state, so state must be remote, encrypted and access-restricted, or the secret must be created outside Terraform.

## 8. Final verification

Everything listed in [VERIFY_LOCALLY.md](VERIFY_LOCALLY.md) under "Verified" was run on the build machine:
- A clean `Stop-Stack -Purge` then `Start-Stack`.
- The rollback drill with images from two real commits.
- The live alert drill (pending at about 1 minute, firing at about 3).
- Each pipeline step body executed locally.
- 168 Pester tests, lint, Terraform, promtool and Trivy.

The remaining items need the Azure DevOps agent and GitHub settings ([MANUAL_STEPS.md](MANUAL_STEPS.md)).
