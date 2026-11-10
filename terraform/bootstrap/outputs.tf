output "state_bucket" {
  description = "Put this in the TF_STATE_BUCKET GitHub variable and in backend configs."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = data.aws_region.current.region
}
