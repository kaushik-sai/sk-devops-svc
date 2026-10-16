# Decisions

Ambiguities and the call made, one line each.

## Step 1: Service and container

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 1 | Language for the service | PowerShell 7 with Pode | One toolchain (same linter and test framework as ReleaseGuard); candidate's strongest language |
| 2 | Failure injection | Environment variable (`FAIL_RATE`, 0 to 1), set at deploy time | Behaves like a real bad release; doubles as the "bad release" for the rollback evidence run |
| 3 | Metrics | `http_requests_total{status}`, `app_info{version}`, plus `http_request_duration_seconds` histogram | Histogram enables latency alerting; the other two cover errors and version |
| 4 | Host ports | dev 7311, prod 7312, Prometheus 7390, Alertmanager 7393 (container port 8080) | Non-default ports, as requested |

## Step 2: ReleaseGuard

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 5 | Branch naming policy | Allowed: `feature/*`, `release/*`, and `main` (main goes to prod). No bugfix/hotfix, no ticket ID | Keeps the policy small and easy to explain |
| 6 | Merge strategy | Squash merge | One PR number per commit on main, so the "no PR" check is a single pattern |
| 7 | Rollback depth | Previous release only | Matches the brief; `-ToTag` noted as a future extension |
| 8 | Deploy history | JSON file per environment in a fixed folder outside the pipeline workspace; bad release marked `rolled_back`; SHA label on the image as a bonus | Labels show only what runs now, not what ran before; file also feeds the audit range |

## Step 3: Pipeline

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 9 | CI platform | Azure DevOps first (free tier: 5 users, 1 free self-hosted parallel job); GitHub Actions only as a fallback if ADO blocks, with the real reason documented | Brief expects ADO and permits the fallback |
| 10 | Where code lives | Public GitHub repo only (confirmed: no duplicate copy in Azure Repos). ADO builds from it via a GitHub connection; "main" protection is GitHub branch protection requiring the ADO check | Brief requires a public GitHub repo; avoids a mirror and mismatched PR formats |
| 11 | Agent machine | Windows laptop; Windows self-hosted agent run interactively under the user account; Docker Desktop (Linux containers); PowerShell 7 | A service account may not reach Docker Desktop's pipe |
| 12 | Image registry | Local on the agent (no registry); DESIGN.md explains what changes with a real registry | Dev and prod run on the same machine; avoids managing a registry token |
| 13 | PR gate: fail vs warn | Fail: lint errors, any test failure, Terraform fmt/validate/test failure, branch-policy violation, HIGH/CRITICAL vulnerabilities with a fix available. Warn: lower severities and vulnerabilities with no fix yet | Fail on what the team can act on |
| 14 | Configuration | YAML template parameters kept in the repo, not variable groups | Reviewable and reproducible from a fresh clone |
| 15 | Migrations stage | Included: numbered SQL files applied to a Postgres container, idempotent via a `schema_migrations` table; runs before each deploy | Welcome extra; migrations must be backward compatible because rollback does not undo them |
| 16 | Pipeline files | Two entry files (`pr.yml`, `main.yml`) sharing reusable templates; smoke test checks `/version` and a batch of requests | Clear separation; batch check catches a bad release (`FAIL_RATE`) |

## Step 4: Terraform

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 17 | Workload name | `sk-svc` (initials plus a generic service name). Pattern `<type>-sk-svc-<env>`: `rg-`, `cae-`, `ca-`, `id-`, `kv-` for resource group, Container Apps environment, app, managed identity, Key Vault; env is `dev` or `prod` | Microsoft's usual naming pattern; a real apply would add a unique suffix to the Key Vault name |
| 18 | Region | `southindia`; availability of Container Apps there to be checked before a real apply | Closest to the candidate |
| 19 | Dev vs prod | Dev: 1 replica, purge protection off. Prod: 2 replicas, purge protection on | Dev stays easy to throw away |
| 20 | Image reference | Placeholder variable (no registry) | Terraform needs a value; never applied |
| 21 | Secret | Database password for the Postgres container. Terraform takes it as a sensitive variable and stores it in Key Vault; the app reads it through the managed identity. Locally the bring-up script generates a random password into a git-ignored file that Compose passes as a secret. Tests use a dummy value | Realistic flow with no secret in Git; note in DESIGN that state holds the value, so real state must be encrypted and restricted |

