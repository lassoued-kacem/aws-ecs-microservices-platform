output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for k, s in aws_subnet.this : s.id if s.tags["Tier"] == "public"]
}

output "app_subnet_ids" {
  value = [for k, s in aws_subnet.this : s.id if s.tags["Tier"] == "app"]
}

output "data_subnet_ids" {
  value = [for k, s in aws_subnet.this : s.id if s.tags["Tier"] == "data"]
}

output "nat_gateway_ids" {
  value = [for n in aws_nat_gateway.this : n.id]
}

output "azs" {
  value = local.azs
}
