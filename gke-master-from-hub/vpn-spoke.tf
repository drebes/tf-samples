resource "google_compute_router" "spoke" {
  count   = local.enable_vpn ? 1 : 0
  name    = "spoke-${local.test_id}"
  network = google_compute_network.spoke.name
  region  = local.region

  bgp {
    asn               = local.spoke_asn
    advertise_mode    = "CUSTOM"
    advertised_groups = []
    advertised_ip_ranges {
      range = local.spoke_custom_announce
    }
  }
}

resource "google_compute_ha_vpn_gateway" "spoke" {
  count    = local.enable_vpn ? 1 : 0
  provider = google-beta
  name     = "spoke-gw-${local.test_id}"
  network  = google_compute_network.spoke.self_link
  region   = local.region
}

resource "google_compute_vpn_tunnel" "spoke" {
  provider      = google-beta
  count         = local.enable_vpn ? 1 : 0
  name          = "spoke-hub-${count.index}-${local.test_id}"
  shared_secret = random_string.vpn-secret[0].result
  region        = local.region
  router        = google_compute_router.spoke[0].name

  vpn_gateway           = google_compute_ha_vpn_gateway.spoke[0].self_link
  vpn_gateway_interface = count.index % 2
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.hub[0].self_link
}

resource "google_compute_router_interface" "spoke" {
  provider   = google-beta
  count      = local.enable_vpn ? 1 : 0
  name       = "spoke-hub-${count.index}-${local.test_id}"
  router     = google_compute_router.spoke[0].name
  region     = var.region
  ip_range   = format("169.254.1.%d/30", count.index + 1 * 4 - 2)
  vpn_tunnel = google_compute_vpn_tunnel.spoke[count.index].name
}

resource "google_compute_router_peer" "spoke" {
  provider                  = google-beta
  count                     = local.enable_vpn ? 1 : 0
  name                      = "spoke-hub-${count.index}-${local.test_id}"
  router                    = google_compute_router.spoke[0].name
  region                    = var.region
  peer_ip_address           = format("169.254.1.%d", count.index + 1 * 4 - 3)
  peer_asn                  = local.hub_asn
  advertised_route_priority = 1000
  interface                 = google_compute_router_interface.spoke[count.index].name
}


