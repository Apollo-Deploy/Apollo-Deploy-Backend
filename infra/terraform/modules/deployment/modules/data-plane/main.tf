module "network" {
  source = "../../../docker/network"
}

resource "docker_volume" "postgres_data" {
  count = var.persistence == null ? 0 : 1

  name = var.persistence.postgres_volume_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "redis_data" {
  count = var.persistence == null ? 0 : 1

  name = var.persistence.redis_volume_name

  lifecycle {
    prevent_destroy = true
  }
}

module "infrastructure" {
  source = "../../../docker/infrastructure"

  network_name = module.network.network_name

  db = {
    user        = var.database.user
    password    = var.database.password
    name        = var.database.name
    port_host   = var.database.postgres_port
    volume_name = var.persistence == null ? null : docker_volume.postgres_data[0].name
  }

  pgbouncer = {
    port_host = var.database.pgbouncer_port
  }

  redis = {
    password    = var.database.redis_password
    port_host   = var.database.redis_port
    max_memory  = var.database.redis_max_memory
    volume_name = var.persistence == null ? null : docker_volume.redis_data[0].name
  }
}

module "postgres_backup" {
  count  = var.backup_enabled ? 1 : 0
  source = "../../../docker/postgres-backup"

  network_name      = module.network.network_name
  postgres_host     = module.infrastructure.postgres_container_name
  postgres_user     = var.database.user
  postgres_password = var.database.password
  postgres_sslmode  = "disable"

  schedule = {
    interval_seconds       = 86400
    retry_interval_seconds = 300
    retention_count        = 7
    max_backup_age_seconds = 93600
  }

  offsite_enabled = var.backup.r2_bucket != ""
  offsite = var.backup.r2_bucket == "" ? null : {
    repository        = "s3:https://${var.backup.r2_account_id}.r2.cloudflarestorage.com/${var.backup.r2_bucket}"
    aws_access_key_id = var.backup.r2_access_key_id
    aws_secret_key    = var.backup.r2_secret_access_key
    restic_password   = var.backup.restic_password
  }

  depends_on = [module.infrastructure]
}
