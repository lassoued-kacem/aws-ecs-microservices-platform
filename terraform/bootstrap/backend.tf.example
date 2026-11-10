# Step 2 of the bootstrap (see WHAT-TO-DO-MANUALLY.md): after the first local
# apply created the bucket, copy this file to backend.tf and run
#   terraform init -migrate-state -backend-config=bucket=<state_bucket output>
# so the bootstrap layer's own state also lives in the bucket.
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
