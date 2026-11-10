output "app_url" {
  description = "Public HTTPS URL (CloudFront)."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "alb_dns_name" {
  description = "Direct ALB hostname. Requests here get 403: the origin is locked to CloudFront."
  value       = aws_lb.this.dns_name
}

output "dashboard_url" {
  value = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.sre.dashboard_name}"
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.this.id
}
