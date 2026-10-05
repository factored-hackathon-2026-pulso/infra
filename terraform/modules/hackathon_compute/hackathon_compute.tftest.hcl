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

run "bundle_rules_core" {
  command = apply
  variables {
    workload = "core"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = try(local.compose.services["llm-gateway"].ports, []) == ["8080:8080"]
    error_message = "The gateway is published on 8080 only: the engine host calls it by the core private IP (security group: engine only)."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 3
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "core.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "bundle_rules_platform" {
  command = apply
  variables {
    workload = "platform"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = !contains(keys(try(local.compose.services["llm-gateway"], {})), "ports")
    error_message = "The gateway is never published."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 2
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "platform.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "bundle_rules_engine" {
  command = apply
  variables {
    workload = "engine"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = !contains(keys(try(local.compose.services["llm-gateway"], {})), "ports")
    error_message = "The gateway is never published."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 2
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "engine.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "defaults_are_hardened" {
  command = apply

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.associate_public_ip_address == false
    error_message = "Root volume encrypted, host private."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t3.small"
    error_message = "Default instance type is t3.small."
  }
}

run "data_volume_sizes_per_workload" {
  command = apply
  variables {
    data_volume_size_gb = 40
  }
  assert {
    condition     = aws_ebs_volume.data_protected[0].encrypted && aws_ebs_volume.data_protected[0].type == "gp3" && aws_ebs_volume.data_protected[0].size == 40
    error_message = "Data volume honors the per-workload size."
  }
  assert {
    condition     = aws_dlm_lifecycle_policy.data.policy_details[0].schedule[0].retain_rule[0].count == 3
    error_message = "Daily snapshots keep 3."
  }
}

run "user_data_has_no_secret_values" {
  command = apply

  assert {
    condition     = !can(regex("(?i)password=|BEGIN .*PRIVATE|AKIA[0-9A-Z]{12}", aws_instance.this.user_data))
    error_message = "user_data must not embed secret material."
  }
  assert {
    condition     = can(regex("get-secret-value", aws_instance.this.user_data)) && can(regex("pulso-stack", aws_instance.this.user_data))
    error_message = "user_data installs the start script and unit."
  }
}

run "kill_switch_stops_instance" {
  command = apply
  variables {
    enabled = false
  }
  assert {
    condition     = aws_ec2_instance_state.this.state == "stopped"
    error_message = "enabled=false stops the instance."
  }
}

run "image_must_be_digest_pinned" {
  command = plan
  variables {
    images = {
      core = "x/agent-core:latest"
    }
  }
  expect_failures = [var.images]
}

run "workload_must_be_known" {
  command = plan
  variables {
    workload = "other"
  }
  expect_failures = [var.workload]
}

run "engine_proxy_listens_on_the_port_the_network_allows" {
  command = apply
  variables {
    workload = "engine"
  }
  assert {
    condition     = local.allowed_ports == ["8080:8080"]
    error_message = "The network module opens 8080 from CloudFront on the engine host, so the engine proxy publishes 8080."
  }
  assert {
    condition     = can(regex(":8080 \\{", local.caddyfile_text)) && !can(regex("(?m)^:80 \\{", local.caddyfile_text))
    error_message = "The engine Caddyfile listens on :8080."
  }
}

run "ssm_path_is_scoped_to_the_workload" {
  command = apply
  variables {
    workload   = "engine"
    ssm_prefix = "/pulso"
  }
  assert {
    condition     = can(regex("SSM_PREFIX=\"/pulso/engine\"", aws_instance.this.user_data))
    error_message = "The start script reads <ssm_prefix>/<workload>/<service>, which is exactly what the host IAM role may read."
  }
}

run "cloudwatch_log_group_is_under_the_name_prefix_the_role_allows" {
  command = apply
  variables {
    enable_cloudwatch_agent = true
    ssm_prefix              = "/pulso"
  }
  assert {
    condition     = can(regex("\"log_group_name\":\"/pulso-hk/docker\"", aws_instance.this.user_data))
    error_message = "Log group must be /<name_prefix>/docker, covered by the role's /<name>/* grant."
  }
}

run "exposes_instance_arn_for_the_cloudfront_vpc_origin" {
  command = apply
  assert {
    condition     = startswith(output.instance_arn, "arn:aws:ec2:")
    error_message = "instance_arn output is required by the edge module."
  }
}
# ---- free_plan: public IP, Postgres data volume, extra bundle files ----

run "public_ip_only_when_asked" {
  command = plan
  variables {
    workload            = "platform"
    associate_public_ip = true
  }

  # associate_public_ip_address is in ignore_changes (a stopped host has no public IP), which the mock provider cannot
  # report; tests/test_compute_inactive_host_contract.py asserts the wiring var.associate_public_ip instead.
  assert {
    condition     = length(aws_ebs_volume.db_protected) == 0 && length(aws_ebs_volume.db_unprotected) == 0
    error_message = "No database volume by default."
  }
}

run "no_database_volume_keeps_user_data_without_pgdata" {
  command = plan
  variables {
    workload = "engine"
  }

  assert {
    condition     = !strcontains(local.user_data, "pgdata") && !strcontains(local.env_text, "COMPOSE_FILE")
    error_message = "Hosts without a database volume are unchanged."
  }
}

run "database_volume_is_snapshotted_by_the_same_dlm_policy" {
  command = apply
  variables {
    workload           = "core"
    instance_type      = "m7i-flex.large"
    db_volume_size_gb  = 30
    extra_service_envs = ["db"]
    compose_files      = ["compose.yaml", "compose.postgres.yaml"]
    extra_bundle_files = { "compose.postgres.yaml" = "services: {}\n", "initdb/00_init.sh" = "#!/bin/bash\n" }
  }

  assert {
    condition     = length(aws_ebs_volume.db_protected) == 1 && aws_ebs_volume.db_protected[0].size == 30 && aws_ebs_volume.db_protected[0].encrypted
    error_message = "Dedicated encrypted EBS volume for Postgres."
  }
  assert {
    condition     = aws_ebs_volume.db_protected[0].tags["Snapshot"] == "pulso-hk-core-daily"
    error_message = "The DLM daily snapshot policy targets the database volume too."
  }
  assert {
    condition     = aws_volume_attachment.db[0].device_name == "/dev/sdg"
    error_message = "Database volume on /dev/sdg."
  }
  assert {
    condition     = strcontains(local.user_data, "/srv/pgdata") && strcontains(local.env_text, "COMPOSE_FILE=compose.yaml:compose.postgres.yaml")
    error_message = "user_data mounts the database volume and .env selects the Postgres compose override."
  }
  assert {
    condition     = contains(local.service_env_names, "db") && strcontains(local.prepare_script, "DB")
    error_message = "A db service env (db.env) is rendered from the DB__* secret keys."
  }
  assert {
    condition     = toset(keys(aws_s3_object.extra)) == toset(["compose.postgres.yaml", "initdb/00_init.sh"])
    error_message = "Extra bundle files are published next to compose.yaml."
  }
  assert {
    condition     = contains(local.allowed_ports, "5432:5432")
    error_message = "Postgres is published on the core host only when the db volume exists."
  }
  assert {
    condition     = local.instance_memory_mb == 8192
    error_message = "m7i-flex.large is 8 GB."
  }
}