## Step 5: Operations

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 22 | Alert rule | Prod 5xx ratio above 5% for 2 minutes, ignored when traffic is near zero; severity page | Wakes someone only for what users feel; the 2-minute wait filters blips; the traffic guard avoids noise at low volume |
| 23 | Notifications | Alertmanager UI only; commented Slack/email placeholder; no credentials | A real integration needs a secret |
| 24 | Dashboards | Grafana OSS included, configured from files in the repo. Panels: request rate, 5xx ratio, p95 latency, running version. Default (change if you object): port 7391, bound to localhost, read-only anonymous access so no password is committed | Runbook step "open the dashboard"; uses the histogram and `app_info` metrics |
| 25 | Runbook roles | Generic roles: engineering lead, service owner, support lead (default, change if you object) | No real people involved |

## Step 6: Calls made while building

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 26 | Base image | `mcr.microsoft.com/dotnet/runtime-deps:10.0.9-alpine3.24` plus the official pwsh 7.6.7 musl tarball (SHA-256 checked), Pode 2.14.1 saved with `Save-PSResource` | The `mcr.microsoft.com/powershell` repo stopped at 7.5 on Alpine 3.20; runtime-deps is patched, small and has a non-root `app` user |
| 27 | ICU in the image | Add `icu-libs` and turn off invariant globalization | Pode loads culture-specific message files and fails to start without ICU |
| 28 | Request logs | Custom Pode logging method writing to stdout | Pode's terminal logger prints only with a TTY, which containers do not have |
| 29 | What `http_requests_total` counts | User traffic only (`/work`, `/version`, unknown paths); not `/metrics` or `/healthz` | Scrapes and health checks add steady 200s that would hide the real error ratio and inflate the alert's traffic guard |
| 30 | Does `Start-Stack.ps1` start monitoring? | Yes, by default (`-SkipMonitoring` to skip) | One command brings up everything the runbook uses |
| 31 | Compose hardening | Apps: `cap_drop: ALL`, `no-new-privileges`, localhost-only ports; Postgres publishes no port | Trivy has no Compose scanner, so the file is hardened by hand |
| 32 | Postgres trusts loopback by default | `POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256` on the `db` service | Otherwise a wrong password still works over 127.0.0.1; verified a wrong password now fails |
| 33 | PR checks again on main? | Build stage reruns lint and Pester and scans the new image; Terraform and the config scan are skipped | The squash-merged code is the PR's code, which already passed; the image is new, so it is scanned again |
| 34 | When does the pipeline roll back prod? | Only if a step failed **after** the prod deploy started (`deployStarted` variable) | A failed audit step must not roll back a healthy prod |
| 35 | Image findings that cannot be fixed | Fix first: `apk upgrade`, delete Pode's unused `netstandard2.0`/`net8.0`/`net9.0` libraries. Remaining pwsh-bundled CVEs go in `.trivyignore.yaml`, scoped to one file each, with a reason and an expiry date | pwsh 7.6.7 is the newest release; Pode's declared Pkcs 8.0.1 is never loaded (checked inside the image) |
| 36 | `terraform test -filter` silently runs 0 tests on Windows with a forward slash | Build the path with `Join-Path`, and fail the step if the output does not show at least one passed run | A green step that tested nothing is worse than a red one |
| 37 | PR images | Removed from the agent after the scan | Only main builds are deployed; keeps the shared Docker daemon from filling up |

