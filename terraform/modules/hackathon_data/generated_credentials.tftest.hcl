mock_provider "aws" {}
mock_provider "random" {}
mock_provider "tls" {}

# RFC 8032 section 7.1 test vector 1 (a published test key, not a secret), as the PEM the tls provider returns for ED25519:
# seed 9d61b19d...7f60 -> public key d75a9801...511a (base64url 11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo).
override_resource {
  target = tls_private_key.agent
  values = {
    private_key_pem = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g\n-----END PRIVATE KEY-----\n"
    public_key_pem  = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=\n-----END PUBLIC KEY-----\n"
  }
}

variables {
  name_prefix            = "pulso-hk"
  region                 = "us-east-1"
  vpc_id                 = "vpc-0123456789abcdef0"
  db_subnet_ids          = ["subnet-aaaa1111", "subnet-bbbb2222"]
  sg_db_id               = "sg-0123456789abcdef0"
  agent_services_enabled = true
}

run "gateway_tokens_are_generated_and_shared_with_their_consumers" {
  command = apply

  assert {
    condition     = length([for k, v in local.generated_secrets : k if startswith(k, "GATEWAY__GATEWAY_TOKEN_")]) == 4
    error_message = "One gateway token per consumer."
  }
  assert {
    condition     = local.generated_secrets["GATEWAY__GATEWAY_TOKEN_ENGINE"] == local.generated_secrets["PULSO__PULSO_LLM_GATEWAY_KEY"]
    error_message = "The engine presents the token the gateway issues to ENGINE."
  }
  assert {
    condition     = local.generated_secrets["GATEWAY__GATEWAY_TOKEN_AGENT_CORE"] == local.generated_secrets["CORE__AGENTCORE_LLM_GATEWAY_TOKEN"]
    error_message = "agent-core presents the token the gateway issues to AGENT_CORE."
  }
  assert {
    condition     = local.generated_secrets["AGENT__AGENTCORE_GRANTS_TOKEN"] == local.generated_secrets["SUPPORT__CC_INTERNAL_SERVICE_TOKEN"]
    error_message = "grant_active bearer and the platform internal token are one value."
  }
  assert {
    condition     = length(distinct([for k, v in local.generated_secrets : v if startswith(k, "GATEWAY__GATEWAY_TOKEN_")])) == 4
    error_message = "Consumer tokens must be distinct."
  }
}

run "ed25519_keys_are_derived_in_the_agent_core_formats" {
  command = apply

  assert {
    condition     = local.agent_seeds["engine"] == "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A" && local.agent_seeds_hex["engine"] == "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" && local.generated_secrets["PULSO__PULSO_SERVICE_SEED_HEX"] == local.agent_seeds_hex["engine"]
    error_message = "The seed must be the 32 raw bytes of the PKCS#8 key, base64url without padding."
  }
  assert {
    condition     = output.engine_core_public_key == "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
    error_message = "The public key must be the 32 raw bytes of the SPKI key, base64url without padding."
  }
  assert {
    condition     = output.engine_core_kid == "pulso-engine-hk1"
    error_message = "Engine kid pulso-engine-<suffix>."
  }
  assert {
    condition     = jsondecode(local.generated_secrets["FILES__AGENT__IDENTITY_KEYS"]).principal_keys["pulso-engine-hk1"] == "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" && contains(keys(jsondecode(local.generated_secrets["FILES__AGENT__IDENTITY_KEYS"]).delegation_keys), "cc-grant-hk1")
    error_message = "identity-keys: platform principal and delegation keys plus the engine principal key."
  }
  assert {
    condition     = join(",", sort(keys(jsondecode(nonsensitive(local.generated_secrets["FILES__AGENT__STAFF_KEYS"])).principal_keys))) == "cc-staff-hk1,pulso-engine-hk1" && !contains(keys(jsondecode(nonsensitive(local.generated_secrets["FILES__AGENT__STAFF_KEYS"]))), "delegation_keys")
    error_message = "staff-keys: platform staff key plus the engine key, no delegation keys."
  }
  assert {
    condition     = join(",", sort(keys(jsondecode(nonsensitive(local.generated_secrets["FILES__SUPPORT__AGENT_PRIVATE_KEYS"]))))) == "delegation,principal,staff" && jsondecode(nonsensitive(local.generated_secrets["FILES__SUPPORT__AGENT_PRIVATE_KEYS"])).staff.kid == "cc-staff-hk1"
    error_message = "The platform private document has principal, delegation and staff seeds."
  }
}

