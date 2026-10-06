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

# Models of the `pulso loop` roles (improvement-engine reasoning/live.rs): scout flash, builder flash escalating to pro, verifier pro.
# Non-secret, derived SSM values: they update in place on apply and are overridable by variable.

run "model_parameters_default_to_the_policy" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY_MODEL"].value == "xiaomi/mimo-v2.6-flash"
    error_message = "The scout model defaults to mimo flash."
  }
  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY_VERIFIER_MODEL"].value == "xiaomi/mimo-v2.6-pro"
    error_message = "The verifier model defaults to mimo pro."
  }
  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY_BUILDER_MODEL"].value == "xiaomi/mimo-v2.6-flash"
    error_message = "The builder primary model defaults to mimo flash."
  }
  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY_BUILDER_ESCALATION_MODEL"].value == "xiaomi/mimo-v2.6-pro"
    error_message = "The builder escalation model defaults to mimo pro."
  }
  assert {
    condition     = !contains(keys(aws_ssm_parameter.placeholder), "engine/pulso/PULSO_LLM_GATEWAY_MODEL")
    error_message = "Model ids are derived values (update in place), not ignore_changes placeholders."
  }
}

run "model_parameters_are_overridable" {
  command = plan
  variables {
    engine_llm_models = {
      scout              = "z-ai/glm-5.3-flash"
      verifier           = "xiaomi/mimo-v2.6-pro"
      builder            = "xiaomi/mimo-v2.6-pro"
      builder_escalation = "xiaomi/mimo-v2.6-pro"
    }
  }

  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_LLM_GATEWAY_MODEL"].value == "z-ai/glm-5.3-flash"
    error_message = "engine_llm_models must reach SSM."
  }
}

run "model_ids_must_not_be_blank" {
  command = plan
  variables {
    engine_llm_models = {
      scout              = ""
      verifier           = "xiaomi/mimo-v2.6-pro"
      builder            = "xiaomi/mimo-v2.6-flash"
      builder_escalation = "xiaomi/mimo-v2.6-pro"
    }
  }
  expect_failures = [var.engine_llm_models]
}
