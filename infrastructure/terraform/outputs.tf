# Outputs
output "gke_cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name"
}

output "gke_cluster_endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE cluster endpoint"
  sensitive   = true
}

output "vpc_network_name" {
  value       = google_compute_network.vpc.name
  description = "VPC network name"
}

output "redis_host" {
  value       = google_redis_instance.cache.host
  description = "Redis instance host"
}

output "redis_port" {
  value       = google_redis_instance.cache.port
  description = "Redis instance port"
}

output "postgres_connection_name" {
  value       = google_sql_database_instance.postgres.connection_name
  description = "Cloud SQL connection name"
}

output "postgres_private_ip" {
  value       = google_sql_database_instance.postgres.private_ip_address
  description = "PostgreSQL private IP address"
}

output "pubsub_topics" {
  value = {
    location_updates   = google_pubsub_topic.location_updates.name
    location_processed = google_pubsub_topic.location_processed.name
    stoppage_detected  = google_pubsub_topic.stoppage_detected.name
    geofence_events    = google_pubsub_topic.geofence_events.name
    analytics_events   = google_pubsub_topic.analytics_events.name
  }
  description = "Pub/Sub topic names"
}

output "storage_buckets" {
  value = {
    terraform_state    = google_storage_bucket.terraform_state.name
    location_archives  = google_storage_bucket.location_archives.name
    analytics_reports  = google_storage_bucket.analytics_reports.name
    system_backups     = google_storage_bucket.system_backups.name
  }
  description = "Storage bucket names"
}