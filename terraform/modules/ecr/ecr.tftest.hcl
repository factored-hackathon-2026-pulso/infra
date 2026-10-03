mock_provider "aws" {}

variables {
  repository_name = "test/agent-core"
  tags            = { Environment = "test" }
}

run "images_are_immutable_and_scanned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "Deployments pin digests; tags must not be movable."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "Images must be scanned on push."
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "Without a key the repository uses AES256."
  }
}

run "a_key_selects_kms_encryption" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "KMS"
    error_message = "A customer-managed key must select KMS."
  }
}
