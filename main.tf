terraform {
  # 1.11+ for native S3 state locking (use_lockfile) and cross-variable validation.
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Points at the bucket created by ../bootstrap. The bucket name has to be
  # hardcoded — Terraform can't interpolate variables here, since the backend
  # is resolved before any variables are loaded. It must match the value in
  # bootstrap/terraform.tfvars and iam/deployer-permissions-policy.json.
  # Native S3 locking (use_lockfile) replaces the old DynamoDB lock table.
  backend "s3" {
    bucket       = "REPLACE_ME_STATE_BUCKET" # must equal bootstrap's bucket_name
    key          = "valheim/terraform.tfstate"
    region       = "us-east-1" # region of the STATE BUCKET (where bootstrap ran); independent of the server's region
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Your current public IP, fetched at plan time ---
# Home connections usually have a dynamic IP. Rather than hardcoding it and
# getting locked out of SSH when it rotates, look it up every plan/apply. When
# your IP changes, re-run `apply`: the plan shows a one-line in-place edit to
# the security group rule and nothing gets replaced. Set ssh_cidr_override in
# terraform.tfvars to bypass the lookup (e.g. from a VPN or a static address).
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_cidr_override != null ? var.ssh_cidr_override : "${chomp(data.http.my_ip.response_body)}/32"

  # Private key path is the public key path minus ".pub" — used only for the
  # convenience output below.
  ssh_private_key_path = trimsuffix(var.ssh_public_key_path, ".pub")
}

# --- Latest Ubuntu 24.04 LTS AMI (Canonical's official account) ---
# Only used to pick the AMI at *creation* time; see the lifecycle block on the
# instance for why later AMI releases don't trigger a rebuild.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Default VPC/subnet (single public-facing box, no need for a custom VPC) ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- SSH key pair, imported from your local public key ---
# pathexpand() is required: file() does not expand "~" on its own.
resource "aws_key_pair" "valheim" {
  key_name   = "valheim-server-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# --- Security group: Valheim UDP ports open, SSH locked to your current IP ---
resource "aws_security_group" "valheim" {
  name        = "valheim-server-sg"
  description = "Valheim dedicated server (Steam-only)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Valheim game traffic"
    from_port   = 2456
    to_port     = 2457
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH admin access (auto-detected home IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "valheim-server-sg"
  }
}

# --- EC2 instance ---
resource "aws_instance" "valheim" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  key_name               = aws_key_pair.valheim.key_name
  vpc_security_group_ids = [aws_security_group.valheim.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name # S3 backup writes; attaches in place

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  # Unlimited mode lets the instance burst past baseline for the length of a play
  # session instead of throttling once CPU credits run out. Surplus charges only
  # apply if the 24hr average usage exceeds baseline — unlikely for evening
  # sessions with idle time overnight.
  credit_specification {
    cpu_credits = "unlimited"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    server_name           = var.server_name
    world_name            = var.world_name
    server_password       = var.server_password
    server_public         = var.server_public ? 1 : 0
    backup_bucket         = aws_s3_bucket.backups.id
    aws_region            = var.aws_region
    install_backup_script = file("${path.module}/scripts/install-backup.sh")
  })

  # The world save lives on this instance's root volume. Anything that forces a
  # replacement destroys it, so:
  #   - ami:       Canonical publishes new 24.04 AMIs regularly; without this,
  #                the next apply after a new release would rebuild the box.
  #   - subnet_id: the aws_subnets data source doesn't guarantee ordering.
  #   - user_data: cloud-init runs the boot script ONCE per instance. Editing
  #                server_name/world_name/server_password in tfvars later would
  #                stop/start the box to update an attribute that nothing reads.
  #                Change those on the instance instead (see docs/runbook.md, "Day-to-day").
  #   - tags["ValheimIdleSince"]: set and cleared by the control Lambda's idle
  #                check; Terraform must not strip it on every apply.
  lifecycle {
    ignore_changes = [ami, subnet_id, user_data, tags["ValheimIdleSince"]]
  }

  tags = {
    Name = "valheim-server"
  }
}

# --- Elastic IP, so the address never changes across reboots ---
resource "aws_eip" "valheim" {
  instance = aws_instance.valheim.id
  domain   = "vpc"

  tags = {
    Name = "valheim-server-eip"
  }
}
