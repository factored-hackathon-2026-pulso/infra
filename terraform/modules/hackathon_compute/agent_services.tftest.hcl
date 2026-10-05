mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_route53_zone" {
    defaults = {
      name = "pulso.internal"
    }
  }
  mock_resource "aws_instance" {
    defaults = {
      arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/pulso-hk-dlm"
    }
  }
}

variables {
  name_prefix           = "pulso-hk"
  region                = "us-east-1"
  workload              = "core"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_ids    = ["sg-0123456789abcdef0"]
  instance_profile_name = "pulso-hk-core"
  private_zone_id       = "Z0123456789ABCDEFGHIJ"
  ssm_prefix            = "/pulso-hk"
  bucket_name           = "pulso-hk-data"
  secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk-abc123"
  kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  ecr_registry_url      = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  images = {
    core        = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gateway     = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso       = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
}

# Separate file: runs of one file share state, and the db volume of the Postgres runs is protected from destroy.

# ---- agent services (agent-core serve, tool-service) on the core host ----

run "agent_services_render_files_and_sync_the_publication" {
  command = apply
  variables {
    workload           = "core"
    instance_type      = "m7i-flex.large"
    extra_service_envs = ["agent", "tools"]
    extra_ports        = ["8001:8001"]
    compose_files      = ["compose.yaml", "compose.agents.yaml"]
    extra_bundle_files = { "compose.agents.yaml" = "services: {}\n" }
  }

  assert {
    condition     = contains(local.allowed_ports, "8001:8001") && contains(local.allowed_ports, "8000:8000")
    error_message = "agent-core serve publishes 8001 next to core-runtime's 8000."
  }
  assert {
    condition     = strcontains(local.prepare_script, "AGENT|TOOLS") && strcontains(local.prepare_script, "SERVICES=\"common core gateway agent tools\"")
    error_message = "agent.env and tools.env are rendered from the AGENT__ and TOOLS__ secret keys."
  }
  assert {
    condition     = strcontains(local.prepare_script, "FILES__") && strcontains(local.prepare_script, "/run/pulso/files")
    error_message = "FILES__<SVC>__<NAME> secret keys become files under /run/pulso/files/<svc>/, never env lines."
  }
  assert {
    condition     = strcontains(local.prepare_script, "lake/publish/latest.json") && strcontains(local.prepare_script, "gold_restricted.duckdb")
    error_message = "With tool-service on the host, the start script syncs the current publication before compose starts."
  }
  assert {
    condition     = strcontains(local.env_text, "COMPOSE_FILE=compose.yaml:compose.agents.yaml")
    error_message = ".env selects the agent services compose override."
  }
}

run "agent_host_syncs_the_calibration_and_classifier_artifacts" {
  command = apply
  variables {
    workload           = "core"
    instance_type      = "m7i-flex.large"
    extra_service_envs = ["agent", "tools"]
    extra_ports        = ["8001:8001"]
    compose_files      = ["compose.yaml", "compose.agents.yaml"]
    extra_bundle_files = { "compose.agents.yaml" = "services: {}\n" }
  }

  assert {
    condition     = strcontains(local.prepare_script, "s3://$BUCKET/core/artifacts/") && strcontains(local.prepare_script, "for d in calibrations classifiers") && strcontains(local.prepare_script, "/srv/data/agent/artifacts/$d/")
    error_message = "With agent-core on the host, the start script syncs core/artifacts/ (calibrations, classifiers) to the read-only mount."
  }
}

run "hosts_without_tool_service_never_sync_the_publication" {
  command = apply
  variables {
    workload = "core"
  }

  assert {
    condition     = !strcontains(local.prepare_script, "lake/publish") && !strcontains(local.prepare_script, "core/artifacts") && local.allowed_ports == ["8000:8000"]
    error_message = "Without the agent services nothing reads the restricted publication and only 8000 is published."
  }
}

run "extra_ports_are_host_colon_container" {
  command = plan
  variables {
    extra_ports = ["8001"]
  }
  expect_failures = [var.extra_ports]
}
