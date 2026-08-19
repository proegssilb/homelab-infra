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

# Some OIDC clients (FreshRSS, Actual Budget, Mealie) fetch Authentik's
# JWKS and require RS256-signed ID tokens, so their providers need an
# explicit signing key (Authentik's default HS256 behavior for unset
# signing_key doesn't publish to JWKS).
data "authentik_certificate_key_pair" "self_signed" {
  name = "authentik Self-signed Certificate"
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
  # Actual Budget's OIDC client (openid-client) rejects HS256-signed ID
  # tokens — it requires RS256, same as FreshRSS below.
  signing_key = data.authentik_certificate_key_pair.self_signed.id
  # Terraform's authentik provider does not default this field — the API
  # leaves it as an empty list, which makes authentik reject every
  # authorization request with a generic "invalid_request" error. Must be
  # set explicitly on every OAuth2 provider in this file.
  grant_types = ["authorization_code", "refresh_token"]
  allowed_redirect_uris = [
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://budget.${var.domain}/openid/callback" },
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
  # Mealie (via authlib) fetches Authentik's JWKS to validate the ID token
  # signature — HS256 (the default with no signing_key) publishes nothing
  # to JWKS, so mealie's KeySet.import_key_set(jwks) dies with KeyError:
  # 'keys'. Same fix as FreshRSS/Actual Budget above.
  signing_key = data.authentik_certificate_key_pair.self_signed.id
  grant_types = ["authorization_code", "refresh_token"]
  allowed_redirect_uris = [
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://meals.${var.domain}/login" },
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
  meta_launch_url   = "https://meals.${var.domain}"
}

# ── FreshRSS ───────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "freshrss" {
  name               = "FreshRSS"
  client_id          = "freshrss"
  client_secret      = var.oidc_client_secrets["freshrss"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.self_signed.id
  grant_types        = ["authorization_code", "refresh_token"]
  allowed_redirect_uris = [
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://rss.${var.domain}/i/" },
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://rss.${var.domain}:443/i/oidc/" },
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://rss.${var.domain}/i/oidc/" },
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
  grant_types        = ["authorization_code", "refresh_token"]
  allowed_redirect_uris = [
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://code.${var.domain}/user/oauth2/Authentik/callback" },
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
  # Immich's OIDC client (openid-client, same as Actual Budget/Mealie) defaults
  # to requiring an RS256-signed ID token — same JWKS fix as the other apps.
  signing_key = data.authentik_certificate_key_pair.self_signed.id
  grant_types = ["authorization_code", "refresh_token"]
  allowed_redirect_uris = [
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "https://photos.${var.domain}/auth/login" },
    # Immich's mobile app always sends this exact custom-scheme callback.
    { matching_mode = "strict", redirect_uri_type = "authorization", url = "app.immich:///oauth-callback" },
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
