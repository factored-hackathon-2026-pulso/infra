# Regression for DR-86: every log group name in this root must have one owner.
mock_provider "aws" {}

variables {
  aws_region                      = "us-east-1"
  vpc_cidr                        = "10.20.0.0/16"
  public_subnet_cidrs             = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs            = ["10.20.10.0/24", "10.20.11.0/24"]
  availability_zones              = ["us-east-1a", "us-east-1b"]
  nat_strategy                    = "single"
  least_privilege_policy_boundary = ""
  image_digest                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/improvement-engine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  artifact_bucket_name            = "pulso-test-artifacts"
  source_bucket_name              = "pulso-test-sources"
  database_engine                 = "postgres"
  secret_name_prefix              = "pulso/test"
  kms_key_arn                     = ""
  runtime_database_secret_arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-db-test"
  desired_count                   = 0
  database_instance_class         = "db.t4g.micro"
  database_backup_retention_days  = 7
  database_deletion_protection    = false
  database_skip_final_snapshot    = true
  database_multi_az               = false
  log_retention_days              = 14
  alarm_actions                   = []
}

run "log_group_has_a_single_owner" {
  command = plan

  # Compute only consumes the name; observability is the sole owner. Before the
  # fix both modules declared "/pulso/<env>/improvement-engine" and AWS would
  # reject the second create.
  assert {
    condition     = module.compute.log_group_name == module.observability.log_group_name
    error_message = "Compute must write to the log group owned by observability, not declare its own."
  }

  assert {
    condition     = module.observability.log_group_name == "/pulso/${local.tags["Environment"]}/improvement-engine"
    error_message = "Log group name must stay /pulso/<env>/improvement-engine."
  }
}
