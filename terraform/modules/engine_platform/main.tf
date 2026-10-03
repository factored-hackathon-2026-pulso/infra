# Improvement-engine platform: the Pulso-owned workloads next to (not instead of) the existing single
# "improvement-engine" service. Opt-in (enabled = false plans zero resources).
#
# Shared foundations are inputs: VPC, private subnets, ECS cluster, RDS security group, KMS key, secret prefix.
# Declared here, per V3 §31 / plan annex D.5 and ADR 0003 flow matrix:
#   control-api  service  also serves the lab-broker audience (one listener, per-route-group audience), Cloud Map
#   worker       service  Rust worker: jobs, scheduler; launches the sandbox task through the ECS API
#   migrate      task     one-off engine migrations
#   sandbox-lab  task     launched by the worker; no secret, no database, VPC endpoints only
# Not declared on purpose: human-issuer (local-only test issuer, never remote), console hosting (edge is
# dependency_blocked), any load balancer or WAF, any model/provider egress (belongs to the Core/gateway runtime).

variable "enabled" {
  type    = bool
  default = false
}

variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "cluster_arn" { type = string }
variable "database_security_group_id" { type = string }

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input: no engine secret or role may reference it."
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "permissions_boundary" {
  type    = string
  default = ""
}

variable "s3_egress_enabled" {
  type        = bool
  default     = false
  description = "True when the shared S3 gateway endpoint exists. Plan-time bool because the prefix list id is unknown until apply."
}

variable "s3_prefix_list_id" {
  type        = string
  default     = ""
  description = "Managed prefix list of the S3 gateway endpoint (core_vpc_endpoints.s3_prefix_list_id)."
}

variable "secret_name_prefix" { type = string }
variable "log_retention_days" { type = number }

