# Pub/Sub Topics
resource "google_pubsub_topic" "location_updates" {
  name    = "location-updates"
  project = var.project_id
  
  message_retention_duration = "86400s" # 1 day
  
  labels = {
    environment = var.environment
    purpose     = "location-ingestion"
  }
}

resource "google_pubsub_topic" "location_processed" {
  name    = "location-processed"
  project = var.project_id
  
  message_retention_duration = "86400s"
  
  labels = {
    environment = var.environment
    purpose     = "processed-locations"
  }
}

resource "google_pubsub_topic" "stoppage_detected" {
  name    = "stoppage-detected"
  project = var.project_id
  
  message_retention_duration = "86400s"
  
  labels = {
    environment = var.environment
    purpose     = "stoppage-events"
  }
}

resource "google_pubsub_topic" "geofence_events" {
  name    = "geofence-events"
  project = var.project_id
  
  message_retention_duration = "86400s"
  
  labels = {
    environment = var.environment
    purpose     = "geofence-notifications"
  }
}

resource "google_pubsub_topic" "analytics_events" {
  name    = "analytics-events"
  project = var.project_id
  
  message_retention_duration = "86400s"
  
  labels = {
    environment = var.environment
    purpose     = "analytics-triggers"
  }
}

# Dead Letter Topic
resource "google_pubsub_topic" "dead_letter" {
  name    = "location-dead-letter"
  project = var.project_id
  
  message_retention_duration = "604800s" # 7 days
  
  labels = {
    environment = var.environment
    purpose     = "dead-letter-queue"
  }
}

# Subscriptions
resource "google_pubsub_subscription" "location_ingestion" {
  name    = "location-ingestion-sub"
  topic   = google_pubsub_topic.location_updates.name
  project = var.project_id
  
  ack_deadline_seconds = 60
  
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }
  
  enable_message_ordering = false
  
  labels = {
    environment = var.environment
    service     = "location-ingestion"
  }
}

resource "google_pubsub_subscription" "analytics_processor" {
  name    = "analytics-processor-sub"
  topic   = google_pubsub_topic.location_processed.name
  project = var.project_id
  
  ack_deadline_seconds = 60
  
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  
  labels = {
    environment = var.environment
    service     = "analytics-processor"
  }
}

resource "google_pubsub_subscription" "notification_service" {
  name    = "notification-service-sub"
  topic   = google_pubsub_topic.stoppage_detected.name
  project = var.project_id
  
  ack_deadline_seconds = 30
  
  retry_policy {
    minimum_backoff = "5s"
    maximum_backoff = "300s"
  }
  
  labels = {
    environment = var.environment
    service     = "notification-service"
  }
}