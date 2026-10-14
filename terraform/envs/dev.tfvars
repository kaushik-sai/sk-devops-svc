# Dev: one replica, purge protection off so the vault is easy to throw away.
# Never put db_password here; it comes from TF_VAR_db_password.
env                      = "dev"
min_replicas             = 1
max_replicas             = 1
purge_protection_enabled = false