variable "image" {
  type        = string
  default     = ""
  description = "Engine image digest (repo@sha256:<64 hex>) for control-api, worker and migrate. Required when enabled."

  validation {
    condition     = !var.enabled || can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "When enabled, image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

variable "sandbox_image" {
  type        = string
  default     = ""
  description = "Sandbox-lab image digest (CLQ-43). Required when enabled."

  validation {
    condition     = !var.enabled || can(regex("@sha256:[0-9a-f]{64}$", var.sandbox_image))
    error_message = "When enabled, sandbox_image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

variable "control_api_port" {
  type    = number
  default = 8080
}

variable "control_api_desired_count" {
  type    = number
  default = 0
}

variable "worker_desired_count" {
  type    = number
  default = 0
}

variable "core_runtime_url" {
  type        = string
  default     = ""
  description = "Private URL of core-runtime (PULSO_CORE_BRIDGE_URL); name only, no credential."
}

variable "core_runtime_port" {
  type    = number
  default = 8000
}

variable "core_runtime_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Security groups of core-runtime (F1): control-api and worker may call them. The Core side adds the matching ingress using the security_group_ids output."
}

variable "core_callback_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Core runtime and exporter security groups allowed to call control-api (F2 callbacks, F3 observations)."
}

variable "service_discovery_namespace_id" {
  type        = string
  default     = ""
  description = "Shared Cloud Map private DNS namespace (reuse the one core or the platform already owns); empty creates <environment>.pulso.internal."
}

variable "alarm_actions" {
  type    = list(string)
  default = []
}

variable "tags" { type = map(string) }

locals {
  env    = var.tags["Environment"]
  prefix = "pulso-engine"

  # entry key -> owning workload; every entry is readable by exactly one execution role.
  secret_owner = {
    "db-control-api"          = "control-api"
    "db-worker"               = "worker"
    "db-migrate"              = "migrate"
    "service-key-control-api" = "control-api"
    "service-key-worker"      = "worker"
    "verifier-keys"           = "control-api"
  }
  entries = var.enabled ? local.secret_owner : {}

  arn = { for k, s in aws_secretsmanager_secret.this : k => s.arn }

  workloads = {
    "control-api" = {
      create_service = true
      port           = var.control_api_port
      cpu            = 512
      memory         = 1024
      desired_count  = var.control_api_desired_count
      image          = var.image
      command        = null
      environment    = { PULSO_CORE_BRIDGE_URL = var.core_runtime_url }
      secrets = {
        PULSO_DATABASE_DSN        = try(local.arn["db-control-api"], "")
        PULSO_SERVICE_SIGNING_KEY = try(local.arn["service-key-control-api"], "")
        PULSO_VERIFIER_KEYS       = try(local.arn["verifier-keys"], "")
      }
      secret_arns = [for k, o in local.entries : try(local.arn[k], "") if o == "control-api"]
    }
    "worker" = {
      create_service = true
      port           = null
      cpu            = 512
      memory         = 1024
      desired_count  = var.worker_desired_count
      image          = var.image
      command        = ["worker"]
      environment = {
        PULSO_CORE_BRIDGE_URL = var.core_runtime_url
        PULSO_SANDBOX_TASK    = "${local.prefix}-sandbox-lab"
      }
      secrets = {
        PULSO_DATABASE_DSN        = try(local.arn["db-worker"], "")
        PULSO_SERVICE_SIGNING_KEY = try(local.arn["service-key-worker"], "")
      }
      secret_arns = [for k, o in local.entries : try(local.arn[k], "") if o == "worker"]
    }
    "migrate" = {
      create_service = false
      port           = null
      cpu            = 256
      memory         = 512
      desired_count  = 0
      image          = var.image
      command        = ["migrate"]
      environment    = {}
      secrets        = { PULSO_DATABASE_DSN = try(local.arn["db-migrate"], "") }
      secret_arns    = [for k, o in local.entries : try(local.arn[k], "") if o == "migrate"]
    }
    "sandbox-lab" = {
      create_service = false
      port           = null
      cpu            = 512
      memory         = 1024
      desired_count  = 0
      image          = var.sandbox_image
      command        = null
      environment    = {}
      secrets        = {}
      secret_arns    = []
    }
  }
  active = { for k, v in local.workloads : k => v if var.enabled }

  # The worker launches the sandbox task through the ECS API (F8). iam:PassRole is not here: it goes through the
  # constrained pass_role_arns path of workload_iam.
  worker_task_statements = [
    {
      Effect    = "Allow"
      Action    = ["ecs:RunTask"]
      Resource  = [try(module.workload_sandbox[0].task_definition_arn, "*")]
      Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
    },
    {
      Effect    = "Allow"
      Action    = ["ecs:StopTask", "ecs:DescribeTasks"]
      Resource  = ["arn:aws:ecs:${var.aws_region}:*:task/${element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)}/*"]
      Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
    },
  ]
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.entries

  name                    = "${var.secret_name_prefix}/engine/${each.key}"
  kms_key_id              = var.kms_key_arn == "" ? null : var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = merge(var.tags, { Workload = "${local.prefix}-${each.value}" })
}

# The sandbox roles are a separate instance so the worker can be allowed to pass exactly those two roles.
module "iam_sandbox" {
  source = "../workload_iam"
  count  = var.enabled ? 1 : 0

  workload_name               = "${local.prefix}-sandbox-lab"
  aws_region                  = var.aws_region
  own_secret_arns             = []
  secret_kms_key_arns         = []
  task_statements             = []
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  permissions_boundary        = var.permissions_boundary
  tags                        = var.tags
}

module "iam" {
  source   = "../workload_iam"
  for_each = { for k, v in local.active : k => v if k != "sandbox-lab" }

  workload_name               = "${local.prefix}-${each.key}"
  aws_region                  = var.aws_region
  own_secret_arns             = each.value.secret_arns
  secret_kms_key_arns         = var.kms_key_arn == "" ? [] : [var.kms_key_arn]
  task_statements             = each.key == "worker" ? local.worker_task_statements : []
  pass_role_arns              = each.key == "worker" ? [module.iam_sandbox[0].task_role_arn, module.iam_sandbox[0].execution_role_arn] : []
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  permissions_boundary        = var.permissions_boundary
  tags                        = var.tags
}

resource "aws_cloudwatch_log_group" "engine" {
  for_each = local.active

  name              = "/pulso/${local.env}/${local.prefix}-${each.key}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_security_group" "engine" {
  for_each = local.active

  name_prefix = "${local.env}-${local.prefix}-${each.key}-"
  description = "Pulso engine ${each.key}: no public ingress; egress is explicit."
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# F4: engine database for control-api, worker and migrate only.
resource "aws_vpc_security_group_egress_rule" "to_database" {
  for_each = { for k, v in local.active : k => v if k != "sandbox-lab" }

  security_group_id            = aws_security_group.engine[each.key].id
  referenced_security_group_id = var.database_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL only"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_engine" {
  for_each = { for k, v in local.active : k => v if k != "sandbox-lab" }

  security_group_id            = var.database_security_group_id
  referenced_security_group_id = aws_security_group.engine[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${local.prefix}-${each.key}"
}

# F7: AWS APIs through VPC endpoints inside the VPC CIDR (core_vpc_endpoints / existing NAT is not used by rule).
resource "aws_vpc_security_group_egress_rule" "vpc_https" {
  for_each = { for k, v in local.active : k => v if k != "sandbox-lab" }

  security_group_id = aws_security_group.engine[each.key].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "VPC endpoints (AWS APIs)"
}

# F9: sandbox-lab reaches VPC endpoints only.
resource "aws_vpc_security_group_egress_rule" "sandbox_https_vpc" {
  count = var.enabled ? 1 : 0

  security_group_id = aws_security_group.engine["sandbox-lab"].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "VPC endpoints only"
}

# ECR layers are served from S3 through the gateway endpoint; the VPC-CIDR rule above does not cover that path, so
# every workload (sandbox-lab included) needs the prefix-list rule to start at all.
resource "aws_vpc_security_group_egress_rule" "s3_layers" {
  for_each = var.enabled && var.s3_egress_enabled ? toset(keys(local.active)) : toset([])

  security_group_id = aws_security_group.engine[each.key].id
  prefix_list_id    = var.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 gateway endpoint (ECR image layers)"
}

# F1: control-api and worker call core-runtime (invoke/read/alias/dry-run/version, executor path).
resource "aws_vpc_security_group_egress_rule" "to_core_runtime" {
  for_each = { for p in setproduct(["control-api", "worker"], var.core_runtime_security_group_ids) : "${p[0]}|${p[1]}" => p if var.enabled }

  security_group_id            = aws_security_group.engine[each.value[0]].id
  referenced_security_group_id = each.value[1]
  ip_protocol                  = "tcp"
  from_port                    = var.core_runtime_port
  to_port                      = var.core_runtime_port
  description                  = "${each.value[0]} to core-runtime"
}

# F2/F3: Core callbacks and exporter observations reach control-api.
resource "aws_vpc_security_group_ingress_rule" "control_api_from_core" {
  count = var.enabled ? length(var.core_callback_security_group_ids) : 0

  security_group_id            = aws_security_group.engine["control-api"].id
  referenced_security_group_id = var.core_callback_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = var.control_api_port
  to_port                      = var.control_api_port
  description                  = "Core callbacks and exporter"
}

# Private DNS: control-api.<env>.pulso.internal; no ALB, no WAF.
resource "aws_service_discovery_private_dns_namespace" "this" {
  count = var.enabled && var.service_discovery_namespace_id == "" ? 1 : 0

  name = "${local.env}.pulso.internal"
  vpc  = var.vpc_id
  tags = var.tags
}

resource "aws_service_discovery_service" "control_api" {
  count = var.enabled ? 1 : 0

  name = "control-api"
  dns_config {
    namespace_id   = var.service_discovery_namespace_id == "" ? aws_service_discovery_private_dns_namespace.this[0].id : var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  tags = var.tags
}

module "workload" {
  source   = "../workload"
  for_each = { for k, v in local.active : k => v if k != "sandbox-lab" }

  name                        = "${local.prefix}-${each.key}"
  image                       = each.value.image
  command                     = each.value.command
  cluster_arn                 = var.cluster_arn
  subnet_ids                  = var.private_subnet_ids
  security_group_ids          = [aws_security_group.engine[each.key].id]
  task_role_arn               = module.iam[each.key].task_role_arn
  execution_role_arn          = module.iam[each.key].execution_role_arn
  aws_region                  = var.aws_region
  log_group_name              = aws_cloudwatch_log_group.engine[each.key].name
  port                        = each.value.port
  cpu                         = each.value.cpu
  memory                      = each.value.memory
  desired_count               = each.value.desired_count
  create_service              = each.value.create_service
  environment                 = each.value.environment
  secrets                     = each.value.secrets
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  service_registry_arn        = each.key == "control-api" ? aws_service_discovery_service.control_api[0].arn : null
  tags                        = merge(var.tags, { Workload = "${local.prefix}-${each.key}" })
}

# Separate instance (see iam_sandbox): the worker's ecs:RunTask statement references this task definition.
module "workload_sandbox" {
  source = "../workload"
  count  = var.enabled ? 1 : 0

  name                        = "${local.prefix}-sandbox-lab"
  image                       = var.sandbox_image
  cluster_arn                 = var.cluster_arn
  subnet_ids                  = var.private_subnet_ids
  security_group_ids          = [aws_security_group.engine["sandbox-lab"].id]
  task_role_arn               = module.iam_sandbox[0].task_role_arn
  execution_role_arn          = module.iam_sandbox[0].execution_role_arn
  aws_region                  = var.aws_region
  log_group_name              = aws_cloudwatch_log_group.engine["sandbox-lab"].name
  port                        = null
  cpu                         = local.workloads["sandbox-lab"].cpu
  memory                      = local.workloads["sandbox-lab"].memory
  desired_count               = 0
  create_service              = false
  environment                 = {}
  secrets                     = {}
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  tags                        = merge(var.tags, { Workload = "${local.prefix}-sandbox-lab" })
}

# Running-task alarms only for services that are expected to run (a zero-task posture must not page anyone).
resource "aws_cloudwatch_metric_alarm" "running_tasks" {
  for_each = var.enabled ? { for k, n in { "control-api" = var.control_api_desired_count, "worker" = var.worker_desired_count } : k => n if n > 0 } : {}

  alarm_name          = "${local.env}-${local.prefix}-${each.key}-running-tasks"
  alarm_description   = "${local.prefix}-${each.key} has fewer running tasks than desired"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = each.value
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  dimensions = {
    ClusterName = element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)
    ServiceName = "${local.prefix}-${each.key}"
  }
  tags = var.tags
}

output "enabled" { value = var.enabled }

output "security_group_ids" {
  value       = { for k, sg in aws_security_group.engine : k => sg.id }
  description = "Feed control-api to the Core side as core_callback_security_group_ids; worker and control-api as its consumer_security_group_ids."
}

output "task_definition_arns" {
  value = merge({ for k, w in module.workload : k => w.task_definition_arn }, { for w in module.workload_sandbox : "sandbox-lab" => w.task_definition_arn })
}

output "control_api_dns_name" {
  value = var.enabled ? "control-api.${local.env}.pulso.internal" : null
}

output "service_discovery_namespace_id" {
  value       = !var.enabled ? "" : var.service_discovery_namespace_id == "" ? aws_service_discovery_private_dns_namespace.this[0].id : var.service_discovery_namespace_id
  description = "Shared Cloud Map namespace; pass it on instead of creating a second one."
}

output "secret_names" {
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.name }
  description = "Entry names only; values are set out of band."
}