run "secret_holds_generated_values_and_keeps_other_placeholders" {
  command = apply

  assert {
    condition     = alltrue([for k in keys(local.generated_secrets) : contains(keys(jsondecode(aws_secretsmanager_secret_version.this.secret_string)), k)])
    error_message = "Every generated key is in the secret."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.this.secret_string)["GATEWAY__OPENROUTER_API_KEY"] == "CHANGE_ME" && jsondecode(aws_secretsmanager_secret_version.this.secret_string)["CORE__AGENTCORE_REGISTRY_DSN"] == "CHANGE_ME"
    error_message = "Provider keys, DSNs and the JEV key stay out-of-band placeholders."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.this.secret_string)["AGENT__AGENTCORE_LLM_GATEWAY_TOKEN"] == jsondecode(aws_secretsmanager_secret_version.this.secret_string)["GATEWAY__GATEWAY_TOKEN_AGENT_SERVE"] && jsondecode(aws_secretsmanager_secret_version.this.secret_string)["TOOLS__TOOL_SERVICE_TOKENS"] == format("agent-core:%s", jsondecode(aws_secretsmanager_secret_version.this.secret_string)["AGENT__AGENTCORE_TOOL_SERVICE_TOKEN"])
    error_message = "agent-core serve presents the token the gateway issues to AGENT_SERVE and the one tool-service accepts for agent-core."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.this.secret_string)["AGENT__AGENTCORE_REGISTRY_DSN"] == "CHANGE_ME" && jsondecode(aws_secretsmanager_secret_version.this.secret_string)["FILES__AGENT__FIELD_GRANTS"] == "CHANGE_ME"
    error_message = "DSNs and data-governance files stay out of band."
  }
}

run "gateway_config_is_derived_not_a_placeholder" {
  command = apply

  assert {
    condition     = jsondecode(aws_ssm_parameter.derived["core/gateway/GATEWAY_CONSUMERS"].value)["engine"].token_env == "GATEWAY_TOKEN_ENGINE" && jsondecode(aws_ssm_parameter.derived["core/gateway/GATEWAY_CONSUMERS"].value)["agent-core"].token_env == "GATEWAY_TOKEN_AGENT_CORE"
    error_message = "GATEWAY_CONSUMERS names the token variable of each consumer."
  }
  assert {
    condition     = jsondecode(aws_ssm_parameter.derived["core/gateway/LLM_ENDPOINTS"].value).openrouter.api_key_env == "OPENROUTER_API_KEY" && length(keys(jsondecode(aws_ssm_parameter.derived["core/gateway/LLM_ENDPOINTS"].value))) == 1
    error_message = "The only endpoint is the openrouter alias."
  }
  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_SERVICE_KID"].value == "pulso-engine-hk1" && aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY"].value == "enabled"
    error_message = "Engine config: kid and gateway switch."
  }
}

run "agent_keys_only_with_the_flag" {
  command = apply
  variables {
    agent_services_enabled = false
  }

  assert {
    condition     = !contains(keys(local.generated_secrets), "FILES__AGENT__STAFF_KEYS") && contains(keys(local.generated_secrets), "PULSO__PULSO_SERVICE_SEED_HEX")
    error_message = "Agent-services keys exist only with agent_services_enabled; the engine credentials always."
  }
}

run "gateway_consumers_must_include_agent_core_and_engine" {
  command = plan
  variables {
    gateway_consumers = ["SUPPORT_PLATFORM"]
  }
  expect_failures = [var.gateway_consumers]
}
