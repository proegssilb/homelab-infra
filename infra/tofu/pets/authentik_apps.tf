# Authentik OIDC provider and application registrations for pet apps.
#
# Runs as part of `tofu apply pets`, which executes after `tune-all platform`
# has already brought Authentik up. Requires AUTHENTIK_URL and AUTHENTIK_TOKEN
# in the environment (set in .env).

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_property_mapping_provider_scope" "openid" {
  scope_name = "openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  scope_name = "email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  scope_name = "profile"
}

resource "authentik_property_mapping_provider_scope" "groups" {
  name       = "authentik default OAuth Mapping: OpenID 'groups'"
  scope_name = "groups"
  expression = "return list(request.user.ak_groups.values_list(\"name\", flat=True))"
}

# ── Actual Budget ──────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "budget" {
  name               = "Actual Budget"
  client_id          = "budget"
  client_secret      = var.oidc_client_secrets["budget"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://budget.${var.domain}/openid/callback" },
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
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
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://mealie.${var.domain}/login" },
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    authentik_property_mapping_provider_scope.groups.id,
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
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://rss.${var.domain}/i/" },
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

resource "authentik_application" "freshrss" {
  name              = "FreshRSS"
  slug              = "freshrss"
  protocol_provider = authentik_provider_oauth2.freshrss.id
  meta_launch_url   = "https://rss.${var.domain}"
}

# ── Forgejo ────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "forgejo" {
  name               = "Forgejo"
  client_id          = "forgejo"
  client_secret      = var.oidc_client_secrets["forgejo"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://code.${var.domain}/user/oauth2/Authentik/callback" },
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

resource "authentik_application" "forgejo" {
  name              = "Forgejo"
  slug              = "forgejo"
  protocol_provider = authentik_provider_oauth2.forgejo.id
  meta_launch_url   = "https://code.${var.domain}/user/oauth2/Authentik"
}

# ── Immich ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "immich" {
  name               = "Immich"
  client_id          = "immich"
  client_secret      = var.oidc_client_secrets["immich"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://photos.${var.domain}/auth/login" },
    { matching_mode = "strict", url = "app.immich:/" },
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    authentik_property_mapping_provider_scope.groups.id,
  ]
}

resource "authentik_application" "immich" {
  name              = "Immich"
  slug              = "immich"
  protocol_provider = authentik_provider_oauth2.immich.id
  meta_launch_url   = "https://photos.${var.domain}"
}
