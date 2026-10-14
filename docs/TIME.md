# Time spent

About **3 to 4 hours** of my own time in total, within the 6-8 hour budget.

I built this with an AI coding assistant (Claude Code). It wrote most of the code and tests. My time went into planning, platform setup, integration, reviewing and approving its changes, and running the evidence.

| Part | Planned | Actual | Notes |
|------|---------|--------|-------|
| Planning and context | | ~1h | Broke the brief down. Made the design decisions in [DECISIONS.md](DECISIONS.md) (language, ports, names, gates, secrets, alerting). Wrote the build plan and constraints the assistant worked from. |
| Setup | 0.5h | ~1h | Public GitHub repo with branch rules. Azure DevOps org and project. Self-hosted agent on my laptop, running as a dedicated `svc-azagent` account. The two pipelines, the environments and the prod approval. |
| 3: Service, container, Terraform | 2h | ~0.5h | Reviewing and approving the assistant's work. |
| 2: ReleaseGuard | 1.5h | (in the 0.5h above) | Built in parallel with Part 3. |
| 1: Pipeline | 2.5h | ~1h | Wiring GitHub, Azure DevOps and the agent together. Fixing what only showed up on the real agent: PATH and `docker compose` for the service account, and a shared folder for the database password. |
| 4: Ops and design | 1h | ~0.5h | Evidence runs, alert drill and screenshots, reviewing DESIGN and the RUNBOOK. |
| **Total** | 6-8h | **~3-4h** | |

## What I skipped

- **Docker-down rollback, for real.** `Invoke-Rollback`'s "Docker is not running" error is covered by mocked tests only. I did not stop Docker Desktop and run it.
- **Linux.** The scripts are written for PowerShell 7 on Linux too, but I only ran them on Windows.
- **A real Azure apply.** There is no subscription. Terraform is checked with `fmt`, `validate` and mocked `terraform test` only.
- **Required reviewers.** `main` needs a PR and a passing `sk-svc-pr`, but 0 approvals: on a one-person repository I cannot approve my own PRs.
- **A public Azure DevOps project.** Microsoft has retired public projects, so it is private and reviewers get access on request ([DECISIONS #64](DECISIONS.md)).

## What I would do next

- Push images to a registry (ACR) instead of keeping them on the agent, and deploy by digest.
- Take the pipeline's database password from Key Vault through a workload-identity service connection, instead of the shared folder on the agent.
- Use ephemeral agents (scale-set or container agents), so each job starts clean and the deploy history lives in shared storage.
- Run the test suite on a Linux agent as well.
- Add `Invoke-Rollback -ToTag`, to roll back further than one release.
- Add an exclusive lock on `sk-svc-prod`, so two releases can never deploy to prod at the same time.
