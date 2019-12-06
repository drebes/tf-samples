resource "google_compute_router" "hub" {
  count   = local.enable_vpn ? 1 : 0
  name    = "hub-${local.test_id}"
  network = google_compute_network.hub.name
  region  = local.region

  bgp {
    asn               = local.hub_asn
    advertise_mode    = "CUSTOM"
    advertised_groups = []
    advertised_ip_ranges {
      range = local.hub_custom_announce
    }
  }
}

resource "google_compute_ha_vpn_gateway" "hub" {
  count    = local.enable_vpn ? 1 : 0
  provider = google-beta
  name     = "hub-gw-${local.test_id}"
  network  = google_compute_network.hub.self_link
  region   = local.region
}

resource "google_compute_vpn_tunnel" "hub" {
  provider      = google-beta
  count         = local.enable_vpn ? 1 : 0
  name          = "hub-spoke-${count.index}-${local.test_id}"
  shared_secret = random_string.vpn-secret[0].result
  region        = local.region
  router        = google_compute_router.hub[0].name

  vpn_gateway           = google_compute_ha_vpn_gateway.hub[0].self_link
  vpn_gateway_interface = count.index % 2
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.spoke[0].self_link
}

resource "google_compute_router_interface" "hub" {
  provider   = google-beta
  count      = local.enable_vpn ? 1 : 0
  name       = "hub-spoke-${count.index}-${local.test_id}"
  router     = google_compute_router.hub[0].name
  region     = var.region
  ip_range   = format("169.254.1.%d/30", count.index + 1 * 4 - 3)
  vpn_tunnel = google_compute_vpn_tunnel.hub[count.index].name
}

resource "google_compute_router_peer" "hub" {
  provider                  = google-beta
  count                     = local.enable_vpn ? 1 : 0
  name                      = "hub-spoke-${count.index}-${local.test_id}"
  router                    = google_compute_router.hub[0].name
  region                    = var.region
  peer_ip_address           = format("169.254.1.%d", count.index + 1 * 4 - 2)
  peer_asn                  = local.spoke_asn
  advertised_route_priority = 1000
  interface                 = google_compute_router_interface.hub[count.index].name
}


