module "message_queues" {
  source = "./modules/message-queues"

  name_prefix              = "${var.name_prefix}-signal"
  region                   = var.region
  queues                   = local.queues
  operator_alert_topic_arn = var.operator_alert_topic_arn
}
