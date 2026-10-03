mock_provider "aws" {}

variables {
  repository_name                 = "pulso/agent-core"
  kms_key_arn                     = ""
  github_oidc_provider_arn        = ""
  publish_subjects                = []
  least_privilege_policy_boundary = ""
  untagged_retention_days         = 14
  max_images                      = 100
  tags                            = { Environment = "test" }
}

run "repository_is_immutable_scanned_and_encrypted" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "Tags must be immutable: deploys use digests and a moved tag would hide a different image."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "Images must be scanned on push."
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "An empty kms_key_arn selects AES256."
  }
}

run "customer_managed_key_selects_kms_encryption" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/01234567-89ab-cdef-0123-456789abcdef"
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "KMS"
    error_message = "A configured key must select KMS encryption."
  }
}

run "no_publisher_without_an_approved_oidc_provider" {
  command = plan

  variables {
    publish_subjects = ["repo:pulso-factored/agent-core:environment:image-publish"]
  }

  assert {
    condition     = length(aws_iam_role.publisher) == 0 && length(aws_iam_role_policy.publisher) == 0
    error_message = "Without an approved provider no publisher role may exist."
  }
}

run "no_publisher_without_subjects" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_role.publisher) == 0
    error_message = "A provider alone must not create a role that nobody can assume."
  }
}

run "publisher_trust_is_pinned_to_one_repository_and_branch" {
  command = apply

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    publish_subjects         = ["repo:pulso-factored/agent-core:environment:image-publish"]
  }

  assert {
    condition     = jsondecode(aws_iam_role.publisher[0].assume_role_policy).Statement[0].Action == ["sts:AssumeRoleWithWebIdentity"]
    error_message = "The publisher trusts web identity only."
  }

  assert {
    condition     = jsondecode(aws_iam_role.publisher[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:pulso-factored/agent-core:environment:image-publish"]
    error_message = "The subject must be exactly the approved protected environment."
  }

  assert {
    condition     = !can(jsondecode(aws_iam_role.publisher[0].assume_role_policy).Statement[0].Condition.StringLike)
    error_message = "No wildcard (StringLike) condition may widen the trust."
  }
}

run "publisher_can_only_push_to_this_repository" {
  command = apply

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    publish_subjects         = ["repo:pulso-factored/agent-core:environment:image-publish"]
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_role_policy.publisher[0].policy).Statement : statement.Resource
      if statement.Sid == "PushToThisRepositoryOnly"
    ] == [[aws_ecr_repository.this.arn]]
    error_message = "Push actions are scoped to this repository's ARN."
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_role_policy.publisher[0].policy).Statement : statement.Sid
      if contains(statement.Resource, "*")
    ] == ["RegistryLogin"]
    error_message = "Only the registry login action may use a wildcard resource."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.publisher[0].policy).Statement :
      !contains(statement.Action, "ecr:BatchDeleteImage") && !contains(statement.Action, "ecr:DeleteRepository")
    ])
    error_message = "The publisher must not delete images or the repository."
  }
}

run "subjects_with_wildcards_are_rejected" {
  command = plan

  variables {
    publish_subjects = ["repo:pulso-factored/*:environment:image-publish"]
  }

  expect_failures = [var.publish_subjects]
}

run "branch_subjects_are_rejected" {
  command = plan

  variables {
    publish_subjects = ["repo:pulso-factored/agent-core:ref:refs/heads/main"]
  }

  expect_failures = [var.publish_subjects]
}
