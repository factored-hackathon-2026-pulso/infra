# Storage encryption contract v1

Both `source` and `artifact` buckets accept `PutObject` only when the caller
explicitly supplies all of the following request headers:

```text
x-amz-server-side-encryption: aws:kms
x-amz-server-side-encryption-aws-kms-key-id: <configured kms_key_arn>
```

The bucket default remains SSE-KMS with the same key and Bucket Keys enabled,
but it is not an authorization bypass. The deny-only bucket policy rejects a
missing key header, a non-KMS algorithm, or any other key ARN. This prevents a
caller from overriding default encryption to SSE-S3 or another CMK.

Consumers must preserve these headers in local/sandbox and AWS adapters. A
future integration test against an S3-compatible sandbox should exercise
accepted and denied writes; Terraform validation alone cannot prove provider
request semantics.
