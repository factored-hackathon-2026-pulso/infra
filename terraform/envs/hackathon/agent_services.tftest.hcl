mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id = "pl-0123456789abcdef0"
    }
  }
  mock_data "aws_cloudfront_cache_policy" {
    defaults = {
      id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    }
  }
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = {
      id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
    }
  }
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
  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/pulso-hk-boundary"
    }
  }
  mock_resource "aws_instance" {
    defaults = {
      arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk/hackathon-AbCdEf"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/pulso-hk-dlm"
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

# region, cloudfront_waf_region, ecr_registry_url, the principal lists and name_prefix are deliberately NOT set:
# a fresh prod account must plan with defaults only.
variables {
  images = {
    core = {
      core    = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      gateway = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    platform = {
      support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
    engine = {
      pulso = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      proxy = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
  }
}

# Separate file: runs of one file share state.
# Agent services (docs/agent-services.md): agent-core serve and tool-service on the core host, platform side wired.

run "agent_services_are_off_by_default" {
  command = apply

  assert {
    condition     = join(",", module.compute_core.compose_files) == "compose.yaml,compose.postgres.yaml" && join(",", module.compute_platform.compose_files) == "compose.yaml"
    error_message = "Without agent_services_enabled the bundles are unchanged."
  }
  assert {
    condition     = join(",", module.compute_core.published_ports) == "8000:8000,5432:5432,8080:8080" && join(",", module.compute_platform.published_ports) == "80:80"
    error_message = "Without agent_services_enabled no new port is published."
  }
  assert {
    condition     = output.agent_services_effective.enabled == false && length(output.agent_services_effective.restricted_readers) == 0
    error_message = "Nobody but the loader and break-glass reads the restricted publication."
  }
}

run "agent_services_wire_core_platform_network_iam_and_data" {
  command = apply
  variables {
    agent_services_enabled = true
    images = {
      core = {
        core    = "r/pulso-prod/core-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        gateway = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        agent   = "r/pulso-prod/agent-core-serve@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        tools   = "r/pulso-prod/tool-service@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
    }
  }

  assert {
    condition     = join(",", module.compute_core.compose_files) == "compose.yaml,compose.postgres.yaml,compose.agents.yaml,compose.agents.postgres.yaml"
    error_message = "The core host merges the agent services override after the Postgres one, then the container-mode ordering file."
  }
  assert {
    condition     = contains(module.compute_core.extra_bundle_keys, "compose.agents.yaml") && contains(module.compute_core.extra_bundle_keys, "initdb/sql/20_agent_databases.sql")
    error_message = "The override and the agent database SQL are published with the core bundle."
  }
  assert {
    condition     = contains(module.compute_core.service_env_names, "agent") && contains(module.compute_core.service_env_names, "tools")
    error_message = "agent.env and tools.env are rendered on the core host."
  }
  assert {
    condition     = contains(module.compute_core.published_ports, "8001:8001") && contains(module.compute_platform.published_ports, "8000:8000")
    error_message = "agent-core serve on core:8001; the platform API on platform:8000 for grant_active."
  }
  assert {
    condition     = join(",", module.compute_platform.compose_files) == "compose.yaml,compose.agents.yaml" && contains(module.compute_platform.extra_bundle_keys, "compose.agents.yaml")
    error_message = "The platform host merges its agent override."
  }
  assert {
    condition     = output.agent_services_effective.enabled && join(",", output.agent_services_effective.restricted_readers) == module.iam.instance_role_arn_core
    error_message = "Only the core host role joins the restricted publication readers."
  }
  assert {
    condition     = contains(keys(output.image_build_projects), "agent-core-serve") && contains(keys(output.image_build_projects), "tool-service")
    error_message = "The two new images have build projects."
  }
  assert {
    condition     = strcontains(output.deployer_policy_json_core, "parameter/pulso/core/images/agent") && strcontains(output.deployer_policy_json_core, "repository/pulso-prod/tool-service")
    error_message = "The core deployer may deploy the two new images."
  }
}

run "serve_takes_no_piece_flags_by_default" {
  command = plan

  assert {
    condition     = var.agent_serve_args == "" && var.agent_serve_agents == "recepcion,disputas,consultas,copiloto-asesor"
    error_message = "The seven real pieces are serve's defaults (agent-core PRs 62 to 70): no piece flag, only optional extras."
  }
}

run "agent_core_host_reads_the_artifacts_prefix" {
  command = apply
  variables {
    agent_services_enabled = true
    images = {
      core = {
        core    = "r/pulso-prod/core-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        gateway = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        agent   = "r/pulso-prod/agent-core-serve@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        tools   = "r/pulso-prod/tool-service@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
    }
  }

  assert {
    condition     = strcontains(jsonencode(output.agent_services_effective.core_read_prefixes), "core/artifacts") && strcontains(jsonencode(output.agent_services_effective.core_read_prefixes), "lake/publish")
    error_message = "The core host reads the publication and core/artifacts (read-only)."
  }
}

run "agent_services_need_both_image_digests" {
  command = plan
  variables {
    agent_services_enabled = true
  }
  expect_failures = [var.images]
}

run "platform_database_needs_agent_services" {
  command = plan
  variables {
    platform_database_enabled = true
  }
  expect_failures = [var.platform_database_enabled]
}

run "platform_database_publishes_sql_and_engine_wiring" {
  command = apply
  variables {
    agent_services_enabled    = true
    platform_database_enabled = true
    images = {
      core = {
        core    = "r/pulso-prod/core-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        gateway = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        agent   = "r/pulso-prod/agent-core-serve@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        tools   = "r/pulso-prod/tool-service@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
    }
  }

  assert {
    condition     = contains(module.compute_core.extra_bundle_keys, "initdb/sql/25_platform_databases.sql") && contains(module.compute_core.extra_bundle_keys, "initdb/sql/26_platform_exporter_grants.sql")
    error_message = "The platform database SQL and the exporter grants ship with the core bundle."
  }
  assert {
    condition = alltrue([for k in ["PULSO_PLATFORM_URL", "PULSO_REGISTRY_ADDR", "PULSO_ANNOUNCE_TO_PLATFORM", "PULSO_SOURCE_ADAPTER", "PULSO_SOURCE_SCHEMA"] :
    contains(keys(aws_ssm_parameter.engine_platform), k)])
    error_message = "The engine learns the platform URL, the serve registry address and the platform event-log adapter from SSM."
  }
  assert {
    condition     = aws_ssm_parameter.engine_platform["PULSO_SOURCE_ADAPTER"].value == "product-postgres" && endswith(aws_ssm_parameter.engine_platform["PULSO_PLATFORM_URL"].name, "/engine/pulso/PULSO_PLATFORM_URL")
    error_message = "Engine reads the platform through the read-only Postgres role; names are the engine's own variables."
  }
  assert {
    condition     = module.data.engine_data_mode == "platform"
    error_message = "product-postgres is valid only with PULSO_DATA_MODE=platform; the engine refuses dataset + product-postgres at startup."
  }
}

run "engine_platform_params_absent_by_default" {
  command = plan

  assert {
    condition     = length(aws_ssm_parameter.engine_platform) == 0
    error_message = "No engine -> platform wiring without platform_database_enabled."
  }
  assert {
    condition     = module.data.engine_data_mode == "dataset"
    error_message = "Without the platform event log the engine stays in dataset mode (no product-* adapter)."
  }
}
