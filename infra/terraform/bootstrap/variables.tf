variable "account_id" {
  description = "Exact AWS account allowed to own the production bootstrap resources."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be an exact 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for Terraform state and the operator notification topic."
  type        = string
  default     = "af-south-1"

  validation {
    condition = contains([
      "af-south-1",
      "ap-southeast-1",
      "eu-west-1",
      "us-east-1",
    ], var.region)
    error_message = "region must be one of Apollo Signal's supported AWS regions."
  }
}

variable "state_bucket_name" {
  description = "Optional globally unique S3 state bucket name; null uses the canonical Apollo production Terraform-state name."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.state_bucket_name == null ||
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    )
    error_message = "state_bucket_name must be null or a valid 3-63 character S3 bucket name."
  }
}

variable "operator_topic_name" {
  description = "Name of the operator-owned SNS topic used by production alarms."
  type        = string
  default     = "apollo-production-operator-alerts"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,256}$", var.operator_topic_name))
    error_message = "operator_topic_name must be a valid SNS topic name."
  }
}
