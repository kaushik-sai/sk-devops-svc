# Terraform: sk-svc on Azure Container Apps

Never applied. There is no Azure subscription; the config is checked with
`fmt`, `validate`, `terraform test` (mocked provider, plan only) and Trivy.

| Path | What it is |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root config: provider pin, one call of the service module |
| `modules/service/` | Resource group, Container Apps environment, Container App, user-assigned identity, Key Vault (RBAC), role assignment, `db-password` secret |
| `envs/dev.tfvars`, `envs/prod.tfvars` | Per-environment values (replicas, purge protection). No secrets |
| `tests/dev.tftest.hcl`, `tests/prod.tftest.hcl` | Plan-only tests with `mock_provider "azurerm"`; each runs against its real tfvars file |
| `tests/mocks/azurerm.tfmock.hcl` | Fake Azure IDs used by the mocked provider |
| `.terraform.lock.hcl` | Locked provider version and checksums (Windows and Linux) |

## Test commands

Run from this `terraform/` folder. `init` must run after the test files exist
(it installs the module the tests call). In PowerShell keep the quotes: without
them PowerShell splits `-var-file=envs/dev.tfvars` at the dot.

```powershell
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
terraform test '-var-file=envs/dev.tfvars'  '-filter=tests\dev.tftest.hcl'
terraform test '-var-file=envs/prod.tfvars' '-filter=tests\prod.tftest.hcl'
```

On Linux or macOS the filter uses a forward slash: `-filter=tests/dev.tftest.hcl`
(Terraform matches the filter against the OS path). A plain `terraform test`
without a var file fails on purpose: `env` and the replica values have no default.

The tests pass a dummy `db_password`; a real run passes it with the
`TF_VAR_db_password` environment variable, never in a tfvars file.

Security scan (from the repo root):

```powershell
trivy config terraform/
trivy config --tf-vars terraform/envs/prod.tfvars terraform/
```

## Before a real apply

- **Remote, encrypted state.** State holds the `db-password` value in plain
  text. Use an azurerm backend on a storage account with encryption, no public
  access, RBAC and state locking; only the pipeline identity may read it.
- **Passwordless pipeline login.** Azure DevOps service connection with
  workload identity federation (OIDC), no client secret. That identity also
  needs `Key Vault Secrets Officer` on the vault to write the secret.
- **A real registry.** Push `sk-svc:<commit SHA>` to Azure Container Registry,
  pull it with the managed identity (`AcrPull`), and pass it as `image`. The
  default image is only a placeholder.
- **Networking and private endpoints.** VNet-integrated Container Apps
  environment, Key Vault private endpoint, then set the vault's network default
  to `Deny` (Trivy AZU-0013 is ignored inline until then).
- **Logging with retention.** Log Analytics workspace for the environment, with
  a set retention period.
- **Tags** (owner, env, cost centre) on every resource.
- **Budgets** and cost alerts on the subscription or resource groups.
- **Region.** Check that Container Apps (and the needed SKUs) are available in
  `southindia`; pick a nearby region if not.
- **Unique Key Vault name.** Vault names are global; add a short unique suffix
  to `kv-sk-svc-<env>`.
