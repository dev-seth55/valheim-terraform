output "server_public_ip" {
  description = "Elastic IP — give this to your friends as the Join IP in Steam."
  value       = aws_eip.valheim.public_ip
}

output "ssh_command" {
  description = "SSH in to check logs or manage the server."
  value       = "ssh -i ${local.ssh_private_key_path} ubuntu@${aws_eip.valheim.public_ip}"
}

output "ssh_allowed_from" {
  description = "CIDR currently allowed to SSH. If this isn't your IP anymore, re-run apply."
  value       = local.ssh_cidr
}

output "join_instructions" {
  description = "How friends connect."
  value       = "In Steam: Valheim > Join Game > Join IP > ${aws_eip.valheim.public_ip}:2456, then enter the password."
}

output "backup_bucket" {
  description = "S3 bucket holding world snapshots. Also the argument to scripts/install-backup.sh on an existing instance."
  value       = aws_s3_bucket.backups.id
}

output "discord_interactions_url" {
  description = "Paste this as the Interactions Endpoint URL in the Discord Developer Portal."
  value       = aws_lambda_function_url.control.function_url
}
