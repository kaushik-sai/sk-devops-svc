# HelloVibe DevOps Take-Home: Checklist

Budget: 6-8 hours of work. Due 72 hours after receipt. Stop at 8 hours and write down what you would do next.
Commit as you go. They read the history.

Scoring: Pipeline 30 | PowerShell 25 | Container + Terraform 20 | Operations 15 | Writing 10

---

## 0. Setup (do first, ~30 min, not counted in parts)

- [ ] Create public GitHub repo and push this scaffold
- [ ] Create free Azure DevOps org + **public** project
- [ ] Install: PowerShell 7, Pester 5, PSScriptAnalyzer, Git
- [ ] Install: Docker Desktop / Rancher Desktop / Colima + Docker Compose
- [ ] Install: Terraform 1.7+ (or OpenTofu), Trivy (or Checkov)
- [ ] Create PAT (Agent Pools: Read & manage) for agent registration only. **Never commit it.**
- [ ] Register self-hosted agent on laptop (script it in `scripts/`)
- [ ] Decide and note: registry = Docker Hub / GHCR / local on agent
- [ ] Start a time log in `docs/TIME.md`

## Part 3: Service, container, Terraform (~2 hrs). Build this first; Parts 1 and 2 depend on it

### Service
- [ ] Tiny HTTP service (any language; PowerShell + Pode is fine) in `app/`
- [ ] `GET /healthz`
- [ ] `GET /version` returns the Git commit SHA it was built from
- [ ] `GET /metrics` in Prometheus format (request count, errors by status class)

### Container
- [ ] Multi-stage Dockerfile, **non-root user**, small final image
- [ ] SHA passed as build arg and baked into the image
- [ ] `docker-compose.yml`: `dev` and `prod` from one file, different ports, health checks

### Terraform (never applied)
- [ ] One module: Container Apps environment + app
- [ ] User-assigned managed identity
- [ ] Key Vault, app reads one secret
- [ ] `dev.tfvars` and `prod.tfvars` from the same module
- [ ] Prod: 2 replicas + purge protection
- [ ] `terraform test` with `mock_provider "azurerm"`, **at least 3 assertions** (e.g. prod replica count)
- [ ] Note what you would add before a real apply (remote state, RBAC, networking, etc.)

## Part 2: ReleaseGuard PowerShell module (~1.5 hrs)

Every command needs: Pester tests, comment-based help, clean PSScriptAnalyzer, proper error handling.

- [ ] Module scaffold: `ReleaseGuard.psd1` / `.psm1`, Public/Private split
- [ ] PSScriptAnalyzer settings file in repo root
- [ ] **`Test-BranchCompliance`**
  - [ ] Input: repo path
  - [ ] Checks branch names against a policy you define (document the policy)
  - [ ] Flags commits that reached `main` without a PR
  - [ ] Readable report, **exits non-zero** on violation
  - [ ] Pester tests (use a temp git repo fixture)
- [ ] **`New-ReleaseAudit`**
  - [ ] Input: two Git refs
  - [ ] Writes Markdown **and** JSON: commits, authors, PR numbers, image tag, checks passed
  - [ ] Pester tests
- [ ] **`Invoke-Rollback`**
  - [ ] Input: environment name
  - [ ] Finds previously deployed image tag, redeploys, verifies `/version`
  - [ ] Idempotent (safe to run twice)
  - [ ] Handles: no previous release, Docker not running, health check timeout
  - [ ] Pester tests (mock docker)

## Part 1: Azure Pipelines (~2.5 hrs)

Runs end to end on the self-hosted agent. Something you would hand to a team of ten.

### PR validation
- [ ] PSScriptAnalyzer
- [ ] Pester
- [ ] `terraform fmt -check`, `validate`, `test`
- [ ] Trivy or Checkov config scan
- [ ] Image build
- [ ] Image vulnerability scan
- [ ] Decide what **fails** vs. what **warns**, and document why (put it in DESIGN.md)
- [ ] Branch policy on `main` enforcing it (build validation + min reviewers + no direct push)
- [ ] `Test-BranchCompliance` runs in the PR stage

### Merge to main
- [ ] Build **once**, tag with commit SHA (never only `latest`)
- [ ] Deploy to `dev` (Compose project on the agent)
- [ ] Smoke test: `/version` returns that SHA

### Prod
- [ ] Promote the **same image** (no rebuild) to `prod` (second Compose project, other port)
- [ ] Azure DevOps **Environment** with an **approval check**
- [ ] Prod smoke test; on failure **auto-rollback** via `Invoke-Rollback`
- [ ] `New-ReleaseAudit` output attached to every prod deploy as an artifact

### Structure
- [ ] Stages/jobs from YAML **templates** reused by dev and prod
- [ ] Config in variable groups or template parameters, no copy-paste
- [ ] Optional: migrations stage (numbered SQL to Postgres container, idempotent)

### Evidence (the three required runs)
- [ ] **Run 1:** PR blocked by your checks
- [ ] **Run 2:** green deploy to prod
- [ ] **Run 3:** bad release deliberately broken, caught, rolled back
- [ ] Links recorded in `docs/EVIDENCE.md`

## Part 4: Operations and design (~1 hr)

- [ ] Prometheus + Alertmanager added to Compose
- [ ] One alert rule you would actually want to be woken for (symptom-based, e.g. 5xx ratio, with `for:` and sensible threshold)
- [ ] Make it fire; screenshot in `docs/evidence/`
- [ ] **RUNBOOK.md**: prod deploy at 01:50, alert at 02:00, a third of requests 5xx
  - [ ] First 15 minutes, minute by minute
  - [ ] Rollback vs. fix-forward decision criteria
  - [ ] Who you tell, and when
  - [ ] Post-mortem outline
- [ ] **DESIGN.md** (one page):
  - [ ] Compose to Terraform / Container Apps mapping
  - [ ] Secrets + identity flow: Key Vault to pipeline to app
  - [ ] What changes when 15 pipelines share your agents
  - [ ] Keeping Azure spend visible and under control

## Final checks before submitting

- [ ] Fresh-machine test: README bring-up in 1-2 commands, and teardown, works
- [ ] PSScriptAnalyzer clean, all Pester tests green
- [ ] `terraform fmt`, `validate`, `test` green
- [ ] **Secret scan**: no PATs, tokens, `.tfstate`, `.env` in repo or history
- [ ] Commit history is readable (small, meaningful commits)
- [ ] You can explain every line of code (follow-up call walks through it)
- [ ] GitHub repo and Azure DevOps project are both **public**
- [ ] `docs/TIME.md`: time spent and what you skipped, plus what you would do next
- [ ] Email **hello@hellovibe.in**, subject: `Take-home: DevOps Engineer (Cloud) - Sai Kaushik`
  - [ ] GitHub link + Azure DevOps link
  - [ ] Links to the three pipeline runs
  - [ ] Note on time spent and skipped items
- [ ] Keep both public until they have reviewed

## After submit

Review within 3 working days, then a 45-min call: half repo walkthrough, half live run of the 02:00 scenario. Re-read RUNBOOK.md beforehand.
