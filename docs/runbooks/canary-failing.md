# Canary failing

The canary probes the public URL every minute from outside the VPC. If it fails and nothing else does, suspect the **edge**:

1. Which check? Dashboard "External canary success %" (frontend / events_api / identity_api / ticketing_api).
2. `frontend` failing only: S3 object missing (re-run App CD) or a CloudFront issue.
3. API checks failing with 403: the origin header secret differs between CloudFront and the ALB rules (run `make apply`), or WAF is blocking the canary ([waf-false-positive.md](waf-false-positive.md)).
4. All failing: `curl -v https://<cloudfront>/api/health` from your laptop. If that works, look at the canary Lambda's own logs (`/aws/lambda/ticketrush-prod-canary`).
