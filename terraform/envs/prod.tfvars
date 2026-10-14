# Prod: two replicas for availability, purge protection on so a deleted
# vault or secret can be recovered. Never put db_password here.
env                      = "prod"
min_replicas             = 2
max_replicas             = 2
purge_protection_enabled = true