## Step 7: ReleaseGuard details

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 38 | How does `Test-BranchCompliance` fail a pipeline step and stay testable? | Returns a result object, then throws `ReleaseGuard.PolicyViolation` on violations; `-NoThrow` only returns the object | An unhandled terminating error makes `pwsh -Command` exit non-zero |
| 39 | Baseline tag missing | Warn and skip only the commit-history check; branch names are still checked | Naming can be enforced from day one; history checks start once the tag exists |
| 40 | Which branches does "all branches" mean? | Local branches; `main` found locally or as `origin/main` | CI checkouts have no local `main`; the PR pipeline passes `-BranchName` anyway |
| 41 | How is a rollback recorded? | Bad entry becomes `rolled_back`; a new `deployed` entry with `rolledBackFrom = <bad tag>` is appended | History stays append-only and readable; the idempotency check reads `rolledBackFrom` |
| 42 | Which release is "current" for a rollback? | The latest entry, whatever its status; the target is the newest earlier `deployed` entry with a different tag | After a failed deploy the environment runs the failed tag |
| 43 | Failed deploys | A `/healthz` timeout appends a `failed` entry, then exits 1 | Rollback then knows what is really running |
| 44 | Duplicate history entries | A deploy only appends when the latest entry is not already this tag as `deployed` | Re-running a deploy (or `Start-Stack`) adds nothing |
| 45 | Calling migrations from the deploy | In a child pwsh process, checking its exit code (`ReleaseGuard.MigrationsFailed`) | The migration script's `exit` cannot end the deploy script |

