# DESIGN

## Compose to Azure Container Apps

| Local (docker-compose.yml) | Azure (terraform/modules/service) |
|---|---|
| Compose project `sksvc-dev` / `sksvc-prod` | Resource group `rg-sk-svc-<env>` + Container Apps environment `cae-sk-svc-<env>` |
| Service `app-dev` / `app-prod`, image `sk-svc:<sha>` | Container App `ca-sk-svc-<env>`, same image from a registry |
| Port `127.0.0.1:731x -> 8080` | Ingress, `target_port = 8080` |
| Health check on `/healthz` | Liveness and readiness probes on `/healthz` |
| Docker secret `/run/secrets/db_password` | Key Vault secret mounted as a secret volume, `/mnt/secrets/db-password` |
| `environment:` (`FAIL_RATE`, `DB_PASSWORD_FILE`) | Container `env` entries |
| One container per environment | `min/max_replicas`: dev 1, prod 2 |

The app only knows `DB_PASSWORD_FILE`, so the code is identical in both places.

## Secrets and identity

1. The pipeline keeps the database password as a secret variable and passes it to Terraform as `TF_VAR_db_password` (sensitive, no default, never in tfvars or Git). A real pipeline logs in to Azure with workload identity federation (OIDC): no client secret.
2. Terraform writes it to Key Vault `kv-sk-svc-<env>` (RBAC mode, purge protection on in prod).
3. The user-assigned identity `id-sk-svc-<env>` gets **Key Vault Secrets User** on that vault only.
4. The Container App runs as that identity and references the secret by its versionless URL; the platform fetches it and mounts it as a file.

**Caveat:** Terraform state contains the secret value. Real state must be remote, encrypted, locked and readable only by the pipeline identity (or the secret is created outside Terraform). Locally, `Start-Stack.ps1` generates a random password into git-ignored `.secrets/`. On the agent machine there is no vault, so the password and the deploy history live in `C:\svc-app` (set up by `scripts/Initialize-AgentHost.ps1`; the secrets folder is readable only by SYSTEM, Administrators, the agent account and you). That is the stand-in for Key Vault: with a subscription, the pipeline would read the secret from Key Vault through a workload-identity service connection instead.

## PR gate: fail or warn

| Check | Fails the PR | Warns only | Why |
|---|---|---|---|
| PSScriptAnalyzer | Error, Warning | Information | Warnings are real bugs or unclear code; Information is style |
| Pester | any failed test | | Tests are the contract |
| Terraform fmt / validate / test | any failure, or 0 tests run | | Cheap and deterministic |
| Branch policy (`Test-BranchCompliance`) | bad branch name, commit on main without `(#n)` after the baseline | | Governance must not be optional |
| Trivy config (Terraform, Dockerfile) | HIGH, CRITICAL | LOW, MEDIUM | Block what is dangerous; show the rest |
| Trivy image | HIGH, CRITICAL **with a fix** | lower severities, unfixed CVEs | Fail on what the team can act on. Exceptions live in `.trivyignore.yaml`: one file path each, a reason, and an expiry date |
| promtool rule tests | | yes (non-blocking) | promtool may be missing on an agent |

On GitHub, `main` accepts changes only through a pull request, squash-merged, with `sk-svc-pr` passing; required reviewers are 0 only because this is a one-person repository (an author cannot approve their own PR). The same checks also run publicly on GitHub Actions (`sk-svc-checks`), with the same fail/warn rules; that run is for visibility and is not a required check. Trivy has no Compose scanner; the Compose file is hardened by hand (no capabilities, `no-new-privileges`, localhost-only ports, no DB port).

## Branching and promotion

Trunk-based: short-lived `feature/*` branches, squash-merged into `main`. Every merge to `main` builds **one** image, `sk-svc:<sha>`, that goes to dev and then, after approval, the **same image** goes to prod. Environments are pipeline stages, not branches. A long-lived `dev` branch is not needed while every change on `main` is meant to ship. If unrelated changes later need to ship independently, add a `dev` integration branch that builds and deploys to dev, and cherry-pick or merge only release-ready commits into `main` for prod (this needs `^dev$` in `policy.json` and a `dev` trigger in the pipeline).

## Fifteen pipelines sharing the agents

- **Capacity:** one free parallel job means queues; buy parallel jobs and run a pool of agents selected by demands, not one named machine.
- **One Docker daemon is shared state:** project names, ports and networks must be unique per pipeline (or one agent per pipeline); prune old images and containers.
- **Ephemeral agents** (scale-set or container agents) start clean every job; deploy history moves to shared storage.
- **Pinned tools** (Pester, PSScriptAnalyzer, Trivy image, Terraform lock file) so every agent behaves the same.
- **Exclusive lock** on `sk-svc-prod` so two releases never deploy at once; prod deploys get queue priority over PR checks. Shared templates are versioned by tag.

## Keeping Azure spend visible

Tags on every resource (`service`, `env`, `owner`); a budget per resource group with alerts at 50/80/100%; dev scales to zero out of hours; Log Analytics retention and daily cap; a monthly cost review by tag.

## Other notes

- **Rollback** (`Invoke-Rollback`) redeploys the previous successful tag from the deploy history (`~/.releaseguard/history/<env>.json`, outside the workspace) with `FAIL_RATE=0`, verifies `/version`, and is a no-op when run twice. It does **not** undo migrations, so every migration must be backward compatible (expand now, contract in a later release).
- **Registry:** images stay local on the single agent (dev and prod run on the same machine). With a real registry (ACR) the build pushes `sk-svc:<sha>` once, deploy stages pull that digest, the Container App pulls it with `AcrPull` on its identity, and Trivy also scans in the registry.
