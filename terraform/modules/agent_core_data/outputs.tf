output "blob_bucket_name" { value = aws_s3_bucket.blobs.bucket }
output "blob_bucket_arn" { value = aws_s3_bucket.blobs.arn }
output "events_topic_arn" { value = aws_sns_topic.events.arn }
output "consumer_queue_arns" { value = { for k, q in aws_sqs_queue.consumer : k => q.arn } }
output "consumer_queue_urls" { value = { for k, q in aws_sqs_queue.consumer : k => q.url } }
output "dead_letter_queue_arns" { value = { for k, q in aws_sqs_queue.dlq : k => q.arn } }
