# Manual steps (only you can do these)

These steps need your accounts and the web UIs. Do them after the build is finished and verified locally.

## A. GitHub

1. Create a **public** GitHub repository (empty, no README).
2. In the repo folder: `git remote add origin <url>` then `git push -u origin main`. Check that nothing secret is tracked first (`git ls-files`).
3. Repository settings: allow **squash merging only**, with the default commit message set to "Pull request title" (so commits end with `(#n)`). Turn off merge commits and rebase merging.

## B. Azure DevOps

1. Sign in at dev.azure.com with a personal Microsoft account and create a free **organization**. No Azure subscription or card is needed.
2. Create a **public** project. If public projects are unavailable, check Organization settings, Policies, and the "Allow public projects" setting.
3. Create a **PAT** with the scope *Agent Pools: Read & manage*, short expiry (a few days). It is only for registering the agent. **Never commit it or paste it into chat.**
4. Create an agent pool named `sk-local` (Organization settings, Agent pools; make it self-hosted).
5. Download the Windows agent from the pool (New agent), unzip it outside the repo, and register it with `config.cmd` (URL of your org, auth type PAT, pool `sk-local`). Run it **interactively** with `run.cmd` in a PowerShell window under your own account (Docker Desktop must be running). A Windows service account may not reach Docker Desktop.
6. Install the **Azure Pipelines** app for GitHub and create two pipelines from the YAML files: `pipelines/pr.yml` (name `sk-svc-pr`) and `pipelines/main.yml` (name `sk-svc-main`).
7. Create Environments `sk-svc-dev` and `sk-svc-prod`. On `sk-svc-prod` add an **Approvals** check with yourself as approver.

## C. Enforce the PR gate on GitHub

1. Settings, Branches, add a rule for `main`: require a pull request, require the `sk-svc-pr` status check to pass, require branches to be up to date, no direct pushes.
2. Only after the pipelines work and all bootstrap commits are on `main`, create the baseline tag: `git tag governance-baseline` then `git push origin governance-baseline`. From then on every change goes through a PR.

## D. The three evidence runs

1. **Blocked PR:** on a `feature/...` branch, introduce a lint error or a failing test, open a PR, and let `sk-svc-pr` fail. Link the run.
2. **Green prod deploy:** merge a good PR (twice, so prod has two releases in its history). Approve the prod stage. Link the green run.
3. **Bad release caught and rolled back:** queue `sk-svc-main` manually with `prodFailRate` set to `1`. Dev passes, the prod smoke test fails, and the rollback step runs. Link that run, and confirm `/version` on prod shows the previous release.

## E. Alert evidence and submission

1. Run the alert demo from the README and save a screenshot to `docs/evidence/` (Prometheus alert firing, or Alertmanager).
2. Fill in `docs/EVIDENCE.md` (links) and `docs/TIME.md` (honest time per part, what you skipped, what you would do next). Stop at 8 hours.
3. Keep the GitHub repo and the Azure DevOps project **public** until they have reviewed.
4. Email **hello@hellovibe.in**, subject `Take-home: DevOps Engineer (Cloud) - Sai Kaushik`, with the GitHub link, the Azure DevOps link, the three run links, and the time note.
5. Before the call, re-read `docs/WALKTHROUGH.md` and `RUNBOOK.md`.
