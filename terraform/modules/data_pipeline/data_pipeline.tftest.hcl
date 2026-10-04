mock_provider "aws" {
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/data-pipeline:3"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test-data-pipeline-task"
    }
  }
}

variables {
  image                       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-data-pipeline@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  cluster_arn                 = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  subnet_ids                  = ["subnet-0123456789abcdef0"]
  security_group_ids          = ["sg-0123456789abcdef0"]
  aws_region                  = "us-east-1"
  log_group_name              = "/pulso/test/data-pipeline"
  cpu                         = 2048
  memory                      = 8192
  lake_bucket_name            = "test-data-lake"
  dataset_bucket              = "challenge-dataset-bucket"
  pseudonym_key_secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:data-pipeline-pseudonym-key"
  dataset_reader_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:data-pipeline-dataset-reader"
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  tags                        = { Environment = "test" }
}

run "it_is_a_batch_task_with_no_service_and_no_listener" {
  command = apply

  assert {
    condition     = module.task.service_name == null
    error_message = "The pipeline runs to completion: no ECS service."
  }

  assert {
    condition     = !can(output.container_definition.portMappings)
    error_message = "No inbound path: the container exposes no port."
  }

  assert {
    condition     = output.container_definition.image == var.image
    error_message = "The container must run the exact digest image."
  }
}

run "dataset_credentials_never_use_the_standard_aws_variables" {
  command = apply

  assert {
    condition = alltrue([
      for s in output.container_definition.secrets : !contains(["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"], s.name)
    ])
    error_message = "AWS_* outranks the task role: the organisers' read-only keys must not be injected under those names."
  }

  assert {
    condition = alltrue([
      for e in output.container_definition.environment : !contains(["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"], e.name)
    ])
    error_message = "No credential travels as a plain environment variable."
  }

  assert {
    condition     = anytrue([for s in output.container_definition.secrets : s.name == "DATASET_AWS_ACCESS_KEY_ID" && endswith(s.valueFrom, ":access_key_id::")])
    error_message = "The dataset key id comes from the JSON key access_key_id of its own secret."
  }

  assert {
    condition     = anytrue([for s in output.container_definition.secrets : s.name == "DATASET_AWS_SECRET_ACCESS_KEY" && endswith(s.valueFrom, ":secret_access_key::")])
    error_message = "The dataset secret comes from the JSON key secret_access_key of its own secret."
  }

  assert {
    condition     = anytrue([for s in output.container_definition.secrets : s.name == "PSEUDONYM_KEY" && s.valueFrom == var.pseudonym_key_secret_arn])
    error_message = "The pseudonym key is injected from its secret."
  }
}

run "lake_and_dataset_have_their_own_region" {
  command = apply

  assert {
    condition     = anytrue([for e in output.container_definition.environment : e.name == "PIPELINE_ROOT" && e.value == "s3://test-data-lake"])
    error_message = "The lake root is the lake bucket."
  }

  assert {
    condition     = anytrue([for e in output.container_definition.environment : e.name == "DATASET_REGION" && e.value == "us-east-2"]) && anytrue([for e in output.container_definition.environment : e.name == "AWS_DEFAULT_REGION" && e.value == "us-east-1"])
    error_message = "The dataset (us-east-2) and the lake (task region) must not share a region."
  }

  assert {
    condition     = !anytrue([for e in output.container_definition.environment : e.name == "S3_KMS_KEY_ID"])
    error_message = "Without a key the uploads use the bucket default."
  }
}

run "a_kms_key_reaches_the_task_and_the_bucket" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = anytrue([for e in output.container_definition.environment : e.name == "S3_KMS_KEY_ID" && e.value == var.kms_key_arn])
    error_message = "The task must upload with the lake key."
  }
}

run "the_task_role_is_the_only_reader_of_bronze" {
  command = apply

  assert {
    condition = anytrue([
      for s in jsondecode(module.lake.bucket_policy_json).Statement :
      s.Sid == "DenyReadBronzeExceptPipeline" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == [module.iam.task_role_arn]
    ])
    error_message = "The lake must trust exactly the role this workload runs as."
  }
}

run "unconfigured_readers_fail_closed" {
  command = apply

  assert {
    condition = anytrue([
      for s in jsondecode(module.lake.bucket_policy_json).Statement :
      s.Sid == "DenyReadRestrictedExceptRestrictedReaders" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::000000000000:role/data-lake-no-principal"]
    ])
    error_message = "With no restricted reader configured, nobody reads personal data in clear."
  }
}

run "no_schedule_means_manual_runs_only" {
  command = apply

  assert {
    condition     = output.schedule_arn == null
    error_message = "A schedule exists only when an expression is given."
  }
}

run "a_schedule_is_created_when_an_expression_is_given" {
  command = apply

  variables {
    schedule_expression = "cron(0 6 * * ? *)"
  }

  assert {
    condition     = output.schedule_arn != null
    error_message = "The expression must create the schedule."
  }
}

run "a_mutable_image_tag_is_refused" {
  command = plan

  variables {
    image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-data-pipeline:latest"
  }

  expect_failures = [var.image]
}
