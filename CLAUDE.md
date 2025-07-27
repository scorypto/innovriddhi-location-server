# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the InnoVd Location Tracking system architecture and documentation repository. It contains comprehensive technical documentation for building a world-class location tracking platform that handles real-time field force management at scale.

## Key Architecture Documents

### Core System Documentation
1. **Location Tracking Architecture** (`docs/location-tracking-architecture.md`) - Complete system design covering current TypeScript/MQTT implementation and proposed migration to Go/Pub/Sub
2. **Go Microservice Blueprint** (`docs/location-tracking-go-microservice.md`) - Detailed implementation guide for high-performance Go services with ClickHouse
3. **GCP Infrastructure Blueprint** (`docs/location-tracking-gcp-infrastructure-blueprint.md`) - Production-ready Terraform configurations for Google Cloud Platform deployment
4. **Migration Strategy** (`docs/location-tracking-migration-strategy.md`) - Step-by-step guide for zero-downtime migration from TypeScript to Go

### Mobile & Dashboard Documentation
1. **Mobile App Migration** (`docs/mobile-app-migration.md` & `docs/mobile-app-location-migration-guide.md`) - Flutter implementation for transitioning from MQTT to Google Pub/Sub
2. **Dashboard Enhancements** (`docs/dashboard-enhancements.md`) - World-class UI/UX improvements for real-time tracking visualization

## Common Development Tasks

### Go Microservice Development

When implementing Go services based on the architecture:
```bash
# Standard Go project structure to follow
location-tracking-service/
├── cmd/           # Main applications
├── internal/      # Private application code
├── pkg/           # Public libraries
└── deployments/   # IaC and Dockerfiles
```

### ClickHouse Development

For time-series data queries:
```sql
-- Use proper partitioning
PARTITION BY toYYYYMM(date)
ORDER BY (company_id, user_id, timestamp)

-- Implement materialized views for real-time aggregations
CREATE MATERIALIZED VIEW location_tracking.locations_5min_mv
```

### GCP Infrastructure

When deploying infrastructure:
```bash
# Use Terraform modules structure
terraform/
├── modules/
│   ├── gke/
│   ├── pubsub/
│   └── databases/
└── environments/
    ├── dev/
    ├── staging/
    └── production/
```

## Architecture Principles

1. **Microservices**: Each service has a single responsibility (ingestion, analytics, geofencing, etc.)
2. **Event-Driven**: Use Google Pub/Sub for decoupled communication
3. **Time-Series Optimization**: ClickHouse for location data, PostgreSQL for metadata
4. **Global Scale**: Multi-region deployment with automatic failover
5. **Cost Optimization**: Spot instances, data tiering, and efficient batching

## Performance Targets

- **Location Updates**: 1M+ per minute
- **API Latency**: <100ms (p95)
- **Dashboard Updates**: Real-time (<1 second)
- **Data Retention**: 90 days hot, 1 year cold storage
- **Uptime**: 99.99% availability

## Migration Approach

The system is designed for gradual migration:
1. **Dual Publishing**: Mobile apps send to both MQTT and Pub/Sub
2. **Shadow Mode**: Go services run alongside TypeScript
3. **Traffic Splitting**: Progressive rollout with Istio
4. **Rollback Ready**: Instant reversion capability at each phase

## Security Considerations

- Service accounts for GCP authentication
- Workload identity for GKE pods
- End-to-end encryption for sensitive location data
- GDPR compliance with configurable retention
- Cloud Armor for DDoS protection

## Testing Strategy

- Unit tests for all business logic
- Integration tests for service communication
- Load testing targeting 100K concurrent devices
- Chaos engineering for resilience validation

## Key Technical Decisions

1. **Go over Node.js**: 10x performance improvement for concurrent operations
2. **ClickHouse over MongoDB**: Optimized for time-series queries
3. **Pub/Sub over MQTT**: Better scalability and managed infrastructure
4. **GKE over VMs**: Container orchestration and auto-scaling
5. **gRPC internally**: Efficient service-to-service communication

## Important Notes

- This repository contains architecture documentation only - no actual implementation code
- The system is designed for Singapore region (asia-southeast1) with DR in Mumbai (asia-south1)
- Cost estimates are based on Google Cloud Platform Singapore pricing
- All code examples are illustrative and need proper error handling in production