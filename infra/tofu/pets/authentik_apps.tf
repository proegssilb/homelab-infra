# Authentik OIDC provider and application registrations for pet apps.
#
# Runs as part of `tofu apply pets`, which executes after `tune-all platform`
# has already brought Authentik up. Requires AUTHENTIK_URL and AUTHENTIK_TOKEN
# in the environment (set in .env).

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_scope_mapping" "openid" {
  scope_name = "openid"
}

data "authentik_scope_mapping" "email" {
  scope_name = "email"
}

data "authentik_scope_mapping" "profile" {
  scope_name = "profile"
}

data "authentik_scope_mapping" "groups" {
  scope_name = "goauthentik.io/providers/oauth2/scope-groups"
}

# ── Actual Budget ──────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "budget" {
  name               = "Actual Budget"
  client_id          = "budget"
  client_secret      = var.oidc_client_secrets["budget"]
  authorization_flow = data.authentik_flow.default_authorization.id
  redirect_uris      = ["https://budget.${var.domain}/openid/callback"]
  property_mappings = [
    data.authentik_scope_mapping.openid.id,
    data.authentik_scope_mapping.email.id,
    data.authentik_scope_mapping.profile.id,
  ]
}

resource "authentik_application" "budget" {
  name              = "Actual Budget"
  slug              = "budget"
  protocol_provider = authentik_provider_oauth2.budget.id
  meta_launch_url   = "https://budget.${var.domain}"
}

# ── Mealie ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "mealie" {
  name               = "Mealie"
  client_id          = "mealie"
  client_secret      = var.oidc_client_secrets["mealie"]
  authorization_flow = data.authentik_flow.default_authorization.id
  redirect_uris      = ["https://mealie.${var.domain}/login"]
  property_mappings = [
    data.authentik_scope_mapping.openid.id,
    data.authentik_scope_mapping.email.id,
    data.authentik_scope_mapping.profile.id,
    data.authentik_scope_mapping.groups.id,
  ]
}

resource "authentik_application" "mealie" {
  name              = "Mealie"
  slug              = "mealie"
  protocol_provider = authentik_provider_oauth2.mealie.id
  meta_launch_url   = "https://mealie.${var.domain}"
}

# ── FreshRSS ───────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "freshrss" {
  name               = "FreshRSS"
  client_id          = "freshrss"
  client_secret      = var.oidc_client_secrets["freshrss"]
  authorization_flow = data.authentik_flow.default_authorization.id
  redirect_uris      = ["https://rss.${var.domain}/i/"]
  property_mappings = [
    data.authentik_scope_mapping.openid.id,
    data.authentik_scope_mapping.email.id,
    data.authentik_scope_mapping.profile.id,
  ]
}

resource "authentik_application" "freshrss" {
  name              = "FreshRSS"
  slug              = "freshrss"
  protocol_provider = authentik_provider_oauth2.freshrss.id
  meta_launch_url   = "https://rss.${var.domain}"
}

# ── Immich ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "immich" {
  name               = "Immich"
  client_id          = "immich"
  client_secret      = var.oidc_client_secrets["immich"]
  authorization_flow = data.authentik_flow.default_authorization.id
  redirect_uris = [
    "https://photos.${var.domain}/auth/login",
    "app.immich:/",
  ]
  property_mappings = [
    data.authentik_scope_mapping.openid.id,
    data.authentik_scope_mapping.email.id,
    data.authentik_scope_mapping.profile.id,
    data.authentik_scope_mapping.groups.id,
  ]
}

resource "authentik_application" "immich" {
  name              = "Immich"
  slug              = "immich"
  protocol_provider = authentik_provider_oauth2.immich.id
  meta_launch_url   = "https://photos.${var.domain}"
}
