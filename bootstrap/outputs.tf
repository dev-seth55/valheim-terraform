output "bucket_name" {
  description = "Must match the bucket in the Valheim project's backend \"s3\" block and in iam/deployer-permissions-policy.json."
  value       = aws_s3_bucket.tf_state.id
}
