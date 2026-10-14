# HelloVibe DevOps Take-Home: Checklist

Budget: 6-8 hours of work. Due 72 hours after receipt. Stop at 8 hours and write down what you would do next.
Commit as you go. They read the history.

Ticked = verified on the build machine. Items that need the Azure DevOps agent, GitHub settings or a screenshot stay open until done; see [docs/VERIFY_LOCALLY.md](docs/VERIFY_LOCALLY.md).

Scoring: Pipeline 30 | PowerShell 25 | Container + Terraform 20 | Operations 15 | Writing 10

---

## 0. Setup (do first, ~30 min, not counted in parts)

- [x] Create public GitHub repo and push this scaffold
- [x] Create free Azure DevOps org + **public** project (private: public projects are retired; see DECISIONS #64)
- [x] Install: PowerShell 7, Pester 5, PSScriptAnalyzer, Git
- [x] Install: Docker Desktop / Rancher Desktop / Colima + Docker Compose
- [x] Install: Terraform 1.7+ (or OpenTofu), Trivy (or Checkov)
- [x] Create PAT (Agent Pools: Read & manage) for agent registration only. **Never commit it.**
- [x] Register self-hosted agent on laptop (registered with `config.cmd`; host prepared by `scripts/Initialize-AgentHost.ps1`)
- [x] Decide and note: registry = Docker Hub / GHCR / local on agent
- [ ] Start a time log in `docs/TIME.md`

## Part 3: Service, container, Terraform (~2 hrs). Build this first; Parts 1 and 2 depend on it

### Service
- [x] Tiny HTTP service (any language; PowerShell + Pode is fine) in `app/`
- [x] `GET /healthz`
- [x] `GET /version` returns the Git commit SHA it was built from
- [x] `GET /metrics` in Prometheus format (request count, errors by status class)

### Container
- [x] Multi-stage Dockerfile, **non-root user**, small final image
- [x] SHA passed as build arg and baked into the image
- [x] `docker-compose.yml`: `dev` and `prod` from one file, different ports, health checks

### Terraform (never applied)
- [x] One module: Container Apps environment + app
- [x] User-assigned managed identity
- [x] Key Vault, app reads one secret
- [x] `dev.tfvars` and `prod.tfvars` from the same module
- [x] Prod: 2 replicas + purge protection
- [x] `terraform test` with `mock_provider "azurerm"`, **at least 3 assertions** (e.g. prod replica count)
- [x] Note what you would add before a real apply (remote state, RBAC, networking, etc.)

## Part 2: ReleaseGuard PowerShell module (~1.5 hrs)

Every command needs: Pester tests, comment-based help, clean PSScriptAnalyzer, proper error handling.

- [x] Module scaffold: `ReleaseGuard.psd1` / `.psm1`, Public/Private split
- [x] PSScriptAnalyzer settings file in repo root
- [x] **`Test-BranchCompliance`**
  - [x] Input: repo path
  - [x] Checks branch names against a policy you define (document the policy)
  - [x] Flags commits that reached `main` without a PR
  - [x] Readable report, **exits non-zero** on violation
  - [x] Pester tests (use a temp git repo fixture)
- [x] **`New-ReleaseAudit`**
  - [x] Input: two Git refs
  - [x] Writes Markdown **and** JSON: commits, authors, PR numbers, image tag, checks passed
  - [x] Pester tests
- [x] **`Invoke-Rollback`**
  - [x] Input: environment name
  - [x] Finds previously deployed image tag, redeploys, verifies `/version`
  - [x] Idempotent (safe to run twice)
  - [x] Handles: no previous release, Docker not running, health check timeout
  - [x] Pester tests (mock docker)

## Part 1: Azure Pipelines (~2.5 hrs)

Runs end to end on the self-hosted agent. Something you would hand to a team of ten.

### PR validation
- [x] PSScriptAnalyzer
- [x] Pester
- [x] `terraform fmt -check`, `validate`, `test`
- [x] Trivy or Checkov config scan
- [x] Image build
- [x] Image vulnerability scan
- [x] Decide what **fails** vs. what **warns**, and document why (put it in DESIGN.md)
- [x] Branch policy on `main` enforcing it (build validation + min reviewers + no direct push) (reviewers: 0, one-person repo; see DECISIONS #65)
- [x] `Test-BranchCompliance` runs in the PR stage

### Merge to main
- [x] Build **once**, tag with commit SHA (never only `latest`)
- [x] Deploy to `dev` (Compose project on the agent)
- [x] Smoke test: `/version` returns that SHA

### Prod
- [x] Promote the **same image** (no rebuild) to `prod` (second Compose project, other port)
- [x] Azure DevOps **Environment** with an **approval check**
- [ ] Prod smoke test; on failure **auto-rollback** via `Invoke-Rollback`
- [x] `New-ReleaseAudit` output attached to every prod deploy as an artifact

### Structure
- [x] Stages/jobs from YAML **templates** reused by dev and prod
- [x] Config in variable groups or template parameters, no copy-paste
- [x] Optional: migrations stage (numbered SQL to Postgres container, idempotent)

### Evidence (the three required runs)
- [ ] **Run 1:** PR blocked by your checks
- [ ] **Run 2:** green deploy to prod
- [ ] **Run 3:** bad release deliberately broken, caught, rolled back
- [ ] Links recorded in `docs/EVIDENCE.md`

## Part 4: Operations and design (~1 hr)

- [x] Prometheus + Alertmanager added to Compose
- [x] One alert rule you would actually want to be woken for (symptom-based, e.g. 5xx ratio, with `for:` and sensible threshold)
- [ ] Make it fire; screenshot in `docs/evidence/`
- [x] **RUNBOOK.md**: prod deploy at 01:50, alert at 02:00, a third of requests 5xx
  - [x] First 15 minutes, minute by minute
  - [x] Rollback vs. fix-forward decision criteria
  - [x] Who you tell, and when
  - [x] Post-mortem outline
- [x] **DESIGN.md** (one page):
  - [x] Compose to Terraform / Container Apps mapping
  - [x] Secrets + identity flow: Key Vault to pipeline to app
  - [x] What changes when 15 pipelines share your agents
  - [x] Keeping Azure spend visible and under control

## Final checks before submitting

- [x] Fresh-machine test: README bring-up in 1-2 commands, and teardown, works
- [x] PSScriptAnalyzer clean, all Pester tests green
- [x] `terraform fmt`, `validate`, `test` green
- [x] **Secret scan**: no PATs, tokens, `.tfstate`, `.env` in repo or history
- [x] Commit history is readable (small, meaningful commits)
- [ ] You can explain every line of code (follow-up call walks through it)
- [ ] GitHub repo and Azure DevOps project are both **public** (GitHub public; Azure DevOps cannot be, see DECISIONS #64)
- [ ] `docs/TIME.md`: time spent and what you skipped, plus what you would do next
- [ ] Email **hello@hellovibe.in**, subject: `Take-home: DevOps Engineer (Cloud) - Sai Kaushik`
  - [ ] GitHub link + Azure DevOps link
  - [ ] Links to the three pipeline runs
  - [ ] Note on time spent and skipped items
- [ ] Keep both public until they have reviewed

## After submit

Review within 3 working days, then a 45-min call: half repo walkthrough, half live run of the 02:00 scenario. Re-read RUNBOOK.md beforehand.
