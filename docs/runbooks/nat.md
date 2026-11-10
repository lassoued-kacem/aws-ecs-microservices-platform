# NAT gateway

- `ErrorPortAllocation > 0`: too many simultaneous connections to one destination. Reuse HTTP connections (boto3 does), or add NATs (`nat_per_az = true`).
- NAT AZ down (single-NAT design): tasks lose internet egress, so ECR pulls, SSM, X-Ray and SQS fail; S3/DynamoDB still work through gateway endpoints. Mitigation: `nat_per_az = true` and apply.
