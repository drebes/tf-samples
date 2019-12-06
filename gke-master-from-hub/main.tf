locals {
  ssh_port            = 22
  region              = var.region
  random_zone         = random_shuffle.random_zones.result[0]
  enable_vpn          = var.enable_vpn
  test_id             = "${random_id.random.hex}"
  hub_asn             = 64512
  spoke_asn           = 64513
  hub_custom_announce = google_compute_subnetwork.hub.ip_cidr_range
  # NOTE! Spoke announcement cannot be the private master allocated
  # range exactly as the hub will export this range through the peering
  # back to the spoke as it learns it over BGP through the tunnel. If a
  # VPC (spoke, in this case) has two imported peering routes for the same
  # range from two different peers (hub and GKE master VPC)
  # it will randomly accept one and ignore the other, independent
  # of priority.
  # See https://cloud.google.com/vpc/docs/routes#routeselection (3.a)
  spoke_custom_announce = "192.168.0.0/24"
}

resource "random_id" "random" {
  byte_length = 3
}

resource "google_service_account" "gce" {
  account_id   = "gce-${local.test_id}-instances"
  display_name = "GCE Instances Service Account"
}

resource "google_service_account" "gke" {
  account_id   = "gke-${local.test_id}-instances"
  display_name = "GKE Instances Service Account"
}

resource "google_compute_network" "hub" {
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  name                    = "hub-${local.test_id}"
}

resource "google_compute_network" "spoke" {
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  name                    = "spoke-${local.test_id}"
}

resource "google_compute_subnetwork" "hub" {
  ip_cidr_range            = "10.0.0.0/24"
  name                     = "hub-${local.test_id}"
  network                  = google_compute_network.hub.self_link
  region                   = local.region
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "spoke" {
  ip_cidr_range            = "172.16.0.0/24"
  name                     = "spoke-${local.test_id}"
  network                  = google_compute_network.spoke.self_link
  region                   = local.region
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "k8s-pods"
    ip_cidr_range = "172.16.128.0/17"
  }

  secondary_ip_range {
    range_name    = "k8s-services"
    ip_cidr_range = "172.16.2.0/24"
  }
}

resource "google_compute_network_peering" "hub_spoke" {
  provider             = google-beta
  name                 = "hub-spoke"
  network              = google_compute_network.hub.self_link
  peer_network         = google_compute_network.spoke.self_link
  import_custom_routes = true
  export_custom_routes = true
}

resource "google_compute_network_peering" "spoke_hub" {
  provider             = google-beta
  name                 = "spoke-hub"
  network              = google_compute_network.spoke.self_link
  peer_network         = google_compute_network.hub.self_link
  import_custom_routes = true
  export_custom_routes = true
}

data "google_netblock_ip_ranges" "iap" {
  range_type = "iap-forwarders"
}

resource "google_compute_firewall" "allow_iap_ssh_hub" {
  allow {
    ports    = [local.ssh_port]
    protocol = "tcp"
  }

  name                    = "${google_compute_network.hub.name}-allow-iap-ssh"
  network                 = google_compute_network.hub.name
  source_ranges           = data.google_netblock_ip_ranges.iap.cidr_blocks_ipv4
  target_service_accounts = [google_service_account.gce.email]
}

resource "google_compute_firewall" "allow_iap_ssh_spoke" {
  allow {
    ports    = [local.ssh_port]
    protocol = "tcp"
  }

  name                    = "${google_compute_network.spoke.name}-allow-iap-ssh"
  network                 = google_compute_network.spoke.name
  source_ranges           = data.google_netblock_ip_ranges.iap.cidr_blocks_ipv4
  target_service_accounts = [google_service_account.gce.email]
}

resource "google_compute_firewall" "allow_icmp_hub" {
  allow {
    protocol = "icmp"
  }

  name                    = "${google_compute_network.hub.name}-allow-icmp-private"
  network                 = google_compute_network.hub.name
  source_ranges           = [google_compute_subnetwork.hub.ip_cidr_range, google_compute_subnetwork.spoke.ip_cidr_range, ]
  target_service_accounts = [google_service_account.gce.email]
}

resource "google_compute_firewall" "allow_icmp_spoke" {
  allow {
    protocol = "icmp"
  }

  name                    = "${google_compute_network.spoke.name}-allow-icmp-private"
  network                 = google_compute_network.spoke.name
  source_ranges           = [google_compute_subnetwork.hub.ip_cidr_range, google_compute_subnetwork.spoke.ip_cidr_range, ]
  target_service_accounts = [google_service_account.gce.email]
}

data "google_compute_zones" "all_zones" {
  region = local.region
  status = "UP"
}

resource "random_shuffle" "random_zones" {
  input        = data.google_compute_zones.all_zones.names
  result_count = 1
}

resource "google_compute_instance" "hub_instance" {
  machine_type = "g1-small"
  name         = "hub-${local.test_id}"
  zone         = local.random_zone

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-10-buster-v20191121"
      size  = 10
      type  = "pd-standard"
    }
  }

  metadata_startup_script = "apt-get install -y kubectl"

  network_interface {
    network    = google_compute_network.hub.self_link
    subnetwork = google_compute_subnetwork.hub.self_link
  }

  service_account {
    email = google_service_account.gce.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

resource "google_compute_instance" "spoke_instance" {
  machine_type = "g1-small"
  name         = "spoke-${local.test_id}"
  zone         = local.random_zone

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-10-buster-v20191121"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.spoke.self_link
    subnetwork = google_compute_subnetwork.spoke.self_link
  }

  service_account {
    email = google_service_account.gce.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

resource "google_container_cluster" "spoke_cluster" {
  name     = "spoke-${local.test_id}"
  location = local.region

  initial_node_count = 1

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    service_account = google_service_account.gke.email
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "192.168.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = google_compute_subnetwork.hub.ip_cidr_range
      display_name = google_compute_subnetwork.hub.name
    }
    cidr_blocks {
      cidr_block   = google_compute_subnetwork.spoke.ip_cidr_range
      display_name = google_compute_subnetwork.spoke.name
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "k8s-pods"
    services_secondary_range_name = "k8s-services"
  }

  network    = google_compute_network.spoke.self_link
  subnetwork = google_compute_subnetwork.spoke.self_link

}
