# All secrets: generated here, stored as SSM SecureString (AWS-managed key),
# injected into containers by ECS. They also exist in Terraform state, which is
# why the state bucket is private, versioned, encrypted and TLS-only.

resource "random_password" "db" {
  length  = 32
  special = true
  # RDS forbids / @ " and space in master passwords.
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "cache" {
  length  = 48
  special = false # ElastiCache AUTH tokens: printable, no @ " /
}

resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

locals {
  secret_values = {
    db_password   = random_password.db.result
    jwt_secret    = random_password.jwt.result
    cache_token   = random_password.cache.result
    origin_verify = random_password.origin_verify.result
  }
}

resource "aws_ssm_parameter" "secret" {
  #checkov:skip=CKV_AWS_337:AWS-managed key (alias/aws/ssm) by project decision, no CMK.
  for_each = local.secret_values
  name     = "/${var.project}/${var.environment}/secrets/${each.key}"
  type     = "SecureString"
  value    = each.value
}

# Non-secret pointers the app pipeline reads to know where to deploy.
resource "aws_ssm_parameter" "env" {
  for_each = {
    cluster         = aws_ecs_cluster.this.name
    frontend_bucket = aws_s3_bucket.frontend.bucket
    cloudfront_id   = aws_cloudfront_distribution.this.id
    base_url        = "https://${aws_cloudfront_distribution.this.domain_name}"
  }
  name  = "/${var.project}/env/${each.key}"
  type  = "String"
  value = each.value
}