## Step 8: Migrations, Terraform, monitoring details

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 46 | Password for psql | `docker exec -e PGPASSWORD` (name only), value set from `.secrets/db_password` and restored afterwards | The secret never appears on a command line or in logs |
| 47 | One transaction per migration file | File plus its `schema_migrations` INSERT sent on stdin to `psql --single-transaction -v ON_ERROR_STOP=1`; files contain no BEGIN/COMMIT | Simplest atomic option; a broken file leaves no table and no record |
| 48 | Migration file names | `NNN_lowercase_name.sql`, sorted by the number; anything else fails the run | Numeric sort avoids text-order surprises; the strict name is safe inside SQL |
| 49 | Example schema | `greetings` table, then a defaulted `language` column | Smallest example that shows a backward-compatible (expand) change |
| 50 | Terraform tests per environment | One test file per env, run with `-var-file=envs/<env>.tfvars`; each has a root run (names) and a module run (resource internals) | Assertions cannot see inside a child module from a root run |
| 51 | IDs at plan time | Mock provider with fake Azure IDs, `override_during = plan` | Otherwise IDs are unknown at plan time and the identity and secret wiring cannot be compared |
| 52 | Trivy AZU-0013 (Key Vault network default Deny) | Inline `#trivy:ignore` with a reason | Deny without a VNet and private endpoints blocks the app and Terraform; private networking is listed under "Before a real apply" |
| 53 | Placeholder image | `mcr.microsoft.com/k8se/quickstart:latest` as the default; tests use `example.invalid/sk-svc:test` | No registry exists; a real deploy passes `<registry>/sk-svc:<sha>` |
| 54 | Deployer permission on Key Vault | Not in Terraform; documented (pipeline identity needs Key Vault Secrets Officer) | Keeps to the resources the brief lists |
| 55 | Runbook link in the alert | Annotation `runbook: RUNBOOK.md` | No public repo URL to point at yet |
| 56 | Dashboard for two environments | One line per environment (`sum by (job)`); the 5xx panel shows 0% instead of "No data" | Dev and prod side by side, no template variables |
| 57 | Grafana auth | Anonymous Viewer, login form and basic auth disabled, localhost-only port | No password committed; the built-in admin account cannot be used |
| 58 | Separate `dev` branch? | No: trunk-based, `main` only; dev and prod are pipeline stages that receive the same `sk-svc:<sha>` image. A `dev` integration branch (cherry-pick release-ready commits to `main`) is the documented next step if unrelated changes must ship independently | One branch keeps promotion simple and guarantees prod runs exactly what dev tested |
| 59 | Old images on the agent | `scripts/Remove-OldImages.ps1` runs after a successful prod deploy and keeps the last 3 deployed releases per environment plus any image a container uses | Every merge adds about 330 MB; rollback targets must never be deleted |
| 60 | Where the pipeline gets the database password and keeps deploy history | Shared `C:\svc-app` (`secrets\db_password` limited to SYSTEM, Administrators, the agent account and the developer; `history\`), wired through `SKSVC_DB_PASSWORD_FILE` and `RELEASEGUARD_HOME` by `scripts/Initialize-AgentHost.ps1` | The agent runs as its own account with a fresh checkout every run; no vault exists here (Key Vault in production) |
| 61 | Agent account | Dedicated local `svc-azagent` (in `docker-users`) instead of `NETWORK SERVICE` or the developer's Microsoft account | `NETWORK SERVICE` cannot reach Docker Desktop or the tools; a Microsoft-account password should not be stored in a service |
| 62 | Postgres in a pipeline run | `Start-Stack.ps1 -DataOnly` runs before each deploy (network, password, Postgres; no-op when already there) | A fresh checkout has nothing; the deploy's migrations need the database |
| 63 | `docker compose` missing for the agent account | `Initialize-AgentHost.ps1` writes `C:\svc-app\docker\config.json` with `cliPluginsExtraDirs` pointing at Docker Desktop's plugin folder, and sets `DOCKER_CONFIG` in the agent's `.env` | Docker Desktop installs Compose per user; the first `sk-svc-main` run failed with "unknown shorthand flag: 'f'" because `compose` was not a known command for `svc-azagent` |
| 64 | The brief asks for a public Azure DevOps project | The project stays private; reviewers are added as users with read access (Project Readers) on request. GitHub, where the code lives, is public, and the PR checks are visible there | Microsoft has retired public projects in Azure DevOps: new organizations cannot create them or switch a project to public (https://learn.microsoft.com/en-us/azure/devops/organizations/projects/make-project-public?view=azure-devops) |
| 65 | Minimum reviewers on `main` | 0 required approvals; the required `sk-svc-pr` check, PR-only and squash-only rules are the gate | Single-person repository: GitHub does not let an author approve their own PR. With a team, require 1+ reviewers |

## Step 9: Public checks on GitHub Actions

| # | Question | Decision | Why |
|---|----------|----------|-----|
| 66 | How can anyone see the checks run, when the Azure DevOps project is private (#64)? | A GitHub Actions workflow, `sk-svc-checks`, runs the PR gate's checks on GitHub-hosted runners on every PR and on `main`. The Azure pipelines are unchanged, and `sk-svc-pr` stays the only required check | Public green checks and a README badge, with no agent or service connection to set up. Deploys stay on the agent, which is where the environments are |
| 67 | Which runner for which check? | `windows-checks` on `windows-latest` (lint, Pester, governance, Terraform, promtool); `linux-image` on `ubuntu-latest` (Trivy config scan, image build, Trivy image scan) | The PowerShell checks run on the same OS as the agent. The image and Trivy are Linux containers, and GitHub's Windows runners only run Windows containers |
| 68 | How do the two pipelines stay the same? | Same step names and the same pinned versions; `tests/GitHubActions.Parity.Tests.ps1` fails when a template step has no GitHub step of the same name, or when a pinned version differs | Two copies of the checks drift silently; the test makes drift fail the PR gate in both pipelines |
| 69 | Workflow hardening | `permissions: contents: read`, actions pinned to full commit SHAs, `persist-credentials: false`, the branch name passed through `env` rather than pasted into the script, the promtool download checked against the release's SHA-256 | A public repository's workflow runs on PRs from anyone; a movable tag or an injected branch name must not run code in CI. No Dependabot: its `dependabot/*` branch names would fail the branch policy, so actions are bumped by hand through a `feature/*` PR |
