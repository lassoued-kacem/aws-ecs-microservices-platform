data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Created by the foundation layer (permanent).
data "aws_iam_policy" "boundary" {
  name = "${var.project}-workload-boundary"
}

data "aws_ecr_repository" "svc" {
  for_each = toset(local.services)
  name     = "${var.project}/${each.key}"
}

# Last image tag the app pipeline pushed; lets a rebuilt env start on a real image.
data "aws_ssm_parameter" "image_tag" {
  for_each = toset(local.services)
  name     = "/${var.project}/deploy/${each.key}/image_tag"
}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  services   = ["identity", "ticketing"]
  boundary   = data.aws_iam_policy.boundary.arn
}

module "network" {
  source                   = "../../modules/network"
  name                     = local.name
  cidr_block               = var.vpc_cidr
  nat_per_az               = var.nat_per_az
  permissions_boundary_arn = local.boundary
}
