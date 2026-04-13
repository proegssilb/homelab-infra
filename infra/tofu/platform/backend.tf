terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "platform/terraform.tfstate"

    # endpoint passed via -backend-config at init time (GARAGE_ENDPOINT in .env)
    region = "garage"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
