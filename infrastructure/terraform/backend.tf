terraform {
  required_version = ">= 1.5.0"

  cloud {} # Empty block satisfied via .tfbackend config file or TF_CLOUD_* env vars
}
