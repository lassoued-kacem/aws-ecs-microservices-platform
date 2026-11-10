output "github_variables" {
  description = "Copy these into GitHub > Settings > Secrets and variables > Actions > Variables."
  value = {
    AWS_REGION              = local.region
    AWS_ROLE_PLAN_ARN       = aws_iam_role.plan.arn
    AWS_ROLE_APPLY_ARN      = aws_iam_role.apply.arn
    AWS_ROLE_APP_DEPLOY_ARN = aws_iam_role.deploy.arn
    TF_STATE_BUCKET         = var.state_bucket
    ECR_REGISTRY            = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  }
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
