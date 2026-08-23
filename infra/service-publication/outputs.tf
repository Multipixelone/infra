output "managed_inventory" {
  description = "Non-secret stable keys used to reconcile imports and deployments."
  value = {
    policies            = sort(keys(cloudflare_zero_trust_access_policy.managed))
    access_applications = sort(keys(cloudflare_zero_trust_access_application.managed))
    dns_records         = sort(keys(cloudflare_dns_record.public))
    registry_schema     = local.registry.metadata.schemaVersion
  }
}
