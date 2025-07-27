# Location Tracking GCP Infrastructure Blueprint

## Table of Contents
1. [Executive Summary](#1-executive-summary)
2. [Infrastructure Architecture](#2-infrastructure-architecture)
3. [Google Kubernetes Engine (GKE)](#3-google-kubernetes-engine-gke)
4. [Google Pub/Sub Configuration](#4-google-pubsub-configuration)
5. [Database Infrastructure](#5-database-infrastructure)
6. [Networking & Security](#6-networking-security)
7. [Monitoring & Observability](#7-monitoring-observability)
8. [CI/CD Pipeline](#8-cicd-pipeline)
9. [Disaster Recovery](#9-disaster-recovery)
10. [Cost Optimization](#10-cost-optimization)

## 1. Executive Summary

### Infrastructure Goals
- **Scalability**: Auto-scale from 10 to 100,000+ devices
- **Reliability**: 99.99% uptime with multi-zone redundancy
- **Security**: Zero-trust architecture with defense in depth
- **Performance**: Sub-100ms latency globally
- **Cost-Effective**: Pay-per-use with automatic optimization

### Key GCP Services
- **Google Kubernetes Engine (GKE)**: Container orchestration
- **Google Pub/Sub**: Message queuing and streaming
- **Cloud SQL + ClickHouse**: Hybrid database solution
- **Cloud Load Balancing**: Global traffic distribution
- **Cloud CDN**: Content delivery
- **Cloud Armor**: DDoS protection
- **Cloud Monitoring**: Observability stack

### Regional Strategy
- **Primary**: asia-southeast1 (Singapore)
- **DR Region**: asia-south1 (Mumbai)
- **CDN POPs**: Global coverage

## 2. Infrastructure Architecture

### High-Level Architecture Diagram
```
┌─────────────────────────────────────────────────────────────────────┐
│                          Global Load Balancer                        │
│                         (Cloud Load Balancing)                       │
└─────────────────┬───────────────────────────────┬───────────────────┘
                  │                               │
        ┌─────────▼─────────┐           ┌─────────▼─────────┐
        │  asia-southeast1  │           │   asia-south1     │
        │  (Primary Region) │           │   (DR Region)     │
        └─────────┬─────────┘           └─────────┬─────────┘
                  │                               │
    ┌─────────────┴─────────────┐   ┌─────────────┴─────────────┐
    │       GKE Cluster         │   │      GKE Cluster          │
    │   ┌─────────────────┐    │   │   ┌─────────────────┐    │
    │   │ Ingestion Pods  │    │   │   │ Ingestion Pods  │    │
    │   ├─────────────────┤    │   │   ├─────────────────┤    │
    │   │ Analytics Pods  │    │   │   │ Analytics Pods  │    │
    │   ├─────────────────┤    │   │   ├─────────────────┤    │
    │   │  Gateway Pods   │    │   │   │  Gateway Pods   │    │
    │   └─────────────────┘    │   │   └─────────────────┘    │
    └───────────────────────────┘   └───────────────────────────┘
                  │                               │
    ┌─────────────┴─────────────┐   ┌─────────────┴─────────────┐
    │    Data Infrastructure    │   │    Data Infrastructure    │
    │  ┌──────────────────┐    │   │  ┌──────────────────┐    │
    │  │   Pub/Sub Topics │    │   │  │   Pub/Sub Topics │    │
    │  ├──────────────────┤    │   │  ├──────────────────┤    │
    │  │  Cloud SQL (PG)  │    │   │  │  Cloud SQL (PG)  │    │
    │  ├──────────────────┤    │   │  ├──────────────────┤    │
    │  │    ClickHouse    │    │   │  │    ClickHouse    │    │
    │  ├──────────────────┤    │   │  ├──────────────────┤    │
    │  │  Cloud Storage   │    │   │  │  Cloud Storage   │    │
    │  └──────────────────┘    │   │  └──────────────────┘    │
    └───────────────────────────┘   └───────────────────────────┘
```

### Terraform Project Structure
```
infrastructure/
├── modules/
│   ├── gke/              # GKE cluster configuration
│   ├── networking/       # VPC, subnets, firewall rules
│   ├── pubsub/          # Pub/Sub topics and subscriptions
│   ├── databases/       # Cloud SQL and ClickHouse
│   ├── storage/         # Cloud Storage buckets
│   ├── monitoring/      # Monitoring and alerting
│   └── security/        # IAM, service accounts
├── environments/
│   ├── dev/             # Development environment
│   ├── staging/         # Staging environment
│   └── production/      # Production environment
├── scripts/
│   ├── init.sh          # Terraform initialization
│   ├── deploy.sh        # Deployment script
│   └── destroy.sh       # Cleanup script
└── main.tf              # Root configuration
```

## 3. Google Kubernetes Engine (GKE)

### Cluster Configuration

#### Production Cluster Specification
```hcl
# modules/gke/main.tf
resource "google_container_cluster" "primary" {
  name     = "${var.project_name}-cluster"
  location = var.region

  # Regional cluster for high availability
  node_locations = [
    "${var.region}-a",
    "${var.region}-b",
    "${var.region}-c",
  ]

  # Initial node count (per zone)
  initial_node_count = 1

  # Cluster configuration
  cluster_autoscaling {
    enabled = true
    resource_limits {
      resource_type = "cpu"
      minimum       = 10
      maximum       = 1000
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 40
      maximum       = 4000
    }
  }

  # Network configuration
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.private.name

  # Security settings
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block = "172.16.0.0/28"
  }

  # Workload identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Add-ons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    vertical_pod_autoscaling {
      enabled = true
    }
    network_policy_config {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }
}
```

#### Node Pool Configuration
```hcl
# Spot instance node pool for cost optimization
resource "google_container_node_pool" "spot_nodes" {
  name       = "${var.project_name}-spot-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  
  # Autoscaling configuration
  autoscaling {
    min_node_count = 1
    max_node_count = 50
  }

  # Node configuration
  node_config {
    preemptible  = true
    machine_type = "n2-standard-4"
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    # Spot instance configuration
    spot = true

    # Labels for pod scheduling
    labels = {
      workload-type = "batch"
      cost-optimization = "spot"
    }

    # Taints for spot instances
    taint {
      key    = "spot-instance"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    # Service account
    service_account = google_service_account.kubernetes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# Regular node pool for critical workloads
resource "google_container_node_pool" "regular_nodes" {
  name       = "${var.project_name}-regular-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  
  autoscaling {
    min_node_count = 3
    max_node_count = 20
  }

  node_config {
    preemptible  = false
    machine_type = "n2-standard-8"
    disk_size_gb = 200
    disk_type    = "pd-ssd"

    labels = {
      workload-type = "critical"
    }

    service_account = google_service_account.kubernetes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
```

### Kubernetes Manifests

#### Namespace Configuration
```yaml
# k8s/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: location-tracking
  labels:
    name: location-tracking
    istio-injection: enabled
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: location-tracking-quota
  namespace: location-tracking
spec:
  hard:
    requests.cpu: "100"
    requests.memory: 200Gi
    limits.cpu: "200"
    limits.memory: 400Gi
    persistentvolumeclaims: "10"
```

#### Deployment Configuration
```yaml
# k8s/deployments/ingestion-service.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: location-ingestion
  namespace: location-tracking
spec:
  replicas: 3
  selector:
    matchLabels:
      app: location-ingestion
  template:
    metadata:
      labels:
        app: location-ingestion
    spec:
      serviceAccountName: location-ingestion-sa
      
      # Anti-affinity for high availability
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - location-ingestion
            topologyKey: kubernetes.io/hostname
      
      containers:
      - name: ingestion
        image: gcr.io/PROJECT_ID/location-ingestion:v2.0.0
        
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 2000m
            memory: 4Gi
        
        env:
        - name: PUBSUB_PROJECT_ID
          value: PROJECT_ID
        - name: CLICKHOUSE_HOST
          valueFrom:
            secretKeyRef:
              name: clickhouse-secret
              key: host
        
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

#### Horizontal Pod Autoscaler
```yaml
# k8s/hpa/ingestion-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: location-ingestion-hpa
  namespace: location-tracking
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: location-ingestion
  
  minReplicas: 3
  maxReplicas: 50
  
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  
  - type: External
    external:
      metric:
        name: pubsub_queue_depth
        selector:
          matchLabels:
            subscription_name: location-updates-sub
      target:
        type: Value
        value: "1000"
  
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 5
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
```

## 4. Google Pub/Sub Configuration

### Topic and Subscription Setup

#### Terraform Configuration
```hcl
# modules/pubsub/main.tf

# Main location updates topic
resource "google_pubsub_topic" "location_updates" {
  name = "location-updates"
  
  labels = {
    environment = var.environment
    service     = "location-tracking"
  }

  message_retention_duration = "86400s" # 24 hours
  
  # Schema validation
  schema_settings {
    schema = google_pubsub_schema.location_update.id
    encoding = "JSON"
  }
}

# Dead letter topic
resource "google_pubsub_topic" "location_updates_dlq" {
  name = "location-updates-dlq"
  
  message_retention_duration = "604800s" # 7 days
}

# Schema definition
resource "google_pubsub_schema" "location_update" {
  name = "location-update-schema"
  type = "AVRO"
  definition = file("${path.module}/schemas/location-update.avsc")
}

# Main subscription with dead letter policy
resource "google_pubsub_subscription" "location_ingestion" {
  name  = "location-ingestion-sub"
  topic = google_pubsub_topic.location_updates.name

  # Message retention
  message_retention_duration = "1800s" # 30 minutes
  retain_acked_messages      = false

  # Acknowledgment deadline
  ack_deadline_seconds = 30

  # Retry policy
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  # Dead letter policy
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.location_updates_dlq.id
    max_delivery_attempts = 5
  }

  # Push configuration for Cloud Run
  push_config {
    push_endpoint = "https://location-ingestion-${var.environment}.a.run.app/pubsub/push"
    
    oidc_token {
      service_account_email = google_service_account.pubsub_invoker.email
    }
  }

  # Enable exactly once delivery
  enable_exactly_once_delivery = true
}
```

#### Additional Topics
```hcl
# Analytics events topic
resource "google_pubsub_topic" "analytics_events" {
  name = "location-analytics-events"
  
  message_retention_duration = "604800s" # 7 days
}

# Real-time updates topic for WebSocket
resource "google_pubsub_topic" "realtime_updates" {
  name = "location-realtime-updates"
  
  # Lower retention for real-time data
  message_retention_duration = "3600s" # 1 hour
}

# Geofence events topic
resource "google_pubsub_topic" "geofence_events" {
  name = "geofence-events"
  
  message_retention_duration = "86400s" # 24 hours
}
```

### Message Flow Configuration

#### Publisher Configuration
```go
// Pub/Sub publisher with best practices
package pubsub

import (
    "context"
    "cloud.google.com/go/pubsub"
)

type Publisher struct {
    client *pubsub.Client
    topic  *pubsub.Topic
}

func NewPublisher(projectID, topicID string) (*Publisher, error) {
    ctx := context.Background()
    client, err := pubsub.NewClient(ctx, projectID)
    if err != nil {
        return nil, err
    }
    
    topic := client.Topic(topicID)
    
    // Configure publishing settings
    topic.PublishSettings = pubsub.PublishSettings{
        NumGoroutines: 10,
        CountThreshold: 100,
        ByteThreshold: 1e6,     // 1MB
        DelayThreshold: 100e6,  // 100ms
        
        // Flow control
        FlowControlSettings: pubsub.FlowControlSettings{
            MaxOutstandingMessages: 1000,
            MaxOutstandingBytes:    1e9, // 1GB
            LimitExceededBehavior:  pubsub.FlowControlBlock,
        },
    }
    
    return &Publisher{
        client: client,
        topic:  topic,
    }, nil
}

func (p *Publisher) Publish(ctx context.Context, msg *LocationUpdate) (string, error) {
    data, err := json.Marshal(msg)
    if err != nil {
        return "", err
    }
    
    result := p.topic.Publish(ctx, &pubsub.Message{
        Data: data,
        Attributes: map[string]string{
            "deviceId":   msg.DeviceID,
            "companyId":  msg.CompanyID,
            "timestamp":  msg.Timestamp.Format(time.RFC3339),
            "version":    "v2",
        },
        OrderingKey: msg.DeviceID, // Ensure ordering per device
    })
    
    return result.Get(ctx)
}
```

## 5. Database Infrastructure

### ClickHouse on GCE

#### Terraform Configuration
```hcl
# modules/databases/clickhouse.tf

# ClickHouse cluster nodes
resource "google_compute_instance" "clickhouse" {
  count = var.clickhouse_node_count
  name  = "clickhouse-node-${count.index + 1}"
  zone  = data.google_compute_zones.available.names[count.index % length(data.google_compute_zones.available.names)]

  machine_type = var.clickhouse_machine_type

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  # Data disk
  attached_disk {
    source      = google_compute_disk.clickhouse_data[count.index].id
    device_name = "data"
    mode        = "READ_WRITE"
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork_name
    
    # No external IP for security
    # Access via Cloud NAT for outbound
  }

  metadata_startup_script = templatefile("${path.module}/scripts/clickhouse-init.sh", {
    cluster_name = var.cluster_name
    shard_id     = floor(count.index / var.replicas_per_shard) + 1
    replica_id   = count.index % var.replicas_per_shard + 1
    zookeeper_hosts = join(",", google_compute_instance.zookeeper[*].network_interface[0].network_ip)
  })

  service_account {
    email  = google_service_account.clickhouse.email
    scopes = ["cloud-platform"]
  }

  tags = ["clickhouse", "database"]
}

# Persistent disks for data
resource "google_compute_disk" "clickhouse_data" {
  count = var.clickhouse_node_count
  name  = "clickhouse-data-${count.index + 1}"
  zone  = data.google_compute_zones.available.names[count.index % length(data.google_compute_zones.available.names)]
  
  type = "pd-ssd"
  size = var.clickhouse_disk_size
  
  # Enable snapshots
  snapshot_schedule_policy = google_compute_resource_policy.hourly_snapshot.id
}

# Internal load balancer for ClickHouse
resource "google_compute_region_backend_service" "clickhouse" {
  name   = "clickhouse-backend"
  region = var.region

  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"

  backend {
    group = google_compute_instance_group.clickhouse.id
  }

  health_checks = [google_compute_health_check.clickhouse.id]
}
```

#### ClickHouse Configuration
```xml
<!-- /etc/clickhouse-server/config.d/cluster.xml -->
<clickhouse>
    <remote_servers>
        <location_tracking_cluster>
            <shard>
                <replica>
                    <host>clickhouse-node-1</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-node-2</host>
                    <port>9000</port>
                </replica>
            </shard>
            <shard>
                <replica>
                    <host>clickhouse-node-3</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-node-4</host>
                    <port>9000</port>
                </replica>
            </shard>
        </location_tracking_cluster>
    </remote_servers>
    
    <zookeeper>
        <node>
            <host>zookeeper-1</host>
            <port>2181</port>
        </node>
        <node>
            <host>zookeeper-2</host>
            <port>2181</port>
        </node>
        <node>
            <host>zookeeper-3</host>
            <port>2181</port>
        </node>
    </zookeeper>
    
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <use_uncompressed_cache>0</use_uncompressed_cache>
            <load_balancing>random</load_balancing>
        </default>
    </profiles>
</clickhouse>
```

### Cloud SQL Configuration

#### PostgreSQL Instance
```hcl
# modules/databases/cloudsql.tf

resource "google_sql_database_instance" "postgres" {
  name             = "${var.project_name}-postgres"
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier              = var.postgres_tier
    availability_type = "REGIONAL"
    disk_size         = var.postgres_disk_size
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      location                       = var.region
      transaction_log_retention_days = 7
      
      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      require_ssl     = true
    }

    database_flags {
      name  = "max_connections"
      value = "500"
    }

    database_flags {
      name  = "shared_buffers"
      value = "256MB"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = true
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
  }

  deletion_protection = true
}

# Read replica for analytics
resource "google_sql_database_instance" "postgres_replica" {
  name                 = "${var.project_name}-postgres-replica"
  database_version     = "POSTGRES_14"
  region              = var.region
  master_instance_name = google_sql_database_instance.postgres.name

  replica_configuration {
    failover_target = false
  }

  settings {
    tier      = var.postgres_replica_tier
    disk_size = var.postgres_disk_size
    disk_type = "PD_SSD"

    database_flags {
      name  = "max_connections"
      value = "200"
    }
  }
}
```

### Redis Configuration

#### Cloud Memorystore
```hcl
# modules/databases/redis.tf

resource "google_redis_instance" "cache" {
  name           = "${var.project_name}-cache"
  tier           = "STANDARD_HA"
  memory_size_gb = var.redis_memory_size
  region         = var.region
  location_id    = var.zone

  authorized_network = var.network_id
  connect_mode      = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_6_X"
  display_name  = "Location Tracking Cache"

  redis_configs = {
    maxmemory-policy = "allkeys-lru"
    timeout          = "300"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 3
        minutes = 0
      }
    }
  }

  labels = {
    environment = var.environment
    service     = "location-tracking"
  }
}

# Redis for session storage
resource "google_redis_instance" "sessions" {
  name           = "${var.project_name}-sessions"
  tier           = "STANDARD_HA"
  memory_size_gb = 2
  region         = var.region

  authorized_network = var.network_id
  redis_version     = "REDIS_6_X"

  redis_configs = {
    maxmemory-policy = "volatile-lru"
    timeout          = "0"
  }
}
```

## 6. Networking & Security

### VPC Configuration

```hcl
# modules/networking/vpc.tf

resource "google_compute_network" "vpc" {
  name                    = "${var.project_name}-vpc"
  auto_create_subnetworks = false
  routing_mode           = "REGIONAL"
}

# Private subnet for GKE
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.project_name}-gke-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.8.0.0/20"
  }

  private_ip_google_access = true
}

# Database subnet
resource "google_compute_subnetwork" "db_subnet" {
  name          = "${var.project_name}-db-subnet"
  ip_cidr_range = "10.1.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true
}

# Cloud NAT for outbound traffic
resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option            = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

### Firewall Rules

```hcl
# modules/networking/firewall.tf

# Allow internal communication
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.project_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    "10.0.0.0/20",  # GKE subnet
    "10.1.0.0/24",  # Database subnet
    "10.4.0.0/14",  # Pod range
    "10.8.0.0/20"   # Service range
  ]
}

# ClickHouse specific rules
resource "google_compute_firewall" "clickhouse" {
  name    = "${var.project_name}-clickhouse"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["9000", "9009", "8123", "9440"]
  }

  source_ranges = ["10.0.0.0/20"]
  target_tags   = ["clickhouse"]
}

# Deny all ingress by default
resource "google_compute_firewall" "deny_all_ingress" {
  name     = "${var.project_name}-deny-all-ingress"
  network  = google_compute_network.vpc.name
  priority = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}
```

### Security Policies

#### Cloud Armor Configuration
```hcl
# modules/security/cloud-armor.tf

resource "google_compute_security_policy" "policy" {
  name = "${var.project_name}-security-policy"

  # Default rule
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default rule"
  }

  # Rate limiting rule
  rule {
    action   = "rate_based_ban"
    priority = "1000"
    
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      
      enforce_on_key = "IP"
      
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
      
      ban_duration_sec = 600
    }
    
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  # Block known bad IPs
  rule {
    action   = "deny(403)"
    priority = "900"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.blocked_ips
      }
    }
  }

  # SQL injection protection
  rule {
    action   = "deny(403)"
    priority = "800"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
  }
}
```

#### IAM Configuration
```hcl
# modules/security/iam.tf

# Service account for GKE workloads
resource "google_service_account" "gke_workload" {
  account_id   = "${var.project_name}-gke-workload"
  display_name = "GKE Workload Identity"
}

# Workload identity binding
resource "google_service_account_iam_binding" "workload_identity" {
  service_account_id = google_service_account.gke_workload.name
  role               = "roles/iam.workloadIdentityUser"
  
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[location-tracking/location-ingestion-sa]"
  ]
}

# Pub/Sub permissions
resource "google_project_iam_member" "pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.gke_workload.email}"
}

# Cloud SQL permissions
resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_workload.email}"
}

# Custom role for minimal permissions
resource "google_project_iam_custom_role" "location_service" {
  role_id     = "locationService"
  title       = "Location Service Role"
  description = "Minimal permissions for location tracking service"
  
  permissions = [
    "pubsub.topics.publish",
    "pubsub.subscriptions.consume",
    "storage.objects.create",
    "storage.objects.get",
    "monitoring.metricDescriptors.create",
    "monitoring.timeSeries.create",
    "logging.logEntries.create"
  ]
}
```

## 7. Monitoring & Observability

### Google Cloud Monitoring

#### Terraform Configuration
```hcl
# modules/monitoring/main.tf

# Uptime checks
resource "google_monitoring_uptime_check_config" "api_health" {
  display_name = "Location API Health Check"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/health"
    port         = "443"
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "api.${var.domain}"
    }
  }

  selected_regions = ["USA", "EUROPE", "ASIA_PACIFIC"]
}

# Custom dashboard
resource "google_monitoring_dashboard" "location_tracking" {
  dashboard_json = jsonencode({
    displayName = "Location Tracking Dashboard"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          xPos   = 0
          yPos   = 0
          width  = 4
          height = 4
          widget = {
            title = "Location Updates/sec"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"custom.googleapis.com/location/updates_per_second\""
                  }
                }
              }]
            }
          }
        },
        {
          xPos   = 4
          yPos   = 0
          width  = 4
          height = 4
          widget = {
            title = "API Latency (p95)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"loadbalancing.googleapis.com/https/request_latencies\""
                    aggregation = {
                      alignmentPeriod = "60s"
                      perSeriesAligner = "ALIGN_PERCENTILE_95"
                    }
                  }
                }
              }]
            }
          }
        }
      ]
    }
  })
}
```

#### Alert Policies
```hcl
# Critical alerts
resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "High Error Rate"
  combiner     = "OR"
  
  conditions {
    display_name = "Error rate > 5%"
    
    condition_threshold {
      filter          = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND resource.type=\"https_lb_rule\" AND metric.label.response_code_class=\"5xx\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.05
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  
  notification_channels = [
    google_monitoring_notification_channel.email.name,
    google_monitoring_notification_channel.pagerduty.name
  ]
  
  alert_strategy {
    auto_close = "1800s"
  }
}

# Performance alerts
resource "google_monitoring_alert_policy" "high_latency" {
  display_name = "High API Latency"
  
  conditions {
    display_name = "p95 latency > 500ms"
    
    condition_threshold {
      filter     = "metric.type=\"loadbalancing.googleapis.com/https/request_latencies\""
      duration   = "300s"
      comparison = "COMPARISON_GT"
      threshold_value = 500
      
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MEAN"
      }
    }
  }
}
```

### Logging Configuration

```hcl
# modules/monitoring/logging.tf

# Log router for long-term storage
resource "google_logging_project_sink" "location_logs" {
  name        = "location-tracking-logs"
  destination = "storage.googleapis.com/${google_storage_bucket.logs.name}"
  
  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="location-tracking"
    severity >= "INFO"
  EOT
  
  unique_writer_identity = true
}

# Log-based metrics
resource "google_logging_metric" "location_updates" {
  name   = "location_updates_count"
  filter = "jsonPayload.event_type=\"location_update\""
  
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    
    labels {
      key         = "device_id"
      value_type  = "STRING"
      description = "Device identifier"
    }
  }
  
  label_extractors = {
    "device_id" = "EXTRACT(jsonPayload.device_id)"
  }
}
```

### Distributed Tracing

```yaml
# k8s/tracing/jaeger.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: location-tracking
spec:
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.50
        ports:
        - containerPort: 16686
        - containerPort: 14268
        env:
        - name: COLLECTOR_ZIPKIN_HOST_PORT
          value: ":9411"
        - name: SPAN_STORAGE_TYPE
          value: elasticsearch
        - name: ES_SERVER_URLS
          value: http://elasticsearch:9200
```

## 8. CI/CD Pipeline

### Cloud Build Configuration

```yaml
# cloudbuild.yaml
steps:
  # Build Go services
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA', '-f', 'cmd/ingestion/Dockerfile', '.']
    
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/location-analytics:$COMMIT_SHA', '-f', 'cmd/analytics/Dockerfile', '.']
    
  # Run tests
  - name: 'golang:1.21'
    args: ['go', 'test', './...', '-v']
    env:
    - 'GO111MODULE=on'
    
  # Push images
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA']
    
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/location-analytics:$COMMIT_SHA']
    
  # Deploy to staging
  - name: 'gcr.io/cloud-builders/gke-deploy'
    args:
    - run
    - --filename=k8s/
    - --location=asia-southeast1
    - --cluster=location-tracking-staging
    - --image=gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA
    
  # Run integration tests
  - name: 'gcr.io/$PROJECT_ID/integration-tests'
    args: ['--endpoint', 'https://staging.api.location.example.com']
    
  # Deploy to production (manual approval required)
  - name: 'gcr.io/cloud-builders/gcloud'
    args: ['builds', 'approve', '$BUILD_ID']
    waitFor: ['-']

timeout: 1800s

options:
  machineType: 'N1_HIGHCPU_8'
  
artifacts:
  images:
  - 'gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA'
  - 'gcr.io/$PROJECT_ID/location-analytics:$COMMIT_SHA'
```

### GitOps with ArgoCD

```yaml
# argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: location-tracking
  namespace: argocd
spec:
  project: default
  
  source:
    repoURL: https://github.com/innovd/location-tracking
    targetRevision: HEAD
    path: k8s/overlays/production
    
  destination:
    server: https://kubernetes.default.svc
    namespace: location-tracking
    
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    
  # Progressive rollout
  rollout:
    steps:
    - setWeight: 20
    - pause: {duration: 10m}
    - setWeight: 40
    - pause: {duration: 10m}
    - setWeight: 60
    - pause: {duration: 10m}
    - setWeight: 80
    - pause: {duration: 10m}
```

## 9. Disaster Recovery

### Backup Strategy

```hcl
# modules/backup/main.tf

# Cloud Storage bucket for backups
resource "google_storage_bucket" "backups" {
  name          = "${var.project_id}-backups"
  location      = var.region
  storage_class = "NEARLINE"
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }
  
  versioning {
    enabled = true
  }
}

# Backup schedule for Cloud SQL
resource "google_sql_database_instance" "postgres" {
  # ... existing configuration ...
  
  backup_configuration {
    enabled                        = true
    start_time                     = "03:00"
    point_in_time_recovery_enabled = true
    location                       = var.region
    
    backup_retention_settings {
      retained_backups = 30
      retention_unit   = "COUNT"
    }
  }
}

# ClickHouse backup job
resource "google_cloud_scheduler_job" "clickhouse_backup" {
  name        = "clickhouse-backup"
  description = "Daily ClickHouse backup"
  schedule    = "0 3 * * *"
  region      = var.region
  
  http_target {
    uri         = "https://backup-service.${var.domain}/clickhouse/backup"
    http_method = "POST"
    
    oauth_token {
      service_account_email = google_service_account.backup.email
    }
  }
  
  retry_config {
    retry_count = 3
  }
}
```

### Multi-Region Failover

```hcl
# Global load balancer with failover
resource "google_compute_global_forwarding_rule" "default" {
  name       = "location-tracking-global"
  target     = google_compute_target_https_proxy.default.id
  port_range = "443"
}

resource "google_compute_backend_service" "default" {
  name                  = "location-tracking-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL"
  
  backend {
    group           = google_compute_region_instance_group_manager.primary.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
  
  backend {
    group           = google_compute_region_instance_group_manager.dr.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 0.0  # Standby region
  }
  
  health_checks = [google_compute_health_check.default.id]
  
  # Automatic failover
  outlier_detection {
    consecutive_errors                    = 5
    interval                              = google_duration.new_from_seconds(30)
    base_ejection_time                    = google_duration.new_from_seconds(30)
    max_ejection_percent                  = 50
    enforcing_consecutive_errors          = 100
    enforcing_success_rate                = 0
    success_rate_minimum_hosts            = 5
    success_rate_request_volume           = 100
    success_rate_stdev_factor             = 1900
    consecutive_gateway_failure           = 5
    enforcing_consecutive_gateway_failure = 100
  }
}
```

### Recovery Procedures

```bash
#!/bin/bash
# disaster-recovery.sh

# Failover to DR region
failover_to_dr() {
    echo "Starting failover to DR region..."
    
    # Update backend service weights
    gcloud compute backend-services update location-tracking-backend \
        --global \
        --update-backend group=regions/asia-southeast1/instanceGroups/primary,capacity-scaler=0.0 \
        --update-backend group=regions/asia-south1/instanceGroups/dr,capacity-scaler=1.0
    
    # Update DNS
    gcloud dns record-sets transaction start --zone=location-zone
    gcloud dns record-sets transaction remove \
        --name=api.location.example.com. \
        --type=A \
        --zone=location-zone \
        --ttl=300 \
        "34.96.123.45"
    gcloud dns record-sets transaction add \
        --name=api.location.example.com. \
        --type=A \
        --zone=location-zone \
        --ttl=60 \
        "35.244.123.45"
    gcloud dns record-sets transaction execute --zone=location-zone
    
    # Verify health checks
    while ! gcloud compute backend-services get-health location-tracking-backend --global | grep -q "HEALTHY"; do
        echo "Waiting for DR region to be healthy..."
        sleep 10
    done
    
    echo "Failover completed successfully"
}
```

## 10. Cost Optimization

### Resource Optimization

```hcl
# Preemptible node pool for batch workloads
resource "google_container_node_pool" "preemptible" {
  name       = "preemptible-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  
  autoscaling {
    min_node_count = 0
    max_node_count = 20
  }
  
  node_config {
    preemptible  = true
    machine_type = "n2-standard-4"
    
    # Spot instances (even cheaper than preemptible)
    spot = true
    
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    labels = {
      workload-type = "batch"
    }
    
    taint {
      key    = "preemptible"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}

# Committed use discounts
resource "google_compute_commitment" "cpu_commitment" {
  name        = "cpu-commitment-1year"
  region      = var.region
  
  resources {
    type   = "VCPU"
    amount = "100"
  }
  
  resources {
    type   = "MEMORY"
    amount = "400"
  }
  
  plan = "TWELVE_MONTH"
}
```

### Auto-scaling Policies

```yaml
# k8s/autoscaling/vpa.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: location-ingestion-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: location-ingestion
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: ingestion
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: 2
        memory: 4Gi
```

### Cost Monitoring

```hcl
# Budget alerts
resource "google_billing_budget" "location_tracking" {
  billing_account = var.billing_account
  display_name    = "Location Tracking Budget"
  
  budget_filter {
    projects = ["projects/${var.project_id}"]
    services = ["services/24E6-581D-38E5"] # Compute Engine
  }
  
  amount {
    specified_amount {
      currency_code = "USD"
      units         = "1000"
    }
  }
  
  threshold_rules {
    threshold_percent = 0.5
  }
  
  threshold_rules {
    threshold_percent = 0.9
  }
  
  threshold_rules {
    threshold_percent = 1.0
  }
  
  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.email.name
    ]
  }
}
```

## Conclusion

This comprehensive GCP infrastructure blueprint provides a production-ready, scalable, and cost-effective foundation for the location tracking system. Key features include:

1. **High Availability**: Multi-zone GKE clusters with automatic failover
2. **Security**: Defense in depth with Cloud Armor, IAM, and network isolation
3. **Scalability**: Auto-scaling at every layer from 10 to 100,000+ devices
4. **Observability**: Comprehensive monitoring, logging, and tracing
5. **Cost Optimization**: Spot instances, committed use discounts, and resource optimization

The infrastructure is designed to be deployed using Terraform, enabling infrastructure as code practices and ensuring reproducible deployments across environments.