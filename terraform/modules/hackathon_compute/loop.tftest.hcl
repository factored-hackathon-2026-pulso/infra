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

# Separate file: runs of one file share state.
# The improvement-loop job (docs/engine-loop.md), the agent-core sweep timer, the in-place key files and the doubles guard in the start script.

run "loop_is_off_by_default" {
  command = apply
  variables {
    workload = "engine"
  }

  assert {
    condition     = !strcontains(local.prepare_script, "pulso-loop") && !strcontains(local.prepare_script, "/srv/data/inputs")
    error_message = "Without loop_enabled the engine host installs nothing of the loop."
  }
}

run "loop_installs_scripts_units_and_the_interval_dropin" {
  command = apply
  variables {
    workload      = "engine"
    loop_enabled  = true
    loop_interval = "90min"
    extra_bundle_files = {
      "compose.loop.yaml"       = "services: {}\n"
      "loop/pulso-loop.service" = "[Unit]\n"
      "loader/check_cells_k.py" = "print(1)\n"
    }
    compose_files = ["compose.yaml", "compose.loop.yaml"]
  }

  assert {
    condition     = strcontains(local.prepare_script, "install -m 755 /srv/stack/loop/pulso-inputs-sync.sh /usr/local/bin/pulso-inputs-sync") && strcontains(local.prepare_script, "install -m 755 /srv/stack/loop/pulso-loop-status.sh /usr/local/bin/pulso-loop-status")
    error_message = "The inputs sync and the status hook are installed from the bundle."
  }
  assert {
    condition     = strcontains(local.prepare_script, "OnUnitActiveSec=%s\\n' \"90min\"") && strcontains(local.prepare_script, "systemctl enable --now pulso-loop.timer")
    error_message = "The timer interval is the variable, in a drop-in, and the timer is enabled."
  }
  assert {
    condition     = strcontains(local.prepare_script, "mkdir -p /srv/data/inputs /srv/data/loop /srv/data/pulso/work") && strcontains(local.prepare_script, "chown 10001:10001 /srv/data/pulso/work")
    error_message = "The inputs mirror, the status directory and the work directory exist and the work directory belongs to the engine user."
  }
  assert {
    condition     = strcontains(local.prepare_script, "/usr/local/lib/pulso-loader/check_cells_k.py")
    error_message = "The loop reuses the loader's k gate script even when the loader is off."
  }
  assert {
    condition     = strcontains(local.env_text, "COMPOSE_FILE=compose.yaml:compose.loop.yaml")
    error_message = ".env selects the loop compose file."
  }
}

run "loop_interval_is_a_systemd_span" {
  command = plan
  variables {
    workload      = "engine"
    loop_enabled  = true
    loop_interval = "soon"
  }
  expect_failures = [var.loop_interval]
}

run "the_loop_is_installed_on_the_engine_host_only" {
  command = apply
  variables {
    workload     = "core"
    loop_enabled = true
  }

  assert {
    condition     = !strcontains(local.prepare_script, "pulso-loop.timer")
    error_message = "loop_enabled means nothing on the core or platform host."
  }
}

run "agent_host_schedules_the_sweep" {
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
    condition     = strcontains(local.prepare_script, "systemctl enable --now pulso-agent-sweep.timer") && strcontains(local.prepare_script, "/srv/stack/sweep/pulso-agent-sweep.service")
    error_message = "agent-core sweep --once runs from a timer on the host that runs serve."
  }
  assert {
    condition     = !strcontains(local.prepare_script, "%%{")
    error_message = "The rendered script has no template directives left."
  }
}

run "hosts_without_agent_services_have_no_sweep" {
  command = apply
  variables {
    workload = "core"
  }

  assert {
    condition     = !strcontains(local.prepare_script, "pulso-agent-sweep")
    error_message = "No sweep timer without agent-core."
  }
}

run "doubles_can_never_reach_an_env_file_and_key_files_are_rewritten_in_place" {
  command = apply
  variables {
    workload           = "core"
    extra_service_envs = ["agent", "tools"]
    compose_files      = ["compose.yaml", "compose.agents.yaml"]
    extra_bundle_files = { "compose.agents.yaml" = "services: {}\n" }
  }

  assert {
    condition     = strcontains(local.prepare_script, "grep -qE '^AGENTCORE_ALLOW_(DOUBLES|DEMO)=' /run/pulso/env/*.env") && strcontains(local.prepare_script, "refusing to start")
    error_message = "The start script aborts when AGENTCORE_ALLOW_DOUBLES or AGENTCORE_ALLOW_DEMO reaches an env file."
  }
  assert {
    condition     = !strcontains(local.prepare_script, "rm -rf /run/pulso/files") && strcontains(local.prepare_script, "xargs -r rm -f")
    error_message = "Key files keep their inode (serve reloads them every 5 seconds); only files that left the secret are removed."
  }
}
