terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Deliberately no backend block here — this project's own state stays local.
  # It has to: the S3 bucket it creates doesn't exist yet for it to use.
  # (Its terraform.tfstate is gitignored; keep a copy somewhere safe.)
}

provider "aws" {
  region = var.aws_region
}

# --- The "filing cabinet": where the Valheim project's state will live ---
resource "aws_s3_bucket" "tf_state" {
  # S3 bucket names are unique across ALL of AWS, not just your account —
  # var.bucket_name should include something identifying (your name, a random
  # suffix) so it doesn't collide with someone else's bucket.
  bucket = var.bucket_name

  # A stray `terraform destroy` in this directory would otherwise try to take
  # the Valheim project's state with it. Remove this line deliberately if you
  # ever really want the bucket gone.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Purpose = "terraform-remote-state"
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled" # keeps every past version of the state file as a safety net
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # state can contain sensitive values (e.g. your Valheim password)
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Locking ---
# Nothing to create. Terraform 1.11+ locks natively with a .tflock object in
# the same bucket (use_lockfile = true in the Valheim project's backend block),
# so the old DynamoDB lock table is no longer needed.
