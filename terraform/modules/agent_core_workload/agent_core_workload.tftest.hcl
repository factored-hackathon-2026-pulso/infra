mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn                  = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
      arn_without_revision = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-secret" }
  }
}

variables {
  aws_region               = "us-east-1"
  image                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  cluster_arn              = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  cluster_name             = "test-pulso"
  private_subnet_ids       = ["subnet-0123456789abcdef0"]
  security_group_ids       = ["sg-0123456789abcdef0"]
  target_group_arn         = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/0123456789abcdef"
  target_group_arn_suffix  = "targetgroup/test/0123456789abcdef"
  load_balancer_arn_suffix = "app/test/0123456789abcdef"
  blob_bucket_name         = "test-agent-core-blobs"
  blob_bucket_arn          = "arn:aws:s3:::test-agent-core-blobs"
  events_topic_arn         = "arn:aws:sns:us-east-1:123456789012:test-agent-core-events"
  secret_name_prefix       = "test/agent-core"
  log_retention_days       = 14
  tags                     = { Environment = "test" }
}

run "an_image_pinned_by_tag_is_rejected" {
  command = plan

  variables {
    image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test/agent-core:latest"
  }

  expect_failures = [var.image]
}

run "demo_mode_is_refused_outside_prod" {
  command = plan

  variables {
    allow_demo = true
  }

  expect_failures = [aws_ecs_task_definition.role]
}

run "demo_mode_is_accepted_in_the_prod_demo" {
  command = plan

  variables {
    allow_demo = true
    tags       = { Environment = "prod" }
  }

  assert {
    condition     = aws_ecs_task_definition.role["serve"].family == "prod-agent-core-serve"
    error_message = "The prod demo may enable demo mode."
  }
}

run "each_role_gets_only_the_secrets_it_needs" {
  command = apply

  assert {
    condition     = !strcontains(aws_ecs_task_definition.role["relay"].container_definitions, "AGENTCORE_JEV_API_KEY") && strcontains(aws_ecs_task_definition.role["relay"].container_definitions, "AGENTCORE_REGISTRY_DSN")
    error_message = "The relay needs only the database DSN."
  }

  assert {
    condition     = !strcontains(aws_ecs_task_definition.role["sweep"].container_definitions, "AGENTCORE_KEYS_FINGERPRINT")
    error_message = "The sweep must not receive signing keys."
  }

  assert {
    condition     = strcontains(aws_ecs_task_definition.role["serve"].container_definitions, "AGENTCORE_JEV_API_KEY") && strcontains(aws_ecs_task_definition.role["serve"].container_definitions, "LLM_ENDPOINTS")
    error_message = "The API needs the full contract of ADR 0003."
  }

  assert {
    condition     = !strcontains(aws_ecs_task_definition.role["migrate"].container_definitions, "AGENTCORE_JEV_API_KEY")
    error_message = "The migration task needs only the DSNs."
  }
}

run "demo_mode_is_off_unless_asked" {
  command = apply

  assert {
    condition     = !strcontains(aws_ecs_task_definition.role["serve"].container_definitions, "AGENTCORE_ALLOW_DEMO")
    error_message = "AGENTCORE_ALLOW_DEMO must be unset in deployed environments."
  }
}

run "roles_use_the_image_commands" {
  command = apply

  assert {
    condition     = strcontains(aws_ecs_task_definition.role["sweep"].container_definitions, "--once") && strcontains(aws_ecs_task_definition.role["relay"].container_definitions, "relay") && strcontains(aws_ecs_task_definition.role["migrate"].container_definitions, "migrate")
    error_message = "Each role runs its own agentcore subcommand."
  }
}

run "autoscaling_bounds_follow_the_inputs" {
  command = plan

  assert {
    condition     = aws_appautoscaling_target.serve.min_capacity == 0 && aws_appautoscaling_target.serve.max_capacity == 4
    error_message = "Autoscaling bounds follow the module inputs."
  }
}
