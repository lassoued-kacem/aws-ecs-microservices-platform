# ---------------------------------------------------------------- ticket issuer
data "aws_iam_policy_document" "issuer" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.orders.arn]
  }
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.tickets.arn]
  }
}

module "ticket_issuer" {
  source                   = "../../modules/lambda-fn"
  name                     = "${local.name}-ticket-issuer"
  source_dir               = "${path.root}/../../../lambdas/ticket_issuer"
  timeout                  = 10
  environment              = { TICKETS_TABLE = aws_dynamodb_table.tickets.name }
  attach_policy            = true
  policy_json              = data.aws_iam_policy_document.issuer.json
  permissions_boundary_arn = local.boundary
  log_retention_days       = var.log_retention_days
}

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn                   = aws_sqs_queue.orders.arn
  function_name                      = module.ticket_issuer.function_arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"] # retry only failed messages
  scaling_config {
    maximum_concurrency = 3 # protects the small account concurrency pool (10)
  }
}

# ---------------------------------------------------------------- synthetic canary
module "canary" {
  source                   = "../../modules/lambda-fn"
  name                     = "${local.name}-canary"
  source_dir               = "${path.root}/../../../lambdas/canary"
  timeout                  = 30
  memory_size              = 128
  environment              = { TARGET_BASE_URL = "https://${aws_cloudfront_distribution.this.domain_name}" }
  permissions_boundary_arn = local.boundary
  log_retention_days       = 7
}

resource "aws_cloudwatch_event_rule" "canary" {
  name                = "${local.name}-canary"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "canary" {
  rule = aws_cloudwatch_event_rule.canary.name
  arn  = module.canary.function_arn
}

resource "aws_lambda_permission" "canary" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.canary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary.arn
}
