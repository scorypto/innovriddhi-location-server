# Storage Buckets
resource "google_storage_bucket" "terraform_state" {
  name     = "${var.project_id}-terraform-state"
  project  = var.project_id
  location = var.region
  
  force_destroy = false
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    purpose     = "terraform-state"
  }
}

resource "google_storage_bucket" "location_archives" {
  name     = "${var.project_id}-location-archives"
  project  = var.project_id
  location = var.region
  
  force_destroy = false
  
  uniform_bucket_level_access = true
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    purpose     = "location-archives"
  }
}

resource "google_storage_bucket" "analytics_reports" {
  name     = "${var.project_id}-analytics-reports"
  project  = var.project_id
  location = var.region
  
  force_destroy = false
  
  uniform_bucket_level_access = true
  
  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    purpose     = "analytics-reports"
  }
}

resource "google_storage_bucket" "system_backups" {
  name     = "${var.project_id}-system-backups"
  project  = var.project_id
  location = var.region
  
  force_destroy = false
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    purpose     = "system-backups"
  }
}