# Async backlog (tickets not issued)

Symptoms: "Issuing tickets…" never resolves; `orders-oldest-message` or `orders-dlq-not-empty` fires.

1. Lambda errors? CloudWatch Logs `/aws/lambda/ticketrush-prod-ticket-issuer`.
   - `AccessDenied dynamodb:PutItem`: IAM drift; run `make apply`.
   - Throttles: account concurrency is 10, and the event source mapping caps at 3.
2. **DLQ has messages:** inspect them: `aws sqs receive-message --queue-url $(aws sqs get-queue-url --queue-name ticketrush-prod-orders-dlq --query QueueUrl --output text) --max-number-of-messages 5`
3. Once fixed, **redrive** back to the main queue (safe, because the consumer is idempotent):
   `aws sqs start-message-move-task --source-arn <dlq arn> --destination-arn <orders queue arn>`
