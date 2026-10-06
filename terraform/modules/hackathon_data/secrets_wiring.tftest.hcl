mock_provider "aws" {}
mock_provider "random" {}
mock_provider "tls" {}

# Separate file: the secret version ignores later secret_string changes, so each secret shape needs its own file.
# docs/secrets-wiring.md: with every flag on, the ONLY CHANGE_ME values left are the external provider keys.

# mock_provider fills computed strings with short random text; fix the byte resources so the formats can be asserted.
override_resource {
  target = random_bytes.totp
  values = { base64 = "+/++AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxw=" }
}

override_resource {
  target = random_bytes.pseudonym
  values = { hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" }
}

# RFC 8032 section 7.1 test vector 1 (a published test key, not a secret), as the PEM the tls provider returns for ED25519:
# seed 9d61b19d...7f60 -> public key d75a9801...511a (base64url 11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo).
override_resource {
  target = tls_private_key.agent
  values = {
    private_key_pem = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g\n-----END PRIVATE KEY-----\n"
    public_key_pem  = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=\n-----END PUBLIC KEY-----\n"
  }
}

# mock_provider fills computed strings with short random text; the session secret must be long enough to assert its length.
override_resource {
  target = random_password.session_secret
  values = { result = "Ab3dEf6hIj9lMn2pQr5tUv8xYz1BcDeF0gHiJkLm" }
}

variables {
  name_prefix               = "pulso-hk"
  region                    = "us-east-1"
  vpc_id                    = "vpc-0123456789abcdef0"
  database_mode             = "container"
  db_subnet_ids             = []
  sg_db_id                  = null
  agent_services_enabled    = true
  platform_database_enabled = true
  auto_loader_enabled       = true
  otlp_forwarder_enabled    = true
  private_zone_name         = "pulso.internal"
}

run "only_provider_keys_stay_placeholders" {
  command = apply

  assert {
    condition = toset([for k, v in nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string)) : k if v == "CHANGE_ME" || v == ""]) == toset([
      "GATEWAY__OPENROUTER_API_KEY", "GATEWAY__JEV_API_KEY", "AGENT__AGENTCORE_JEV_API_KEY",
      "LANGFUSE__LANGFUSE_PUBLIC_KEY", "LANGFUSE__LANGFUSE_SECRET_KEY",
    ])
    error_message = "Only OpenRouter, JEV and Langfuse keys may still hold CHANGE_ME."
  }
  assert {
    condition     = length([for k, v in aws_ssm_parameter.placeholder : k]) == 0 && alltrue([for k, v in aws_ssm_parameter.derived : v.value != "CHANGE_ME"])
    error_message = "No SSM parameter is a CHANGE_ME placeholder with agent services on."
  }
}

run "dsns_are_assembled_from_the_generated_passwords_and_hosts" {
  command = apply

  assert {
    condition     = startswith(local.wired_secrets["AGENT__AGENTCORE_REGISTRY_DSN"], "postgresql://agent_app:") && endswith(local.wired_secrets["AGENT__AGENTCORE_REGISTRY_DSN"], "@postgres:5432/agent_runtime?sslmode=disable")
    error_message = "agent-core runs on the core host: the compose service name, the agent_app role, database agent_runtime."
  }
  assert {
    condition     = endswith(local.wired_secrets["AGENT__AGENTCORE_MIGRATE_EVAL_DSN"], "@postgres:5432/agent_eval?sslmode=disable") && startswith(local.wired_secrets["AGENT__AGENTCORE_MIGRATE_EVAL_DSN"], "postgresql://agent_owner:")
    error_message = "The migrate DSN uses the owner role."
  }
  assert {
    condition     = startswith(local.wired_secrets["SUPPORT__CC_DATABASE_URL"], "postgresql://platform_app:") && endswith(local.wired_secrets["SUPPORT__CC_DATABASE_URL"], "@core.pulso.internal:5432/platform?sslmode=disable")
    error_message = "The platform uses the psycopg 3 postgresql:// scheme (docs/secrets-wiring.md; no +asyncpg) and reaches Postgres as core.<zone>."
  }
  assert {
    condition     = startswith(local.wired_secrets["PULSO__PULSO_PG_PRODUCT_DSN"], "postgresql://platform_exporter_ro:") && startswith(local.wired_secrets["PULSO__PULSO_DATABASE_URL"], "postgresql://pulso_master:") && endswith(local.wired_secrets["PULSO__PULSO_DATABASE_URL"], "@core.pulso.internal:5432/pulso?sslmode=disable")
    error_message = "The engine reads the event log as the read-only exporter and migrates as the master."
  }
  assert {
    condition     = strcontains(local.wired_secrets["AGENT__AGENTCORE_REGISTRY_DSN"], local.wired_secrets["DB__DB_PASSWORD_AGENT_APP"]) && strcontains(local.wired_secrets["PULSO__PULSO_DATABASE_URL"], random_password.db_master.result)
    error_message = "A DSN embeds the generated password of its role."
  }
}

run "passwords_keys_and_files_are_wired" {
  command = apply

  assert {
    condition     = length(distinct([for r in local.db_password_roles : local.db_pw[r]])) == length(local.db_password_roles)
    error_message = "Every role has its own password."
  }
  assert {
    condition     = length(local.pseudonym_key) == 64 && can(regex("^[0-9a-f]{64}$", local.pseudonym_key))
    error_message = "The pseudonymisation key is 64 hex characters."
  }
  assert {
    condition     = !strcontains(local.totp_secret_key, "+") && !strcontains(local.totp_secret_key, "/") && length(local.totp_secret_key) == 44
    error_message = "CC_TOTP_SECRET_KEY is a urlsafe base64 Fernet key (44 characters)."
  }
  assert {
    condition     = length(random_password.session_secret.result) >= 32 && local.wired_secrets["SUPPORT__CC_SESSION_SECRET"] == random_password.session_secret.result
    error_message = "The session secret is at least 32 characters."
  }
  assert {
    condition     = length(jsondecode(local.wired_secrets["FILES__AGENT__FIELD_GRANTS"])) >= 1 && alltrue([for g in jsondecode(local.wired_secrets["FILES__AGENT__FIELD_GRANTS"]) : length(g) == 2])
    error_message = "Field grants are [field, purpose] pairs."
  }
  assert {
    condition     = can(jsondecode(local.wired_secrets["FILES__AGENT__FX_RATES"])) && can(jsondecode(local.wired_secrets["FILES__AGENT__FIELD_OVERLAY"])) && jsondecode(local.wired_secrets["FILES__SUPPORT__BANK_CUSTOMER_LINKS"]) == {}
    error_message = "FX, overlay and customer links are valid JSON documents (links start empty)."
  }
  assert {
    condition     = !contains(keys(local.wired_secrets), "AGENT__AGENTCORE_ALLOW_DOUBLES") && !contains(keys(local.generated_secrets), "PULSO__PULSO_REGISTRY_TOKEN") && !anytrue([for k in keys(local.generated_secrets) : strcontains(k, "ALLOW_DOUBLES") || strcontains(k, "REGISTRY_TOKEN")])
    error_message = "The doubles switch and the static registry token are never generated."
  }
}
