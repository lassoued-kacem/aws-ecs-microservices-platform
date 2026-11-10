locals {
  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket}"
  boundary_name    = "${var.project}-workload-boundary"
  boundary_arn     = "arn:${local.partition}:iam::${local.account_id}:policy/${local.boundary_name}"
  # Roles the apply role may create/manage. CI roles are excluded below.
  workload_roles = "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*"
  ci_roles       = "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-gha-*"
}

# ------------------------------------------------ permissions boundary
# Every role Terraform creates in envs/prod MUST carry this boundary. Even if
# the apply role is abused to create a role with AdministratorAccess, the
# boundary caps it: no IAM, no Organizations, no billing.
data "aws_iam_policy_document" "boundary" {
  #checkov:skip=CKV_AWS_1:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_107:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_108:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_109:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_110:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_111:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_356:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  #checkov:skip=CKV_AWS_49:This is a permissions BOUNDARY (a ceiling intersected with each role's own policy), not a grant; it denies IAM/Organizations.
  statement {
    sid       = "AllowWorkloadServices"
    actions   = ["*"]
    resources = ["*"]
  }
  statement {
    sid       = "DenyPrivilegeEscalation"
    effect    = "Deny"
    actions   = ["iam:*", "organizations:*", "account:*", "sts:AssumeRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for every workload role (ECS tasks, Lambda, flow logs)."
  policy      = data.aws_iam_policy_document.boundary.json
}

# ------------------------------------------------ plan role (PRs, read-only)
resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
  }
  # Native locking writes <key>.tflock next to the state: allow only that.
  statement {
    sid       = "LockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket_arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ------------------------------------------------ apply role (main branch)
resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
}

# PowerUserAccess = everything EXCEPT IAM/Organizations/Account. IAM is then
# granted narrowly below. Not AdministratorAccess by design.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam" {
  #checkov:skip=CKV_AWS_356:Only read-only IAM Get/List actions use "*"; all writes are scoped to ticketrush-* roles with a boundary condition.
  statement {
    sid = "CreateWorkloadRolesOnlyWithBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.workload_roles]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }
  statement {
    sid = "ManageWorkloadRoles"
    actions = [
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription",
    ]
    resources = [local.workload_roles]
  }
  statement {
    sid       = "PassWorkloadRoles"
    actions   = ["iam:PassRole"]
    resources = [local.workload_roles]
  }
  statement {
    sid       = "ReadIam"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicies", "iam:GetOpenIDConnectProvider"]
    resources = ["*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }
  statement {
    sid    = "NeverTouchCiRolesOrBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.ci_roles, aws_iam_policy.boundary.arn]
  }
  statement {
    sid       = "NeverRemoveBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  name   = "scoped-iam"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam.json
}

# ------------------------------------------------ deploy role (app pipeline)
resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  #checkov:skip=CKV_AWS_356:ecr:GetAuthorizationToken and ecs Describe/RegisterTaskDefinition do not support resource-level permissions.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushOwnRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.svc : r.arn]
  }
  statement {
    sid       = "EcsDescribe"
    actions   = ["ecs:DescribeClusters", "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:ListTaskDefinitions"]
    resources = ["*"] # these actions do not support resource-level permissions
  }
  statement {
    sid       = "EcsUpdateOwnServices"
    actions   = ["ecs:UpdateService"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.project}-*/*"]
  }
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.project}-prod-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ReadEnvPointers"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.project}/env/*"]
  }
  statement {
    sid       = "WriteDeployPointers"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.project}/deploy/*"]
  }
  statement {
    sid       = "FrontendBucket"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:${local.partition}:s3:::${var.project}-*-frontend-*", "arn:${local.partition}:s3:::${var.project}-*-frontend-*/*"]
  }
  statement {
    sid       = "InvalidateCdn"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["arn:${local.partition}:cloudfront::${local.account_id}:distribution/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
