data "archive_file" "zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/build/${var.name}.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:AWS-managed encryption (no CMK by project decision).
  #checkov:skip=CKV_AWS_338:Short retention is intentional to control cost.
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "logs" {
  name   = "logs-and-tracing"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.logs.json
}

resource "aws_iam_role_policy" "extra" {
  count  = var.attach_policy ? 1 : 0
  name   = "function-permissions"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_117:Functions call only public AWS APIs; putting them in the VPC adds NAT cost and cold-start latency.
  #checkov:skip=CKV_AWS_116:SQS-triggered function uses the queue's redrive DLQ; the scheduled canary needs none.
  #checkov:skip=CKV_AWS_115:Account concurrency limit is 10; reserving would starve other functions.
  #checkov:skip=CKV_AWS_173:Env vars hold no secrets; AWS-managed encryption applies.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope (image/code signing declined).
  function_name    = var.name
  role             = aws_iam_role.this.arn
  runtime          = var.runtime
  handler          = "handler.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment {
    variables = var.environment
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  depends_on = [aws_iam_role_policy.logs]
}
