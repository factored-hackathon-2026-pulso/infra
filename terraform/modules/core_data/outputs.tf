output "blob_bucket_name" { value = aws_s3_bucket.blobs.bucket }
output "blob_bucket_arn" { value = aws_s3_bucket.blobs.arn }
output "events_topic_arn" { value = aws_sns_topic.events.arn }
output "consumer_queue_arns" { value = { for k, q in aws_sqs_queue.consumer : k => q.arn } }
output "consumer_queue_urls" { value = { for k, q in aws_sqs_queue.consumer : k => q.url } }
output "dead_letter_queue_arns" { value = { for k, q in aws_sqs_queue.dlq : k => q.arn } }

# Statements for `workload_iam.task_statements` of the Core workloads that serve and relay. No kms:, no
# secretsmanager:, no delete: the module validation in workload_iam would refuse them anyway.
output "task_statements" {
  value = [
    {
      Sid      = "ListBlobBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = [aws_s3_bucket.blobs.arn]
    },
    {
      Sid      = "ReadAndAddBlobs"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = ["${aws_s3_bucket.blobs.arn}/*"]
    },
    {
      Sid      = "PublishOutboundEvents"
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [aws_sns_topic.events.arn]
    },
  ]
}
