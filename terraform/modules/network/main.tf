data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  # /16 -> /20 subnets (newbits = 4). Index plan, easy to read in the console:
  #   public   0,1   -> 10.0.0.0/20,  10.0.16.0/20
  #   app      4,5   -> 10.0.64.0/20, 10.0.80.0/20
  #   data     8,9   -> 10.0.128.0/20, 10.0.144.0/20
  tiers = {
    public = 0
    app    = 4
    data   = 8
  }
  subnets = merge([
    for tier, base in local.tiers : {
      for i, az in local.azs : "${tier}-${az}" => {
        tier = tier
        az   = az
        cidr = cidrsubnet(var.cidr_block, 4, base + i)
      }
    }
  ]...)
  nat_azs = var.nat_per_az ? local.azs : [local.azs[0]]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # required for RDS/ElastiCache endpoint names
  tags                 = { Name = var.name }
}

# Lock the default SG down: nothing should ever use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "this" {
  for_each          = local.subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  # Nothing gets a public IP automatically, not even in public subnets: only the
  # ALB and NAT (with an explicit EIP) live there.
  map_public_ip_on_launch = false
  tags = {
    Name = "${var.name}-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = { Name = "${var.name}-nat-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this["public-${each.key}"].id
  tags          = { Name = "${var.name}-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.this]
}

# ---- route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table" "app" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "${var.name}-app-${each.key}" }
}

resource "aws_route" "app_nat" {
  for_each               = toset(local.azs)
  route_table_id         = aws_route_table.app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # Same-AZ NAT if it exists, otherwise the single shared NAT.
  nat_gateway_id = aws_nat_gateway.this[contains(local.nat_azs, each.key) ? each.key : local.nat_azs[0]].id
}

# Data tier: a route table with NO default route. The only way in or out is
# inside the VPC (local route). This is the "isolated" tier.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-data" }
}

resource "aws_route_table_association" "this" {
  for_each  = local.subnets
  subnet_id = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public" ? aws_route_table.public.id :
    each.value.tier == "app" ? aws_route_table.app[each.value.az].id :
    aws_route_table.data.id
  )
}

# ---- free gateway endpoints: S3 (ECR image layers live in S3) and DynamoDB.
data "aws_region" "current" {}

resource "aws_vpc_endpoint" "gateway" {
  for_each          = toset(["s3", "dynamodb"])
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.app : rt.id]
  tags              = { Name = "${var.name}-${each.key}" }
}

# ---- flow logs (REJECT + ACCEPT) to CloudWatch, short retention.
resource "aws_cloudwatch_log_group" "flow" {
  #checkov:skip=CKV_AWS_158:AWS-managed encryption (no CMK by project decision).
  #checkov:skip=CKV_AWS_338:Short retention is intentional to control cost.
  name              = "/${var.name}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name                 = "${var.name}-flow-logs"
  assume_role_policy   = data.aws_iam_policy_document.flow_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "flow" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow.arn
  max_aggregation_interval = 600 # 10 min: cheaper than 1 min, fine for forensics
}
