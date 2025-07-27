# Redis Instance (Memorystore)
resource "google_redis_instance" "cache" {
  name           = "innovriddhi-cache-${var.environment}"
  project        = var.project_id
  region         = var.region
  tier           = "STANDARD_HA"
  memory_size_gb = 5
  
  redis_version = "REDIS_6_X"
  display_name  = "InnoVriddhi Location Cache"
  
  authorized_network = google_compute_network.vpc.self_link
  
  redis_configs = {
    maxmemory-policy = "allkeys-lru"
    notify-keyspace-events = "Ex"
  }
  
  labels = {
    environment = var.environment
    purpose     = "location-cache"
  }
}

# Cloud SQL (PostgreSQL) Instance
resource "google_sql_database_instance" "postgres" {
  name             = "innovriddhi-postgres-${var.environment}"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_14"
  
  depends_on = [google_service_networking_connection.private_vpc_connection]
  
  settings {
    tier = "db-custom-2-7680"
    
    disk_size = 100
    disk_type = "PD_SSD"
    
    backup_configuration {
      enabled                        = true
      start_time                     = "19:00"  # 3 AM SGT
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }
    
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.self_link
      require_ssl     = true
    }
    
    
    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
    }
    
    maintenance_window {
      day          = 7  # Sunday
      hour         = 19 # 3 AM SGT
      update_track = "stable"
    }
  }
  
  deletion_protection = false  # Set to true in production
}

# PostgreSQL Databases
resource "google_sql_database" "metadata" {
  name     = "location_metadata"
  project  = var.project_id
  instance = google_sql_database_instance.postgres.name
}

# PostgreSQL User
resource "google_sql_user" "postgres_user" {
  name     = "innovriddhi"
  project  = var.project_id
  instance = google_sql_database_instance.postgres.name
  password = random_password.postgres_password.result
}

# Random password for PostgreSQL
resource "random_password" "postgres_password" {
  length  = 32
  special = true
}

# Store password in Secret Manager
resource "google_secret_manager_secret" "postgres_password" {
  secret_id = "postgres-password-${var.environment}"
  project   = var.project_id
  
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "postgres_password" {
  secret      = google_secret_manager_secret.postgres_password.id
  secret_data = random_password.postgres_password.result
}