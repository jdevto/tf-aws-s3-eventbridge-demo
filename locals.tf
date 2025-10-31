locals {
  # Use a short random suffix for globally-unique bucket name
  bucket_name = "${var.project_name}-${random_id.bucket_suffix.hex}"

  common_tags = {
    Project     = var.project_name
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
