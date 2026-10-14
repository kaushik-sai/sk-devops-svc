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
