output "queue_urls" {
  description = "Signal source queue URLs keyed by workload."
  value       = { for name, queue in aws_sqs_queue.this : name => queue.url }
}

output "queue_arns" {
  description = "Signal source queue ARNs keyed by workload."
  value       = { for name, queue in aws_sqs_queue.this : name => queue.arn }
}

output "dlq_arns" {
  description = "Signal dead-letter queue ARNs keyed by workload."
  value       = { for name, queue in aws_sqs_queue.dlq : name => queue.arn }
}
