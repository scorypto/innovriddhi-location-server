# GCP Infrastructure Blueprint for Location Tracking System

## Table of Contents
1. [Executive Summary](#1-executive-summary)
2. [Infrastructure Architecture](#2-infrastructure-architecture)
3. [GKE Cluster Configuration](#3-gke-cluster-configuration)
4. [Networking & Security](#4-networking-security)
5. [Data Storage Services](#5-data-storage-services)
6. [Messaging & Streaming](#6-messaging-streaming)
7. [Monitoring & Observability](#7-monitoring-observability)
8. [CI/CD Pipeline](#8-cicd-pipeline)
9. [Disaster Recovery](#9-disaster-recovery)
10. [Terraform Configurations](#10-terraform-configurations)

## 1. Executive Summary

### Infrastructure Goals
- **High Availability**: 99.99% uptime across all regions
- **Auto-scaling**: Handle 10x traffic spikes automatically
- **Security**: Zero-trust architecture with defense in depth
- **Cost Optimization**: Pay-per-use with intelligent resource allocation
- **Global Distribution**: Multi-region deployment capability

### Key GCP Services
- **Google Kubernetes Engine (GKE)**: Container orchestration
- **Cloud Pub/Sub**: Message streaming
- **Cloud SQL**: PostgreSQL for metadata
- **Memorystore**: Redis caching
- **Cloud Storage**: Object storage
- **Cloud CDN**: Content delivery
- **Cloud Armor**: DDoS protection
- **Cloud IAM**: Identity management

## 2. Infrastructure Architecture

### High-Level Design
```
┌─────────────────────────────────────────────────────────────────┐
│                        Global Load Balancer                       │
│                    (Cloud CDN + Cloud Armor)                      │
└────────────────────┬────────────────────┬──────────────────────┘
                     │                    │
        ┌────────────▼────────┐  ┌───────▼──────────┐
        │   Primary Region    │  │ Failover Region  │
        │ (asia-southeast1)   │  │ (asia-south1)    │
        └─────────────────────┘  └──────────────────┘
                     │
        ┌────────────┴───────────────────────┐
        │         GKE Autopilot Cluster      │
        │  ┌─────────────┬──────────────┐   │
        │  │ Workloads   │  Services    │   │
        │  │ ─────────   │  ─────────   │   │
        │  │ • Ingestion │ • Pub/Sub    │   │
        │  │ • Analytics │ • Cloud SQL  │   │
        │  │ • API GW    │ • Memstore   │   │
        │  │ • WebSocket │ • Storage    │   │
        │  └─────────────┴──────────────┘   │
        └────────────────────────────────────┘
```

### Network Architecture
```yaml
VPC Design:
  Name: innovd-location-vpc
  Regions:
    Primary:
      Region: asia-southeast1
      Subnets:
        - gke-subnet: 10.0.0.0/20
        - services-subnet: 10.0.16.0/20
        - management-subnet: 10.0.32.0/20
    Secondary:
      Region: asia-south1
      Subnets:
        - gke-subnet: 10.1.0.0/20
        - services-subnet: 10.1.16.0/20
        - management-subnet: 10.1.32.0/20
```

## 3. GKE Cluster Configuration

### Autopilot Cluster Setup
```yaml
# GKE Autopilot Configuration
apiVersion: container.googleapis.com/v1
kind: Cluster
metadata:
  name: location-tracking-autopilot
spec:
  autopilot:
    enabled: true
  location: asia-southeast1
  network: innovd-location-vpc
  subnetwork: gke-subnet
  releaseChannel:
    channel: REGULAR
  addonsConfig:
    httpLoadBalancing:
      enabled: true
    horizontalPodAutoscaling:
      enabled: true
    networkPolicyConfig:
      enabled: true
    gcePersistentDiskCsiDriverConfig:
      enabled: true
  workloadIdentityConfig:
    workloadPool: innovd-prod.svc.id.goog
```

### Node Pool Configuration (Standard GKE)
```yaml
# For cost optimization with Standard GKE
nodePools:
  - name: default-pool
    config:
      machineType: n2-standard-4
      diskSizeGb: 100
      diskType: pd-ssd
      preemptible: false
      labels:
        workload-type: general
    initialNodeCount: 3
    autoscaling:
      enabled: true
      minNodeCount: 3
      maxNodeCount: 10
    management:
      autoUpgrade: true
      autoRepair: true
      
  - name: spot-pool
    config:
      machineType: n2-standard-4
      diskSizeGb: 100
      diskType: pd-standard
      spot: true  # Cost savings with Spot VMs
      labels:
        workload-type: batch
    initialNodeCount: 2
    autoscaling:
      enabled: true
      minNodeCount: 0
      maxNodeCount: 20
    taints:
      - key: spot
        value: "true"
        effect: NoSchedule
```

### Workload Specifications
```yaml
# Deployment example with resource limits
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
      containers:
      - name: ingestion
        image: gcr.io/innovd-prod/location-ingestion:v2.0.0
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        env:
        - name: PROJECT_ID
          value: "innovd-prod"
        - name: PUBSUB_TOPIC
          value: "location-updates"
        - name: CLICKHOUSE_DSN
          valueFrom:
            secretKeyRef:
              name: clickhouse-credentials
              key: dsn
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

## 4. Networking & Security

### Load Balancing Configuration
```yaml
# Global HTTPS Load Balancer
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: location-api-ingress
  annotations:
    kubernetes.io/ingress.global-static-ip-name: "location-api-ip"
    networking.gke.io/managed-certificates: "location-api-cert"
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.allow-http: "false"
spec:
  rules:
  - host: api.innovd.com
    http:
      paths:
      - path: /v2/locations/*
        pathType: ImplementationSpecific
        backend:
          service:
            name: location-gateway
            port:
              number: 8080
      - path: /v2/analytics/*
        pathType: ImplementationSpecific
        backend:
          service:
            name: analytics-service
            port:
              number: 8080
```

### Cloud Armor Security Policy
```yaml
# DDoS Protection and WAF Rules
security_policy:
  name: location-api-security
  rules:
    # Rate limiting
    - priority: 1000
      match:
        expr:
          expression: "origin.region_code == 'CN'"
      action: "deny(403)"
      
    - priority: 2000
      match:
        expr:
          expression: "inIpRange(origin.ip, '10.0.0.0/8')"
      action: "allow"
      
    - priority: 3000
      match:
        expr:
          expression: "true"
      action: "rate_based_ban"
      rate_limit_options:
        conform_action: "allow"
        exceed_action: "deny(429)"
        rate_limit_threshold:
          count: 1000
          interval_sec: 60
        ban_duration_sec: 600
        
    # OWASP Top 10 Protection
    - priority: 4000
      match:
        expr:
          expression: |
            evaluatePreconfiguredExpr('xss-stable') ||
            evaluatePreconfiguredExpr('sqli-stable') ||
            evaluatePreconfiguredExpr('lfi-stable') ||
            evaluatePreconfiguredExpr('rfi-stable')
      action: "deny(403)"
```

### IAM Configuration
```yaml
# Service Account Bindings
service_accounts:
  - name: location-ingestion-sa
    roles:
      - pubsub.publisher
      - monitoring.metricWriter
      - logging.logWriter
      
  - name: analytics-service-sa
    roles:
      - bigquery.dataViewer
      - storage.objectViewer
      - cloudsql.client
      
  - name: api-gateway-sa
    roles:
      - cloudtrace.agent
      - monitoring.metricWriter
      - secretmanager.secretAccessor

# Workload Identity Binding
kubectl annotate serviceaccount location-ingestion-sa \
  iam.gke.io/gcp-service-account=location-ingestion-sa@innovd-prod.iam.gserviceaccount.com
```

## 5. Data Storage Services

### Cloud SQL Configuration
```hcl
# PostgreSQL for metadata
resource "google_sql_database_instance" "location_metadata" {
  name             = "location-metadata-primary"
  database_version = "POSTGRES_14"
  region           = "asia-southeast1"
  
  settings {
    tier              = "db-custom-4-16384"  # 4 vCPU, 16GB RAM
    availability_type = "REGIONAL"           # High availability
    disk_size         = 100
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    
    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }
    
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
      require_ssl     = true
    }
    
    database_flags {
      name  = "max_connections"
      value = "200"
    }
    
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
  }
  
  replica_configuration {
    failover_target = false
  }
}

# Read Replica
resource "google_sql_database_instance" "location_metadata_replica" {
  name                 = "location-metadata-replica-1"
  database_version     = "POSTGRES_14"
  region               = "asia-southeast1"
  master_instance_name = google_sql_database_instance.location_metadata.name
  
  settings {
    tier      = "db-custom-2-8192"
    disk_size = 100
    
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }
}
```

### ClickHouse on GCE
```hcl
# ClickHouse cluster configuration
resource "google_compute_instance_template" "clickhouse" {
  name_prefix  = "clickhouse-node-"
  machine_type = "n2-highmem-8"  # 8 vCPU, 64GB RAM
  region       = "asia-southeast1"
  
  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    disk_size_gb = 100
    disk_type    = "pd-ssd"
    boot         = true
  }
  
  disk {
    disk_size_gb = 1000
    disk_type    = "pd-ssd"
    boot         = false
    device_name  = "data"
  }
  
  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.services.id
  }
  
  metadata_startup_script = file("scripts/install-clickhouse.sh")
  
  service_account {
    email  = google_service_account.clickhouse.email
    scopes = ["cloud-platform"]
  }
}

# Managed Instance Group
resource "google_compute_instance_group_manager" "clickhouse" {
  name               = "clickhouse-cluster"
  base_instance_name = "clickhouse"
  zone               = "asia-southeast1-a"
  target_size        = 3
  
  version {
    instance_template = google_compute_instance_template.clickhouse.id
  }
  
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }
}
```

### Memorystore Redis Configuration
```hcl
resource "google_redis_instance" "location_cache" {
  name               = "location-cache"
  tier               = "STANDARD_HA"
  memory_size_gb     = 10
  region             = "asia-southeast1"
  location_id        = "asia-southeast1-a"
  alternative_location_id = "asia-southeast1-b"
  
  redis_version      = "REDIS_6_X"
  display_name       = "Location Tracking Cache"
  reserved_ip_range  = "10.0.20.0/29"
  
  redis_configs = {
    maxmemory-policy = "allkeys-lru"
    notify-keyspace-events = "Ex"
  }
  
  persistence_config {
    persistence_mode = "RDB"
    rdb_snapshot_period = "ONE_HOUR"
  }
}
```

## 6. Messaging & Streaming

### Cloud Pub/Sub Configuration
```hcl
# Topics
resource "google_pubsub_topic" "location_updates" {
  name = "location-updates"
  
  message_storage_policy {
    allowed_persistence_regions = ["asia-southeast1"]
  }
  
  schema_settings {
    schema = google_pubsub_schema.location_update.id
    encoding = "JSON"
  }
}

# Schema definition
resource "google_pubsub_schema" "location_update" {
  name = "location-update-schema"
  type = "AVRO"
  definition = file("schemas/location-update.avsc")
}

# Subscriptions
resource "google_pubsub_subscription" "location_ingestion" {
  name  = "location-ingestion-sub"
  topic = google_pubsub_topic.location_updates.name
  
  message_retention_duration = "604800s"  # 7 days
  retain_acked_messages      = false
  ack_deadline_seconds       = 60
  
  expiration_policy {
    ttl = ""  # Never expire
  }
  
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.location_updates_dlq.id
    max_delivery_attempts = 5
  }
  
  push_config {
    push_endpoint = "https://location-ingestion.innovd.com/pubsub"
    
    oidc_token {
      service_account_email = google_service_account.pubsub_invoker.email
    }
  }
}
```

### WebSocket Configuration with Cloud Run
```yaml
# WebSocket service on Cloud Run
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: location-websocket
  annotations:
    run.googleapis.com/cpu-throttling: "false"
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/execution-environment: gen2
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/maxScale: "100"
    spec:
      containerConcurrency: 1000
      timeoutSeconds: 3600  # 1 hour for WebSocket
      containers:
      - image: gcr.io/innovd-prod/location-websocket:v2.0.0
        resources:
          limits:
            cpu: "2"
            memory: "2Gi"
        env:
        - name: REDIS_HOST
          value: "10.0.20.3"
        - name: REDIS_PORT
          value: "6379"
```

## 7. Monitoring & Observability

### Cloud Monitoring Stack
```yaml
# Monitoring configuration
monitoring:
  metrics:
    - name: location_updates_per_second
      type: GAUGE
      unit: "1/s"
      labels:
        - device_type
        - company_id
        
    - name: processing_latency
      type: DISTRIBUTION
      unit: "ms"
      labels:
        - service
        - operation
        
    - name: error_rate
      type: GAUGE
      unit: "%"
      labels:
        - service
        - error_type

# Uptime checks
uptime_checks:
  - name: api-health-check
    monitored_resource:
      type: uptime_url
      host: api.innovd.com
      path: /v2/health
    period: 60s
    timeout: 10s
    
  - name: websocket-health-check
    monitored_resource:
      type: uptime_url
      host: ws.innovd.com
      path: /health
    period: 60s
    timeout: 10s
```

### Logging Configuration
```yaml
# Structured logging setup
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         5
        Log_Level     info
        Daemon        off
        
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
        
    [OUTPUT]
        Name   stackdriver
        Match  *
        resource k8s_container
        k8s_cluster_name location-tracking-cluster
        k8s_cluster_location asia-southeast1
```

### Alerting Policies
```yaml
# Critical alerts
alert_policies:
  - name: high-error-rate
    conditions:
      - display_name: "Error rate > 1%"
        condition_threshold:
          filter: 'resource.type="k8s_container" AND metric.type="custom.googleapis.com/location/error_rate"'
          comparison: COMPARISON_GT
          threshold_value: 0.01
          duration: 300s
    notification_channels:
      - pagerduty-oncall
      - slack-alerts
      
  - name: pubsub-backlog
    conditions:
      - display_name: "Pub/Sub backlog > 10000"
        condition_threshold:
          filter: 'resource.type="pubsub_subscription" AND metric.type="pubsub.googleapis.com/subscription/num_undelivered_messages"'
          comparison: COMPARISON_GT
          threshold_value: 10000
          duration: 300s
    notification_channels:
      - email-engineering
      - slack-alerts
```

## 8. CI/CD Pipeline

### Cloud Build Configuration
```yaml
# cloudbuild.yaml
steps:
  # Run tests
  - name: 'golang:1.21'
    entrypoint: 'go'
    args: ['test', './...']
    env:
      - 'CGO_ENABLED=0'
      - 'GOOS=linux'
      
  # Build container
  - name: 'gcr.io/cloud-builders/docker'
    args: [
      'build',
      '-t', 'gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA',
      '-t', 'gcr.io/$PROJECT_ID/location-ingestion:latest',
      '--build-arg', 'VERSION=$COMMIT_SHA',
      '.'
    ]
    
  # Push to GCR
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '--all-tags', 'gcr.io/$PROJECT_ID/location-ingestion']
    
  # Deploy to GKE
  - name: 'gcr.io/cloud-builders/gke-deploy'
    args:
      - run
      - --filename=k8s/
      - --image=gcr.io/$PROJECT_ID/location-ingestion:$COMMIT_SHA
      - --cluster=location-tracking-cluster
      - --location=asia-southeast1
      
  # Run integration tests
  - name: 'gcr.io/$PROJECT_ID/integration-tests'
    args: ['--endpoint', 'https://api-staging.innovd.com']
    
options:
  machineType: 'N1_HIGHCPU_8'
  
# Trigger configuration
trigger:
  branch:
    name: '^main$'
  included_files:
    - 'cmd/ingestion/**'
    - 'internal/**'
    - 'go.mod'
```

### GitOps with Config Sync
```yaml
# Config management
apiVersion: configmanagement.gke.io/v1
kind: ConfigManagement
metadata:
  name: config-management
spec:
  sourceFormat: unstructured
  git:
    syncRepo: https://github.com/innovd/k8s-config
    syncBranch: main
    secretType: ssh
    policyDir: "environments/production"
```

## 9. Disaster Recovery

### Backup Strategy
```yaml
backup_configuration:
  databases:
    clickhouse:
      schedule: "0 2 * * *"  # Daily at 2 AM
      retention: 30  # days
      location: "gs://innovd-backups/clickhouse"
      
    postgresql:
      schedule: "0 * * * *"  # Hourly
      retention: 7  # days
      point_in_time_recovery: true
      
    redis:
      schedule: "0 */6 * * *"  # Every 6 hours
      retention: 3  # days
      
  kubernetes:
    etcd:
      schedule: "0 */4 * * *"  # Every 4 hours
      retention: 7  # days
      
    persistent_volumes:
      schedule: "0 3 * * *"  # Daily at 3 AM
      retention: 14  # days
```

### Multi-Region Failover
```hcl
# Global load balancer with failover
resource "google_compute_global_forwarding_rule" "default" {
  name       = "location-api-forwarding-rule"
  target     = google_compute_target_https_proxy.default.id
  port_range = "443"
  ip_address = google_compute_global_address.default.address
}

resource "google_compute_backend_service" "default" {
  name                  = "location-api-backend"
  protocol              = "HTTPS"
  timeout_sec           = 30
  enable_cdn            = true
  
  health_checks = [google_compute_health_check.default.id]
  
  backend {
    group                 = google_compute_instance_group.primary.id
    balancing_mode        = "UTILIZATION"
    capacity_scaler       = 1.0
    max_utilization       = 0.8
  }
  
  backend {
    group                 = google_compute_instance_group.secondary.id
    balancing_mode        = "UTILIZATION"
    capacity_scaler       = 0.0  # Standby
    max_utilization       = 0.8
    failover              = true
  }
  
  circuit_breakers {
    max_connections = 1000
    max_requests_per_connection = 2
  }
  
  outlier_detection {
    consecutive_errors = 5
    interval {
      seconds = 30
    }
    base_ejection_time {
      seconds = 30
    }
  }
}
```

### RTO/RPO Targets
| Component | RTO | RPO | Strategy |
|-----------|-----|-----|----------|
| API Services | < 1 min | 0 | Multi-region active-active |
| ClickHouse | < 15 min | < 5 min | Automated restore from snapshots |
| PostgreSQL | < 5 min | < 1 min | Automated failover to replica |
| Redis Cache | < 1 min | N/A | Rebuild from source |
| Pub/Sub | 0 | 0 | Multi-region by default |

## 10. Terraform Configurations

### Main Infrastructure
```hcl
# main.tf
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
  
  backend "gcs" {
    bucket = "innovd-terraform-state"
    prefix = "location-tracking/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.primary_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.primary_region
}

# VPC Module
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 7.0"
  
  project_id   = var.project_id
  network_name = "innovd-location-vpc"
  routing_mode = "GLOBAL"
  
  subnets = [
    {
      subnet_name           = "gke-subnet"
      subnet_ip             = "10.0.0.0/20"
      subnet_region         = var.primary_region
      subnet_private_access = "true"
    },
    {
      subnet_name           = "services-subnet"
      subnet_ip             = "10.0.16.0/20"
      subnet_region         = var.primary_region
      subnet_private_access = "true"
    }
  ]
  
  secondary_ranges = {
    gke-subnet = [
      {
        range_name    = "pods"
        ip_cidr_range = "10.4.0.0/14"
      },
      {
        range_name    = "services"
        ip_cidr_range = "10.8.0.0/20"
      }
    ]
  }
}

# GKE Module
module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-autopilot-public-cluster"
  version = "~> 27.0"
  
  project_id     = var.project_id
  name           = "location-tracking-autopilot"
  region         = var.primary_region
  network        = module.vpc.network_name
  subnetwork     = module.vpc.subnets_names[0]
  
  ip_range_pods     = "pods"
  ip_range_services = "services"
  
  enable_vertical_pod_autoscaling = true
  horizontal_pod_autoscaling      = true
  enable_private_endpoint         = false
  enable_private_nodes            = true
  master_ipv4_cidr_block         = "172.16.0.0/28"
  
  master_authorized_networks = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "all"
    }
  ]
}
```

### Application Deployment
```hcl
# kubernetes.tf
resource "kubernetes_namespace" "location_tracking" {
  metadata {
    name = "location-tracking"
    labels = {
      name        = "location-tracking"
      environment = "production"
    }
  }
}

resource "kubernetes_secret" "clickhouse_credentials" {
  metadata {
    name      = "clickhouse-credentials"
    namespace = kubernetes_namespace.location_tracking.metadata[0].name
  }
  
  data = {
    dsn = "clickhouse://${var.clickhouse_user}:${var.clickhouse_password}@${google_compute_instance_group.clickhouse.instances[0]}:9000/location_tracking"
  }
}

resource "helm_release" "location_services" {
  name       = "location-services"
  repository = "https://charts.innovd.com"
  chart      = "location-tracking"
  version    = "2.0.0"
  namespace  = kubernetes_namespace.location_tracking.metadata[0].name
  
  values = [
    templatefile("${path.module}/helm-values.yaml", {
      project_id     = var.project_id
      clickhouse_dsn = kubernetes_secret.clickhouse_credentials.data.dsn
      redis_host     = google_redis_instance.location_cache.host
      pubsub_topic   = google_pubsub_topic.location_updates.name
    })
  ]
}
```

### Cost Optimization
```hcl
# Preemptible/Spot instances for batch workloads
resource "google_compute_instance_template" "batch_processor" {
  name_prefix  = "batch-processor-"
  machine_type = "n2-standard-8"
  
  scheduling {
    preemptible       = true
    automatic_restart = false
  }
  
  disk {
    source_image = "cos-cloud/cos-stable"
    disk_size_gb = 50
    disk_type    = "pd-standard"
  }
  
  service_account {
    email  = google_service_account.batch_processor.email
    scopes = ["cloud-platform"]
  }
}

# Committed use discounts
resource "google_compute_commitment" "compute_commitment" {
  name        = "location-tracking-commitment"
  region      = var.primary_region
  plan        = "TWELVE_MONTH"
  
  resources {
    type   = "VCPU"
    amount = "100"
  }
  
  resources {
    type   = "MEMORY"
    amount = "400"  # GB
  }
}
```

## Operational Runbooks

### Deployment Checklist
```bash
#!/bin/bash
# deploy.sh

# Pre-deployment checks
echo "Running pre-deployment checks..."
terraform plan -out=tfplan
gcloud container clusters get-credentials location-tracking-autopilot --region=asia-southeast1

# Deploy infrastructure
echo "Deploying infrastructure..."
terraform apply tfplan

# Deploy applications
echo "Deploying applications..."
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/deployments.yaml
kubectl apply -f k8s/services.yaml
kubectl apply -f k8s/ingress.yaml

# Verify deployment
echo "Verifying deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/location-ingestion -n location-tracking
kubectl wait --for=condition=available --timeout=300s deployment/analytics-service -n location-tracking

# Run smoke tests
echo "Running smoke tests..."
./scripts/smoke-tests.sh
```

### Monitoring Dashboard
```json
{
  "dashboardId": "location-tracking-ops",
  "displayName": "Location Tracking Operations",
  "widgets": [
    {
      "title": "Location Updates Rate",
      "xyChart": {
        "dataSets": [{
          "timeSeriesQuery": {
            "timeSeriesFilter": {
              "filter": "metric.type=\"custom.googleapis.com/location/updates_per_second\""
            }
          }
        }]
      }
    },
    {
      "title": "API Latency (p95)",
      "xyChart": {
        "dataSets": [{
          "timeSeriesQuery": {
            "timeSeriesFilter": {
              "filter": "metric.type=\"loadbalancing.googleapis.com/https/request_latencies\"",
              "aggregation": {
                "alignmentPeriod": "60s",
                "perSeriesAligner": "ALIGN_PERCENTILE_95"
              }
            }
          }
        }]
      }
    },
    {
      "title": "Error Rate",
      "xyChart": {
        "dataSets": [{
          "timeSeriesQuery": {
            "timeSeriesFilter": {
              "filter": "metric.type=\"custom.googleapis.com/location/error_rate\""
            }
          }
        }]
      }
    }
  ]
}
```

## Conclusion

This GCP infrastructure blueprint provides a comprehensive, production-ready architecture for the location tracking system. Key benefits:

1. **Scalability**: Auto-scaling at every layer handles growth from 10 to 100,000+ devices
2. **Reliability**: Multi-region deployment with automated failover ensures 99.99% uptime
3. **Security**: Defense-in-depth with Cloud Armor, IAM, and network policies
4. **Cost Efficiency**: Spot instances, committed use discounts, and intelligent resource allocation
5. **Observability**: Comprehensive monitoring, logging, and alerting for proactive operations

The infrastructure is designed to be deployed incrementally, allowing for validation at each stage and easy rollback if needed. With proper implementation, this architecture will support the location tracking system's growth for years to come.