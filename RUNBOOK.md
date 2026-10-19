# RUNBOOK: elevated 5xx after a prod deploy

**Scenario.** A prod deploy went out at 01:50. At 02:00 `ProdHighErrorRate` pages: about a third of prod requests return 5xx.

**Where to look**
| What | Where |
|---|---|
| Alert state | Prometheus http://127.0.0.1:7390/alerts, Alertmanager http://127.0.0.1:7393 |
| Dashboard (rate, 5xx ratio, p95, running version) | Grafana http://127.0.0.1:7391, dashboard "sk-svc" |
| Running version | `Invoke-RestMethod http://127.0.0.1:7312/version` |
| What was deployed, and when | `$HOME/.releaseguard/history/prod.json` (or `$env:RELEASEGUARD_HOME`), and the release audit artifact on the `sk-svc-main` run |
| Container logs | `docker logs --since 15m sksvc-prod-app-prod-1` |

## First 15 minutes

| Time | Action |
|---|---|
| 02:00 | **Acknowledge** the page so others know someone is on it. Open the dashboard and the alert. |
| 02:01 | **Confirm impact.** On the dashboard: prod 5xx ratio about 33% (red line is 5%), request rate normal, p95 latency. Is dev also affected? (If dev is fine, the problem is prod-only: config, data or the release.) |
| 02:02 | **Check what changed.** `/version` on prod; the last entries in `prod.json`; the `sk-svc-main` run that deployed at 01:50 and its release audit (commits, PR numbers, author). The errors started ~10 minutes after a deploy: the deploy is the prime suspect. |
| 02:04 | **Tell people** (first update, see below): "Investigating elevated 5xx on prod since ~01:52, likely the 01:50 deploy. Next update 02:15." |
| 02:05 | **Decide**: rollback or fix forward, using the criteria below. Default is **rollback**. |
| 02:06 | **Act**: run the rollback (commands below). It redeploys the previous release's image and checks `/version`. |
| 02:08 | **Verify**: `/version` shows the previous SHA; `/healthz` is ok; a quick `Send-Traffic.ps1` burst returns only 200s. |
| 02:08-02:13 | **Watch** the 5xx ratio fall on the dashboard. It drops right away for new requests; the 5-minute ratio and the alert clear over the next ~5 minutes. |
| 02:13 | Alert resolved in Alertmanager. If not, or if the ratio does not fall: the deploy was not the cause, so escalate (see below) and keep investigating (logs, database, host). |
| 02:15 | **Update** (second update): "Rolled back prod to <previous SHA> at 02:06; error rate back to normal at 02:1x. Root cause under investigation; bad release blocked from redeploy." Open the incident ticket and keep the timeline. |

## Rollback or fix forward?

**Roll back (the default)** when all of these hold:
- the problem started with, or shortly after, a deploy;
- the previous release was healthy;
- the release did not include an irreversible database migration (our migrations are expand-only and backward compatible, so the old version still works on the new schema).

**Fix forward** only when one of these holds:
- the cause is known, the fix is small, already tested, and faster to ship than a rollback; or
- rolling back is unsafe (for example the previous version cannot read data the new version already wrote, or a migration cannot be undone and the old code breaks on it).

If in doubt, roll back first and fix in daylight. A rollback is one command and is verified automatically.

## Commands

```powershell
# From the repo root, PowerShell 7.
Import-Module ./modules/ReleaseGuard

# 1. Roll back prod to the previous successfully deployed release.
#    Safe to run twice: a second run reports "already rolled back" and does nothing.
#    "Previous release" means another tag, or the same tag with another FAIL_RATE: if the bad
#    release is the current image with a high FAIL_RATE, it goes back to that image with FAIL_RATE 0.
Invoke-Rollback -Environment prod

# 2. Verify the running version is the previous SHA.
Invoke-RestMethod http://127.0.0.1:7312/version
Invoke-RestMethod http://127.0.0.1:7312/healthz

# 3. Confirm requests succeed again (all 200s expected).
pwsh ./scripts/Send-Traffic.ps1 -BaseUrl http://127.0.0.1:7312 -DurationSeconds 20 -RatePerSecond 2

# 4. Watch the 5xx ratio fall (Prometheus query, or the Grafana panel).
#    sum(rate(http_requests_total{job="sk-svc-prod",status=~"5.."}[5m])) / sum(rate(http_requests_total{job="sk-svc-prod"}[5m]))
```

If `Invoke-Rollback` fails:
- **"no previous release"**: there is nothing to roll back to. Fix forward, or redeploy a known-good SHA with `pwsh ./scripts/Invoke-Deploy.ps1 -Environment prod -ImageTag <sha>`.
- **"Docker is not running"**: start Docker Desktop on the agent, then run it again.
- **"health check timed out"**: the old version did not come up either. Check `docker logs`; the problem is probably not the release (host, database, network). Escalate.

## If `ProdDown` pages instead

`ProdDown` means Prometheus cannot scrape prod at all for 2 minutes: the container is stopped, crash-looping or not answering. `ProdHighErrorRate` cannot fire then, because there are no request series.
1. `docker ps -a --filter name=sksvc-prod` and `docker logs --tail 100 sksvc-prod-app-prod-1`: is it running, restarting, or exited?
2. If it stopped right after a deploy, roll back with the commands above.
3. If no deploy happened, start it again (`docker compose -p sksvc-prod --profile prod up -d app-prod` with `IMAGE_TAG` set to the SHA in the deploy history) and look at the host (Docker Desktop, disk, memory).

A prod deploy that fails during migrations exits with code 2 and leaves the previous release running. The pipeline then skips the automatic rollback, so the run is red but prod is unchanged. Fix the migration and deploy again.

## Who to tell, and when

| Who | When | Why |
|---|---|---|
| Engineering lead | At 02:04 (first update) and 02:15 | Owns the decision to escalate and to wake more people |
| Service owner | At 02:04 if not the person on call; again at 02:15 | Knows the code and the recent changes |
| Support lead | At 02:04 and 02:15 | Can answer customers and post a status note |

Updates go to the incident channel, at **5 minutes** (02:04-02:05) and **15 minutes** (02:15) after the page, then every 30 minutes until resolved, then a short "resolved" note. Each update says: impact, what we did, what is next, next update time.

## Post-mortem outline (blameless)

Within 2 working days. Focus on the system and the process, not on people.

1. **Summary**: two or three sentences: what happened, how long, how it was fixed.
2. **Impact**: users and requests affected, error ratio, duration (01:52 to 02:1x), any data impact.
3. **Timeline** (UTC): deploy, first errors, page, acknowledgement, decision, rollback, recovery, all-clear.
4. **Root cause**: what in the release caused the 5xx, and why it was not caught earlier.
5. **Detection**: how fast did the alert fire after impact started? Would a faster or slower alert have been better?
6. **Response**: what we did and how long each step took.
7. **What went well / what went badly / where we got lucky.**
8. **Action items**: each with an owner and a due date. For example: a check that would have caught it in the PR or dev smoke test; a smoke test that covers the failing path; alert tuning.
