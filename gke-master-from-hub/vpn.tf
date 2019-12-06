resource "random_string" "vpn-secret" {
  count   = local.enable_vpn ? 1 : 0
  length  = 64
  special = false
}



