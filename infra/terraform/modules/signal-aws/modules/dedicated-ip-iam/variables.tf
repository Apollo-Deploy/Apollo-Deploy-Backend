variable "name_prefix" {
  description = "Prefix used for the dedicated-IP managed policy name."
  type        = string
}

variable "partition" {
  description = "AWS partition containing the Signal SES resources."
  type        = string
}

variable "account_id" {
  description = "AWS account containing the Signal SES resources."
  type        = string
}

variable "regions" {
  description = "Exact AWS regions where Signal may provision dedicated-IP resources."
  type        = set(string)
}

variable "shared_configuration_set_name" {
  description = "Terraform-owned SES configuration set copied into per-customer dedicated routes."
  type        = string
}

variable "runtime_user_name" {
  description = "Signal runtime IAM user receiving dedicated-IP permissions."
  type        = string
}

variable "ownership_tag" {
  description = "Tag required on every runtime-managed SES resource."
  type = object({
    key   = string
    value = string
  })
}

variable "tags" {
  description = "Tags applied to the dedicated-IP managed IAM policy."
  type        = map(string)
  default     = {}
}
