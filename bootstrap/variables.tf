variable "aws_region" {
  description = "Region for the state bucket. Independent of the server's region; whatever you pick here must match the backend block in ../main.tf."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name (unique across all of AWS, not just your account). Suggest something like '<yourname>-tf-state-<random-suffix>'."
  type        = string
}
