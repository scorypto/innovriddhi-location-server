# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "innovriddhi-vpc-${var.environment}"
  project                 = var.project_id
  auto_create_subnetworks = false
}

# Subnet for GKE
resource "google_compute_subnetwork" "subnet" {
  name          = "innovriddhi-subnet-${var.environment}"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.self_link
  ip_cidr_range = "10.1.0.0/20"
  
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }
  
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }
  
  private_ip_google_access = true
}

# Cloud NAT for private GKE nodes
resource "google_compute_router" "router" {
  name    = "innovriddhi-router-${var.environment}"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.self_link
}

resource "google_compute_router_nat" "nat" {
  name                               = "innovriddhi-nat-${var.environment}"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}