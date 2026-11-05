# =============================================================================
# World backups to S3
#
# The instance tars worlds_local/ and uploads it hourly (only when the world
# has changed) and after every graceful stop. The on-instance side is
# scripts/install-backup.sh, run by user_data on new instances.
# =============================================================================

resource "aws_s3_bucket" "backups" {
  # bucket_prefix gets a random suffix appended, so this is globally unique
  # without you having to pick a name. The deployer IAM policy is scoped to
  # buckets matching "valheim-backups-*".
  bucket_prefix = "valheim-backups-"

  tags = {
    Name = "valheim-backups"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Snapshots are timestamped tarballs, so "keep N days" is the whole retention
# policy. Noncurrent versions (from any overwrite) are cleaned up on the same
# schedule, and abandoned multipart uploads don't linger.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }
}

# --- Instance role: the only AWS permission the box has is writing to this bucket ---
resource "aws_iam_role" "instance" {
  name = "valheim-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "instance_backup" {
  name = "valheim-backup-write"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "valheim-instance"
  role = aws_iam_role.instance.name
}
