# Root config: one call of the service module per environment.
# Pick the environment with -var-file=envs/dev.tfvars or envs/prod.tfvars.

module "service" {
  source = "./modules/service"

  env                      = var.env
  location                 = var.location
  image                    = var.image
  min_replicas             = var.min_replicas
  max_replicas             = var.max_replicas
  fail_rate                = var.fail_rate
  purge_protection_enabled = var.purge_protection_enabled
  db_password              = var.db_password
}
