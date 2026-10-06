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

# The engine refuses to start when PULSO_DATA_MODE and PULSO_SOURCE_ADAPTER disagree (improvement-engine config.rs):
# dataset allows stub|dataset-*, platform allows stub|product-*. The mode is a derived value, never an out-of-band one.

run "data_mode_defaults_to_dataset" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_DATA_MODE"].value == "dataset" && output.engine_data_mode == "dataset"
    error_message = "Without a platform event log the engine keeps the bank dataset mode."
  }
  assert {
    condition     = !contains(keys(aws_ssm_parameter.placeholder), "engine/pulso/PULSO_DATA_MODE")
    error_message = "The data mode is derived, not an ignore_changes placeholder: it must update in place on apply."
  }
}

run "data_mode_platform_is_written_to_ssm" {
  command = plan
  variables {
    engine_data_mode = "platform"
  }

  assert {
    condition     = aws_ssm_parameter.derived["engine/pulso/PULSO_DATA_MODE"].value == "platform"
    error_message = "engine_data_mode=platform must reach SSM so product-postgres is a valid adapter."
  }
}

run "data_mode_rejects_unknown_values" {
  command = plan
  variables {
    engine_data_mode = "product"
  }
  expect_failures = [var.engine_data_mode]
}
