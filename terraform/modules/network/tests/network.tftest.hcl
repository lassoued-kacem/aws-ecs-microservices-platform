# Offline unit tests: mock provider, plan only, zero cost, ~seconds.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "eu-west-3"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name                     = "test"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "two_azs_six_subnets_one_nat" {
  command = plan

  assert {
    condition     = length(aws_subnet.this) == 6
    error_message = "Expected 3 tiers x 2 AZs = 6 subnets."
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "Default must be a single shared NAT gateway (cost)."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.this : s.map_public_ip_on_launch == false])
    error_message = "No subnet may auto-assign public IPs."
  }
}

run "nat_per_az_when_enabled" {
  command = plan
  variables {
    nat_per_az = true
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "nat_per_az=true must create one NAT per AZ."
  }
}

run "subnet_math_is_non_overlapping" {
  command = plan
  assert {
    condition     = aws_subnet.this["public-eu-west-3a"].cidr_block == "10.0.0.0/20" && aws_subnet.this["app-eu-west-3a"].cidr_block == "10.0.64.0/20" && aws_subnet.this["data-eu-west-3a"].cidr_block == "10.0.128.0/20"
    error_message = "Subnet plan changed unexpectedly."
  }
}

run "data_tier_has_no_default_route" {
  command = plan
  # The only 0.0.0.0/0 routes are public->IGW and app->NAT; none target the data table.
  assert {
    condition     = length([for r in aws_route.app_nat : r]) == 2 && aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Unexpected default routes."
  }
}

run "rejects_single_az" {
  command = plan
  variables {
    az_count = 1
  }
  expect_failures = [var.az_count]
}
