output "db_password" {
  description = "Postgres superuser password"
  value       = random_password.db.result
  sensitive   = true
}

output "redis_password" {
  description = "Redis requirepass password"
  value       = random_password.redis.result
  sensitive   = true
}

output "session_secret" {
  description = "Platform session signing secret"
  value       = random_password.session.result
  sensitive   = true
}

output "auth_cookie_secret" {
  description = "Platform auth cookie signing secret"
  value       = random_password.auth_cookie.result
  sensitive   = true
}

output "internal_service_secret" {
  description = "Shared internal service-to-service secret"
  value       = random_password.internal.result
  sensitive   = true
}

output "platform_app_db_pass" {
  description = "Password for the platform_app DB role"
  value       = random_password.platform_app.result
  sensitive   = true
}

output "billing_app_db_pass" {
  description = "Password for the billing_app DB role"
  value       = random_password.billing_app.result
  sensitive   = true
}

output "billing_superuser_db_pass" {
  description = "Password for the billing_superuser DB role"
  value       = random_password.billing_super.result
  sensitive   = true
}

output "signal_app_db_pass" {
  description = "Password for the signal_app DB role"
  value       = random_password.signal_app.result
  sensitive   = true
}

output "signal_superuser_db_pass" {
  description = "Password for the signal_superuser DB role"
  value       = random_password.signal_super.result
  sensitive   = true
}

output "platform_verifier_db_pass" {
  description = "Password for the platform_verifier DB role"
  value       = random_password.platform_verifier.result
  sensitive   = true
}
