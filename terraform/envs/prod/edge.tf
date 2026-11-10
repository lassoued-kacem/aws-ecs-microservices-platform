# ---------------------------------------------------------------- S3 (SPA assets)
resource "aws_s3_bucket" "frontend" {
  #checkov:skip=CKV_AWS_144:No cross-region replication: assets are rebuilt by CI.
  #checkov:skip=CKV_AWS_18:Access logging skipped; CloudFront is the only reader.
  #checkov:skip=CKV2_AWS_62:No event notifications needed.
  #checkov:skip=CKV_AWS_145:AWS-managed SSE-S3 by project decision.
  #checkov:skip=CKV_AWS_21:Versioning unnecessary: every deploy re-uploads from git.
  #checkov:skip=CKV2_AWS_61:Lifecycle not needed for a few hundred KB of assets.
  bucket        = "${local.name}-frontend-${local.account_id}"
  force_destroy = true # ephemeral layer: destroy must not fail on a non-empty bucket
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Origin Access Control: CloudFront signs requests (SigV4); the bucket stays private.
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn] # only OUR distribution
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  policy     = data.aws_iam_policy_document.frontend.json
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# ---------------------------------------------------------------- CloudFront
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  # Forwards cookies, query strings and headers (Idempotency-Key, Authorization)
  # but not Host, so the ALB sees its own hostname.
  name = "Managed-AllViewerExceptHostHeader"
}

# SPA routing: /events/123 has no file in S3; serve index.html instead. Done in
# a CloudFront Function on the S3 behavior only, so API 404s stay real 404s
# (a distribution-wide custom_error_response would rewrite those too).
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${local.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var req = event.request;
      if (!req.uri.includes('.')) { req.uri = '/index.html'; }
      return req;
    }
  JS
}

resource "aws_cloudfront_response_headers_policy" "security" {
  #checkov:skip=CKV_AWS_259:HSTS is enforced (1 year, includeSubDomains); preload is impossible on *.cloudfront.net.
  name = "${local.name}-security-headers"
  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
      override                = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  #checkov:skip=CKV_AWS_374:Public ticketing site: no geo restriction wanted.
  #checkov:skip=CKV_AWS_68:WAF is attached at the ALB (regional) to avoid a us-east-1 provider; documented.
  #checkov:skip=CKV2_AWS_47:See CKV_AWS_68.
  #checkov:skip=CKV_AWS_86:CloudFront access logs skipped for cost; metrics + WAF logs cover it.
  #checkov:skip=CKV_AWS_174:Default *.cloudfront.net certificate (no domain) cannot pin a minimum TLS version.
  #checkov:skip=CKV2_AWS_42:No custom domain/certificate by project decision.
  #checkov:skip=CKV_AWS_310:Single ALB origin; S3 + ALB are different path behaviors, not failover pairs.
  #checkov:skip=CKV2_AWS_32:Response headers policy IS attached to both behaviors.
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name} SPA + API"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # EU + North America edges: cheapest

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    origin_id   = "alb-api"
    domain_name = aws_lb.this.dns_name
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 30
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-frontend"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = "alb-api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id # API: never cache at the edge (Valkey does it)
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
