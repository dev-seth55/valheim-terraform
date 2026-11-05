variable "aws_region" {
  description = "AWS region to deploy into. Pick one geographically close to you and your friends."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3a.medium (2 vCPU / 4GB) comfortably runs a 10-player vanilla server."
  type        = string
  default     = "t3a.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. Holds the OS, SteamCMD, and the world save."
  type        = number
  default     = 40
}

variable "ssh_public_key_path" {
  description = "Path to your local SSH public key — used to create the AWS key pair. \"~\" is expanded."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_cidr_override" {
  description = "Optional. CIDR allowed to SSH (e.g. 203.0.113.5/32). Leave null to auto-detect your current public IP at plan time."
  type        = string
  default     = null
}

variable "server_name" {
  description = "Name shown in the Steam server browser and join dialog."
  type        = string
  default     = "My Valheim Server"

  validation {
    condition     = !can(regex("[\"\\\\$`]", var.server_name))
    error_message = "server_name cannot contain double quotes, backslashes, dollar signs, or backticks (it is embedded in a shell script)."
  }
}

variable "world_name" {
  description = "Name of the world save file."
  type        = string
  default     = "Midgard"
}

variable "server_password" {
  description = "Join password. Valheim requires 5+ characters and it cannot contain the server name."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.server_password) >= 5
    error_message = "server_password must be at least 5 characters."
  }

  validation {
    condition     = !strcontains(lower(var.server_password), lower(var.server_name))
    error_message = "server_password cannot contain the server_name (Valheim rejects it)."
  }

  validation {
    condition     = !can(regex("[\"\\\\$`]", var.server_password))
    error_message = "server_password cannot contain double quotes, backslashes, dollar signs, or backticks (it is embedded in a shell script)."
  }
}

variable "server_public" {
  description = "List the server in the Steam server browser (password-protected, shown with a lock). Must be true: Valheim only answers Steam A2S queries on port 2457 when listed, and the Discord /valheim status player count and the idle auto-stop both depend on that. With false the idle check can never stop the server (it refuses to act on an unknown player count)."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Days to keep world snapshots in the S3 backup bucket before they expire."
  type        = number
  default     = 30
}

variable "idle_minutes" {
  description = "Stop the instance after this many minutes with zero players online (checked every 5 min)."
  type        = number
  default     = 30
}

variable "discord_public_key" {
  description = "Discord application public key (Developer Portal > General Information). Used to verify slash-command requests. Leave empty to disable Discord control; idle auto-stop still works."
  type        = string
  default     = ""
}

variable "discord_guild_id" {
  description = "Discord server (guild) ID the commands are allowed from. Right-click the server in Discord > Copy Server ID (needs Developer Mode)."
  type        = string
  default     = ""
}
