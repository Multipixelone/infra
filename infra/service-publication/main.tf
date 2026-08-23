locals {
  registry            = jsondecode(file("${path.module}/registry.json"))
  access_policies     = local.registry.cloudflare.accessPolicies
  access_applications = local.registry.cloudflare.accessApplications
  dns_records         = local.registry.cloudflare.dnsRecords
  tunnel_routes       = flatten([for application in local.registry.cloudflare.tunnel.applications : application.ingress])

  tunnel_ingress = concat(
    [for route in local.tunnel_routes : merge(
      {
        hostname = local.registry.applications[element(split("/", route.key), 0)].canonical
        service  = route.service
      },
      route.pathPrefix == "/" ? {} : {
        path = "${trimsuffix(route.pathPrefix, "/")}.*"
      },
      startswith(route.service, "https://") ? {
        origin_request = {
          http_host_header   = route.httpHostHeader
          no_tls_verify      = false
          origin_server_name = route.originServerName
        }
      } : {}
    )],
    [{ service = local.registry.cloudflare.tunnel.catchAll }]
  )
}

resource "cloudflare_zero_trust_access_policy" "managed" {
  for_each = local.access_policies

  account_id       = var.cloudflare_account_id
  name             = each.key
  decision         = each.value.decision
  include          = each.value.include
  exclude          = each.value.exclude
  require          = each.value.require
  session_duration = each.value.sessionDuration

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_zero_trust_access_application" "managed" {
  for_each = local.access_applications

  account_id           = var.cloudflare_account_id
  name                 = "service-publication:${each.key}"
  domain               = each.value.domain
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  policies = concat(
    length(each.value.access.serviceTokens) == 0 ? [] : [{
      name       = "service-token:${each.key}"
      decision   = "non_identity"
      precedence = 1
      include = [for token_id in each.value.access.serviceTokens : {
        service_token = { token_id = token_id }
      }]
    }],
    each.value.access.bypassAccess ? [{
      name       = "reviewed-bypass:${each.key}"
      decision   = "bypass"
      precedence = 2
      include    = [{ everyone = {} }]
    }] : [],
    [{
      id         = cloudflare_zero_trust_access_policy.managed[each.value.access.policy].id
      precedence = 1000
    }]
  )

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = each.value.access.policy != null && contains(keys(local.access_policies), each.value.access.policy)
      error_message = "Every Access application must bind an adopted, registry-managed default policy."
    }
    precondition {
      condition     = !each.value.access.bypassAccess || trimspace(each.value.access.bypassJustification) != ""
      error_message = "Access bypasses require a non-empty registry justification."
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "managed" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = var.tunnel_secret

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "managed" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.managed.id
  source     = "cloudflare"

  config = {
    ingress = local.tunnel_ingress
  }

  depends_on = [cloudflare_zero_trust_access_application.managed]
}

resource "cloudflare_dns_record" "public" {
  for_each = local.dns_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.managed.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Multipixelone/infra service publication (${each.key})"

  depends_on = [
    cloudflare_zero_trust_access_application.managed,
    cloudflare_zero_trust_tunnel_cloudflared_config.managed,
  ]
}
