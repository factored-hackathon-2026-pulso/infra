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
# Wiring of agent-core serve (docs/agent-core-serve.md), the improvement loop (docs/engine-loop.md) and the OTLP forwarder
# (docs/otlp-forwarder.md). Everything is off by default.

run "nothing_new_is_wired_by_default" {
  command = apply

  assert {
    condition     = join(",", module.compute_engine.compose_files) == "compose.yaml" && length(module.compute_engine.extra_bundle_keys) == 0
    error_message = "Without the flags the engine bundle is unchanged."
  }
  assert {
    condition     = !contains(module.compute_core.service_env_names, "langfuse") && !contains(module.compute_engine.service_env_names, "langfuse") && !strcontains(module.compute_core.bundle_env, "OTLP_TRACE_CONTENT") && !strcontains(module.compute_engine.bundle_env, "PULSO_CELLS_SOURCE")
    error_message = "No forwarder env, no loop knob."
  }
  assert {
    condition     = !contains(keys(output.image_build_projects), "otlp-forwarder")
    error_message = "No forwarder build project by default."
  }
}

run "serve_replaces_the_core_bridge_and_takes_its_caps_from_the_instance" {
  command = apply
  variables {
    agent_services_enabled = true
    images = {
      core = {
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
    condition     = contains(module.compute_core.extra_bundle_keys, "compose.agents.postgres.yaml") && contains(module.compute_core.extra_bundle_keys, "sweep/pulso-agent-sweep.service") && contains(module.compute_core.extra_bundle_keys, "sweep/pulso-agent-sweep.timer")
    error_message = "The container-mode ordering file and the sweep units ship with the core bundle."
  }
  assert {
    condition     = contains(keys(module.compute_core.image_parameter_names), "core") && module.compute_core.image_parameter_names["core"] != module.compute_core.image_parameter_names["agent"]
    error_message = "CORE_IMAGE is still seeded (it aliases the agent digest) so compose can interpolate the disabled legacy services."
  }
  assert {
    condition     = strcontains(module.compute_core.bundle_env, "AGENT_MAX_INFLIGHT=32") && strcontains(module.compute_core.bundle_env, "AGENT_WORKER_THREADS=16") && strcontains(module.compute_core.bundle_env, "AGENT_DB_POOL_MAX=10")
    error_message = "m7i-flex.large (8 GiB, the free_plan core) gets the largest load caps."
  }
  assert {
    condition     = strcontains(module.compute_core.bundle_env, "AGENT_SERVE_ARGS=\n") && strcontains(module.compute_core.bundle_env, "AGENT_SERVE_AGENTS=recepcion,disputas,consultas,copiloto-asesor")
    error_message = "No piece flags; the serve agents are the default four."
  }
  assert {
    condition     = !strcontains(module.compute_core.bundle_env, "ALLOW_DOUBLES") && !strcontains(module.compute_core.bundle_env, "ALLOW_DEMO")
    error_message = "The doubles switch is never in the bundle environment."
  }
}

run "a_two_gib_core_gets_small_caps" {
  command = apply
  variables {
    agent_services_enabled = true
    instance_types         = { core = "t3.small", platform = "t3.small", engine = "t3.small" }
    images = {
      core = {
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
    condition     = strcontains(module.compute_core.bundle_env, "AGENT_MAX_INFLIGHT=8") && strcontains(module.compute_core.bundle_env, "AGENT_DB_POOL_MAX=4")
    error_message = "Load caps follow the instance memory."
  }
}

run "an_explicit_legacy_core_image_is_kept" {
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
    condition     = contains(keys(module.compute_core.image_parameter_names), "core")
    error_message = "A legacy core digest, when given, is still seeded."
  }
}

run "serve_args_cannot_enable_the_doubles" {
  command = plan
  variables {
    agent_serve_args = "--allow-doubles"
  }
  expect_failures = [var.agent_serve_args]
}

run "serve_args_cannot_name_a_testing_piece" {
  command = plan
  variables {
    agent_serve_args = "--tools testing.fakes:tools"
  }
  expect_failures = [var.agent_serve_args]
}

run "loop_needs_agent_services" {
  command = plan
  variables {
    engine_loop_enabled = true
  }
  expect_failures = [var.engine_loop_enabled]
}

run "demo_profile_only_with_synthetic_cells" {
  command = plan
  variables {
    engine_loop_profile = "demo"
  }
  expect_failures = [var.engine_loop_profile]
}

run "loop_wires_the_compose_file_scripts_units_and_knobs" {
  command = apply
  variables {
    agent_services_enabled = true
    engine_loop_enabled    = true
    engine_loop_interval   = "3h"
    images = {
      core = {
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
    condition     = join(",", module.compute_engine.compose_files) == "compose.yaml,compose.loop.yaml"
    error_message = "The engine host merges the loop job file."
  }
  assert {
    condition     = alltrue([for k in ["compose.loop.yaml", "loop/pulso-inputs-sync.sh", "loop/pulso-loop-status.sh", "loop/pulso-loop.service", "loop/pulso-loop.timer", "loop/pulso-loop-failed.service", "loader/check_cells_k.py"] : contains(module.compute_engine.extra_bundle_keys, k)])
    error_message = "The loop files ship with the engine bundle."
  }
  assert {
    condition     = strcontains(module.compute_engine.bundle_env, "PULSO_CELLS_SOURCE=bank") && strcontains(module.compute_engine.bundle_env, "PULSO_LOOP_PROFILE=standard")
    error_message = "The cells source defaults to the loader bank cells and the profile to standard."
  }
  assert {
    condition     = !contains(module.compute_engine.service_env_names, "loader")
    error_message = "The loop does not need the loader env: the loader is not duplicated."
  }
}

run "synthetic_demo_loop" {
  command = apply
  variables {
    agent_services_enabled   = true
    engine_loop_enabled      = true
    engine_loop_cells_source = "synthetic"
    engine_loop_profile      = "demo"
    images = {
      core = {
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
    condition     = strcontains(module.compute_engine.bundle_env, "PULSO_CELLS_SOURCE=synthetic") && strcontains(module.compute_engine.bundle_env, "PULSO_LOOP_PROFILE=demo")
    error_message = "Demo floors only with synthetic cells."
  }
}

run "loop_and_loader_share_the_gate_script_without_conflict" {
  command = apply
  variables {
    agent_services_enabled = true
    engine_loop_enabled    = true
    auto_loader_enabled    = true
    images = {
      core = {
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
        pulso    = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy    = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        pipeline = "r/pulso-prod/data-pipeline@sha256:3333333333333333333333333333333333333333333333333333333333333333"
      }
    }
  }

  assert {
    condition     = contains(module.compute_engine.extra_bundle_keys, "loader/check_cells_k.py") && contains(module.compute_engine.extra_bundle_keys, "loader/pulso-loader.sh") && contains(module.compute_engine.extra_bundle_keys, "loop/pulso-loop.service")
    error_message = "Both features ship their files; the gate script is one key."
  }
}

run "forwarder_needs_its_image_on_both_hosts" {
  command = plan
  variables {
    otlp_forwarder_enabled = true
  }
  expect_failures = [var.images]
}

run "forwarder_wires_sidecars_secret_names_and_flags" {
  command = apply
  variables {
    agent_services_enabled = true
    otlp_forwarder_enabled = true
    images = {
      core = {
        gateway   = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        agent     = "r/pulso-prod/agent-core-serve@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        tools     = "r/pulso-prod/tool-service@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        forwarder = "r/pulso-prod/otlp-forwarder@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso     = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy     = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        forwarder = "r/pulso-prod/otlp-forwarder@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      }
    }
  }

  assert {
    condition     = join(",", module.compute_core.compose_files) == "compose.yaml,compose.postgres.yaml,compose.agents.yaml,compose.agents.postgres.yaml,compose.observability.yaml" && join(",", module.compute_engine.compose_files) == "compose.yaml,compose.observability.yaml"
    error_message = "Each host merges its observability file last."
  }
  assert {
    condition     = contains(module.compute_core.service_env_names, "langfuse") && contains(module.compute_engine.service_env_names, "langfuse") && !contains(module.compute_platform.service_env_names, "langfuse")
    error_message = "langfuse.env on the core and engine hosts only; the platform has no OTLP producer."
  }
  assert {
    condition     = strcontains(module.compute_core.bundle_env, "OTLP_TRACE_CONTENT=0") && strcontains(module.compute_engine.bundle_env, "OTLP_TRACE_CONTENT=0")
    error_message = "Content export is off unless otlp_trace_content is true."
  }
  assert {
    condition     = contains(module.compute_core.extra_bundle_keys, "compose.observability.yaml") && contains(module.compute_engine.extra_bundle_keys, "compose.observability.yaml")
    error_message = "Both observability files ship with their bundles."
  }
  assert {
    condition     = contains(keys(output.image_build_projects), "otlp-forwarder") && strcontains(output.deployer_policy_json_core, "parameter/pulso/core/images/forwarder") && strcontains(output.deployer_policy_json_engine, "parameter/pulso/engine/images/forwarder")
    error_message = "The forwarder image has a build project and both deployers may deploy it."
  }
}

run "forwarder_with_content_and_the_loop_joins_one_namespace" {
  command = apply
  variables {
    agent_services_enabled = true
    otlp_forwarder_enabled = true
    otlp_trace_content     = true
    engine_loop_enabled    = true
    images = {
      core = {
        gateway   = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        agent     = "r/pulso-prod/agent-core-serve@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        tools     = "r/pulso-prod/tool-service@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        forwarder = "r/pulso-prod/otlp-forwarder@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso     = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy     = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        forwarder = "r/pulso-prod/otlp-forwarder@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      }
    }
  }

  assert {
    condition     = join(",", module.compute_engine.compose_files) == "compose.yaml,compose.loop.yaml,compose.observability.yaml,compose.loop.observability.yaml"
    error_message = "The loop job joins the pulso namespace only when both features are on."
  }
  assert {
    condition     = strcontains(module.compute_core.bundle_env, "OTLP_TRACE_CONTENT=1") && strcontains(module.compute_engine.bundle_env, "OTLP_TRACE_CONTENT=1")
    error_message = "otlp_trace_content turns the content flags on for every producer at once."
  }
}

run "engine_key_rotation_variables_reach_the_ssm_kid" {
  command = apply
  variables {
    agent_services_enabled    = true
    engine_extra_key_suffixes = ["hk2"]
    engine_active_key_suffix  = "hk2"
    images = {
      core = {
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
    condition     = join(",", sort(keys(module.data.engine_published_keys))) == "pulso-engine-hk1,pulso-engine-hk2" && module.data.engine_core_kid == "pulso-engine-hk2"
    error_message = "The module receives the rotation variables: both kids published, the new one active."
  }
}

run "platform_url_cors_and_secrets_are_derived_not_typed" {
  command = apply
  variables {
    agent_services_enabled = true
    images = {
      core = {
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
    condition     = startswith(aws_ssm_parameter.platform_public["CC_PUBLIC_APP_URL"].value, "https://") && aws_ssm_parameter.platform_public["CC_CORS_ORIGINS"].value == jsonencode([aws_ssm_parameter.platform_public["CC_PUBLIC_APP_URL"].value])
    error_message = "CC_PUBLIC_APP_URL is the CloudFront origin and CC_CORS_ORIGINS a JSON list of it; nobody types them."
  }
  assert {
    condition     = length(module.data.ssm_prefix) > 0 && !contains(values({ for k, v in aws_ssm_parameter.platform_public : k => v.value }), "CHANGE_ME")
    error_message = "No CHANGE_ME in the platform SSM values."
  }
}
