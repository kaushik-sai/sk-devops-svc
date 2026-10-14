# One environment of sk-svc on Azure Container Apps.
# Secret flow: var.db_password -> Key Vault secret -> Container App secret
# (read with the user-assigned identity) -> file /mnt/secrets/db-password.

locals {
  # Microsoft's usual naming pattern: <type>-<workload>-<env>.
  name_suffix = "sk-svc-${var.env}"

  container_port = 8080
  secrets_path   = "/mnt/secrets"
}

# Gives the tenant ID that Key Vault requires.
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_suffix}"
  location = var.location
}

# The environment is the shared boundary for apps, like a Compose project.
resource "azurerm_container_app_environment" "this" {
  name                = "cae-${local.name_suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# The app's own identity: no stored credentials needed to read Key Vault.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name_suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Network access stays open on purpose: without a VNet and private endpoints
# (see README "Before a real apply") a "Deny" default would block both the
# Container App fetching the secret and Terraform writing it.
#trivy:ignore:AZU-0013
resource "azurerm_key_vault" "this" {
  # A real apply needs a unique suffix here: Key Vault names are global.
  name                = "kv-${local.name_suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Access via Azure RBAC role assignments instead of vault access policies.
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection_enabled
  # Azure's default, written out so the recovery window is visible.
  soft_delete_retention_days = 90
}

# Least privilege: the app identity may only read secret values in this vault.
resource "azurerm_role_assignment" "app_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  # Skips a directory lookup that can fail while a new identity is still replicating.
  principal_type = "ServicePrincipal"
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = var.db_password
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${local.name_suffix}"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # App secret that points at Key Vault. The platform fetches the value with the
  # identity, so the password is not stored in the app definition.
  secret {
    name                = "db-password"
    identity            = azurerm_user_assigned_identity.app.id
    key_vault_secret_id = azurerm_key_vault_secret.db_password.versionless_id
  }

  ingress {
    external_enabled = true
    target_port      = local.container_port

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # A "Secret" volume exposes each app secret as a file named after the secret.
    volume {
      name         = "secrets"
      storage_type = "Secret"
    }

    container {
      name   = "sk-svc"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "FAIL_RATE"
        value = var.fail_rate
      }

      # The app reads the password from this file, same as with the Compose secret.
      env {
        name  = "DB_PASSWORD_FILE"
        value = "${local.secrets_path}/db-password"
      }

      volume_mounts {
        name = "secrets"
        path = local.secrets_path
      }

      liveness_probe {
        transport = "HTTP"
        port      = local.container_port
        path      = "/healthz"
      }

      readiness_probe {
        transport = "HTTP"
        port      = local.container_port
        path      = "/healthz"
      }
    }
  }

  # The identity must be allowed to read the secret before the app starts.
  depends_on = [azurerm_role_assignment.app_secrets_user]
}
