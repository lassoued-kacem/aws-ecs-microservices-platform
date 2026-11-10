data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  oidc_host  = "token.actions.githubusercontent.com"
  oidc_arn   = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"
}

# ---------------------------------------------------------------- ECR
resource "aws_ecr_repository" "svc" {
  #checkov:skip=CKV_AWS_136:AWS-managed (AES256) encryption by project decision, no CMK.
  #checkov:skip=CKV_AWS_163:Image scanning explicitly declined by the project owner.
  for_each             = var.services
  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a SHA tag can never be overwritten
  force_delete         = false
  encryption_configuration {
    encryption_type = "AES256"
  }
  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 15 most recent images (caps storage cost)"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 15 }
      action       = { type = "expire" }
    }]
  })
}

# Pointer written by the app pipeline after each push. envs/prod reads it so a
# rebuilt environment starts on the last good image (no `latest` tag exists).
resource "aws_ssm_parameter" "image_tag" {
  for_each    = var.services
  name        = "/${var.project}/deploy/${each.key}/image_tag"
  description = "Last image tag pushed by CI for ${each.key}"
  type        = "String"
  value       = "none"
  lifecycle {
    ignore_changes = [value] # owned by the pipeline after creation
  }
}

# ---------------------------------------------------------------- GitHub OIDC
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates thumbprints for GitHub (trusted root CAs), but the
  # API field is still accepted; this is GitHub's published one.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan   = ["repo:${var.github_repository}:pull_request"]
    apply  = ["repo:${var.github_repository}:ref:refs/heads/main"]
    deploy = ["repo:${var.github_repository}:ref:refs/heads/main"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # StringEquals (not Like): only this repo AND this exact trigger.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}
