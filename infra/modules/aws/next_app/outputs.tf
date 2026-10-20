output "url" {
  description = "Public URL of the app."
  value       = "https://${var.domain}"
}

output "assets_bucket" {
  description = "S3 bucket the deploy workflow syncs .open-next/assets into."
  value       = aws_s3_bucket.assets.id
}

output "server_function_name" {
  description = "Lambda the deploy workflow updates with the .open-next server bundle and the app's settings."
  value       = aws_lambda_function.server.function_name
}

output "distribution_id" {
  description = "CloudFront distribution ID (the deploy workflow invalidates it)."
  value       = aws_cloudfront_distribution.app.id
}
