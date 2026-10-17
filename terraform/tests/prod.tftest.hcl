# Prod checks against the real prod values. Run from terraform/:
#   terraform test -var-file=envs/prod.tfvars -filter=tests/prod.tftest.hcl
# (On Windows the filter path needs a backslash: tests\prod.tftest.hcl.)

mock_provider "azurerm" {
  # Use the mock values at plan time too, so IDs are known and comparable.
  override_during = plan
  source          = "./tests/mocks"
}

variables {
  # Test-only values; real ones never live in the repo.
  db_password = "test-only-not-a-secret"
  image       = "example.invalid/sk-svc:test"
}

# 1. The root config plans with envs/prod.tfvars and names follow the pattern.
run "root_plan" {
  command = plan

  assert {
    condition     = output.resource_group_name == "rg-sk-svc-prod"
    error_message = "resource group should be named rg-sk-svc-prod"
  }

  assert {
    condition     = output.container_app_name == "ca-sk-svc-prod"
    error_message = "container app should be named ca-sk-svc-prod"
  }
}

# 2. The service module itself, with the same prod values, so the test can
#    look inside the resources (a root run only sees module outputs).
run "service" {
  command = plan

  module {
    source = "./modules/service"
  }

  assert {
    condition     = azurerm_container_app.this.template[0].min_replicas == 2 && azurerm_container_app.this.template[0].max_replicas == 2
    error_message = "prod should run exactly 2 replicas"
  }

  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled == true
    error_message = "prod Key Vault should have purge protection on"
  }

  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled == true
    error_message = "Key Vault should use RBAC authorization"
  }

  assert {
    condition     = azurerm_container_app.this.identity[0].type == "UserAssigned" && contains(azurerm_container_app.this.identity[0].identity_ids, azurerm_user_assigned_identity.app.id)
    error_message = "app should use the user-assigned identity"
  }

  assert {
    condition     = azurerm_key_vault_secret.db_password.name == "db-password" && azurerm_key_vault_secret.db_password.key_vault_id == azurerm_key_vault.this.id
    error_message = "Key Vault secret db-password should exist in the vault"
  }

  assert {
    condition = anytrue([
      for s in azurerm_container_app.this.secret :
      s.name == "db-password" &&
      s.key_vault_secret_id == azurerm_key_vault_secret.db_password.versionless_id &&
      s.identity == azurerm_user_assigned_identity.app.id
    ])
    error_message = "app secret db-password should reference Key Vault through the identity"
  }

  assert {
    condition = (
      azurerm_role_assignment.app_secrets_user.role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.app_secrets_user.principal_id == azurerm_user_assigned_identity.app.principal_id &&
      azurerm_role_assignment.app_secrets_user.scope == azurerm_key_vault.this.id
    )
    error_message = "identity should have Key Vault Secrets User on the vault"
  }

  assert {
    condition = (
      azurerm_container_app.this.template[0].volume[0].storage_type == "Secret" &&
      azurerm_container_app.this.template[0].container[0].volume_mounts[0].path == "/mnt/secrets" &&
      contains([for e in azurerm_container_app.this.template[0].container[0].env : "${e.name}=${e.value}"], "DB_PASSWORD_FILE=/mnt/secrets/db-password")
    )
    error_message = "db-password should be mounted as a secret file at /mnt/secrets/db-password"
  }

  assert {
    condition = (
      azurerm_container_app.this.ingress[0].target_port == 8080 &&
      azurerm_container_app.this.template[0].container[0].liveness_probe[0].path == "/healthz" &&
      azurerm_container_app.this.template[0].container[0].readiness_probe[0].path == "/healthz"
    )
    error_message = "ingress should target 8080 and probes should use /healthz"
  }
}

# 3. The module rejects max_replicas below min_replicas at plan time, instead of
#    leaving it for the Azure API to refuse during apply.
run "replica_range" {
  command = plan

  module {
    source = "./modules/service"
  }

  variables {
    min_replicas = 3
    max_replicas = 2
  }

  expect_failures = [var.max_replicas]
}
