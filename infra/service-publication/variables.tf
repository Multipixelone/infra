variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID supplied by the declarative Nix service-publication registry."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "finnrut.is zone ID supplied by the declarative Nix service-publication registry."
}

variable "tunnel_name" {
  type        = string
  description = "Name of the existing adopted service-publication Tunnel."
}

variable "tunnel_secret" {
  type        = string
  sensitive   = true
  description = "Existing Tunnel secret supplied at runtime; remote encrypted state will contain a sensitive value."
}

variable "bootstrap_complete" {
  type        = bool
  description = "Declarative adoption gate; true only after remote locking and imports are proven."

  validation {
    condition     = var.bootstrap_complete
    error_message = "Cloudflare adoption is incomplete; refusing to plan or apply managed publication resources."
  }
}
