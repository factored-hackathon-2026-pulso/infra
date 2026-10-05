mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix   = "pulso-hk"
  region        = "us-east-1"
  vpc_id        = "vpc-0123456789abcdef0"
  database_mode = "container"
  db_subnet_ids = []
  sg_db_id      = null
}

# Separate file: test runs of one file share state and the secret version ignores later secret_string changes.

run "restricted_publication_is_pii_even_without_agent_services" {
  command = plan
  variables {
    loader_role_arns           = ["arn:aws:iam::111111111111:role/loader"]
    break_glass_principal_arns = ["arn:aws:iam::111111111111:role/admin"]
  }

  assert {
    condition = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyRestrictedReadToOthers" &&
      anytrue([for r in s.Resource : endswith(r, "/lake/publish/*/gold_restricted.duckdb")]) &&
      anytrue([for r in s.Resource : endswith(r, "/lake/gold_restricted/*")]) &&
      contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/loader") &&
    contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/admin")]) == 1
    error_message = "gold_restricted (PII in the clear, published by data-pipeline) is readable only by the loader, break-glass and the restricted readers."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Effect == "Allow"]) == 0
    error_message = "The bucket policy stays deny-only."
  }
}

run "restricted_readers_are_exempt_only_from_the_restricted_deny" {
  command = plan
  variables {
    restricted_reader_role_arns = ["arn:aws:iam::111111111111:role/core-host"]
  }

  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyRestrictedReadToOthers" && contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/core-host")]) == 1
    error_message = "The core host (tool-service) may read the restricted publication."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyPiiReadToOthers" && contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/core-host")]) == 0
    error_message = "A restricted reader never reads landing/ or lake/bronze/."
  }
}

run "agent_services_seed_their_keys" {
  command = apply
  variables {
    agent_services_enabled = true
  }

  assert {
    condition = alltrue([for k in [
      "AGENT__AGENTCORE_REGISTRY_DSN", "AGENT__AGENTCORE_EVAL_DSN", "AGENT__AGENTCORE_MIGRATE_DSN", "AGENT__AGENTCORE_MIGRATE_EVAL_DSN",
      "AGENT__AGENTCORE_LLM_GATEWAY_TOKEN", "AGENT__AGENTCORE_JEV_API_KEY", "AGENT__AGENTCORE_KEYS_FINGERPRINT",
      "AGENT__AGENTCORE_KEYS_TOKEN_MAP", "AGENT__AGENTCORE_TOOL_SERVICE_TOKEN", "AGENT__AGENTCORE_GRANTS_TOKEN",
      "TOOLS__TOOL_SERVICE_TOKENS", "GATEWAY__GATEWAY_TOKEN_AGENT_SERVE", "SUPPORT__CC_INTERNAL_SERVICE_TOKEN",
      "FILES__AGENT__IDENTITY_KEYS", "FILES__AGENT__STAFF_KEYS", "FILES__AGENT__FIELD_GRANTS", "FILES__AGENT__FIELD_OVERLAY",
      "FILES__SUPPORT__AGENT_PRIVATE_KEYS", "FILES__SUPPORT__BANK_CUSTOMER_LINKS",
      "DB__DB_PASSWORD_AGENT_OWNER", "DB__DB_PASSWORD_AGENT_APP",
    ] : contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), k)])
    error_message = "agent-core serve, tool-service, the gateway consumer, the platform side and the agent databases get their placeholder keys."
  }
  assert {
    condition     = nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))["AGENT__AGENTCORE_JEV_API_KEY"] == "CHANGE_ME"
    error_message = "Values are set out of band; Terraform seeds CHANGE_ME."
  }
  assert {
    condition = alltrue([for k in keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))) :
    can(regex("^(CORE|GATEWAY|SUPPORT|PULSO|COMMON|AGENT|TOOLS|DB)__[A-Z0-9_]+$", k)) || can(regex("^FILES__(AGENT|SUPPORT)__[A-Z0-9_]+$", k)) || k == "RDS_MASTER_PASSWORD"])
    error_message = "Every key is <SERVICE>__<VAR> or FILES__<SERVICE>__<NAME>."
  }
}
