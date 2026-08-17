variable "ses_feedback_endpoint_override" {
  description = "Wizard-only current SNS endpoint retained during a base-domain/TLS transition."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.ses_feedback_endpoint_override == null ||
      can(regex(
        "^https://api[.]signal[.][A-Za-z0-9.-]+/v1/ses-events/ingest$",
        var.ses_feedback_endpoint_override,
      ))
    )
    error_message = "ses_feedback_endpoint_override must be a valid Apollo Signal HTTPS ingestion endpoint."
  }
}
