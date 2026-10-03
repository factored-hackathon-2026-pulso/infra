# Core bridge runtime, Core exporter and platform exporter: the three Pulso-owned services that sit between the
# improvement engine and Core / the product platform (V3 section 31.11, PL-L5 of section 32.4). Opt-in
# (enabled = false plans zero resources).
#
# Shared foundations are inputs: VPC, private subnets, ECS cluster, KMS key, secret prefix, the Cloud Map namespace,
# the S3 prefix list, the control-api security group and the Core / platform database security groups. Nothing here
# creates a VPC, cluster, database, namespace, load balancer, WAF or image repository.
#
# Declared here:
#   core-runtime       service  our composed pulso-core-runtime image (command "runtime"), Cloud Map core-runtime
#   core-exporter      service  same image (command "exporter"), reads Core with the read-only role
#   platform-exporter  service  reads the product platform database with a read-only credential
#
# Not declared on purpose: core-migrate and the sweep (Core workload slice, ADR 0003), the LLM gateway (ADR 0004),
# Core's own core/* secret entries (consumed by ARN, never created), and any database, role or grant (human
# bootstrap, ADR 0003 item 2).
#
# Key delivery follows ADR 0009 of core-bridge: secrets are injected as environment variables, the image entrypoint
# writes them into /run/pulso-keys and unsets them. Fargate has no tmpfs, so the path is task-scoped ephemeral
# storage under a read-only root filesystem (workload.ephemeral_volumes). The image must create /run/pulso-keys and
# the state directories owned by its app uid so the volume inherits that ownership.

variable "enabled" {
  type    = bool
  default = false
}

variable "core_runtime_enabled" {
  type    = bool
  default = true
}

variable "core_exporter_enabled" {
  type    = bool
  default = true
}

variable "platform_exporter_enabled" {
  type    = bool
  default = true
}

variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "cluster_arn" { type = string }

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input: no secret or role here may reference it."
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
  description = "True when the shared S3 gateway endpoint exists (plan-time bool: the prefix list id is unknown until apply)."
}

variable "s3_prefix_list_id" {
  type        = string
  default     = ""
  description = "Managed prefix list of the S3 gateway endpoint (core_vpc_endpoints.s3_prefix_list_id): ECR layer pulls."
}

variable "secret_name_prefix" { type = string }
variable "log_retention_days" { type = number }

variable "core_image" {
  type        = string
  default     = ""
  description = "pulso-core-runtime digest (repo@sha256:<64 hex>) from <env>/pulso-core; one digest serves the runtime and exporter roles."

  validation {
    condition     = !(var.enabled && (var.core_runtime_enabled || var.core_exporter_enabled)) || can(regex("@sha256:[0-9a-f]{64}$", var.core_image))
    error_message = "When the runtime or the Core exporter is enabled, core_image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

variable "platform_exporter_image" {
  type        = string
  default     = ""
  description = "platform-exporter digest (repo@sha256:<64 hex>)."

  validation {
    condition     = !(var.enabled && var.platform_exporter_enabled) || can(regex("@sha256:[0-9a-f]{64}$", var.platform_exporter_image))
    error_message = "When the platform exporter is enabled, platform_exporter_image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

variable "core_runtime_desired_count" {
  type    = number
  default = 0
}

variable "core_exporter_desired_count" {
  type    = number
  default = 0
}

variable "platform_exporter_desired_count" {
  type    = number
  default = 0
}

variable "core_runtime_port" {
  type    = number
  default = 8000
}

variable "service_discovery_namespace_id" {
  type        = string
  default     = ""
  description = "Shared Cloud Map private DNS namespace <env>.pulso.internal (engine_platform output service_discovery_namespace_id). Required for core-runtime; never created here."
}

variable "control_api_security_group_id" {
  type        = string
  default     = ""
  description = "engine_platform security group of control-api: F2 (callbacks) and F3 (observations) are opened toward it."
}

variable "control_api_dns_name" {
  type        = string
  default     = ""
  description = "engine_platform output control_api_dns_name."
}

variable "control_api_port" {
  type    = number
  default = 8080
}

variable "engine_caller_security_group_ids" {
  type        = map(string)
  default     = {}
  description = "Engine callers of core-runtime (F1), keyed by a static name (control-api, worker) -> security group id. This module opens both ends, so leave engine_platform core_runtime_security_group_ids empty."
}

variable "core_database_security_group_id" {
  type        = string
  default     = ""
  description = "Security group of the Core database (or its rds_proxy): F5 for the runtime and the Core exporter."
}

variable "platform_database_security_group_id" {
  type        = string
  default     = ""
  description = "Security group of the product platform database the platform exporter reads."
}

variable "manage_core_database_ingress" {
  type        = bool
  default     = false
  description = "Add the ingress rule on the Core database security group. Off by default: that group belongs to the Core workload slice."
}

variable "manage_platform_database_ingress" {
  type        = bool
  default     = false
  description = "Add the ingress rule on the platform database security group. Off by default: that group belongs to the platform."
}

variable "database_port" {
  type    = number
  default = 5432
}

variable "llm_gateway_url" {
  type        = string
  default     = ""
  description = "Private URL of the LLM gateway (ADR 0004); name only. With it set, core_secret_arns must carry llm_gateway_token."
}

variable "llm_gateway_security_group_id" {
  type        = string
  default     = ""
  description = "Gateway security group; the runtime gets egress to it. The gateway side admits this module's core-runtime group (output security_group_ids)."
}

variable "llm_gateway_port" {
  type    = number
  default = 8080
}

variable "core_secret_arns" {
  type        = map(string)
  default     = {}
  description = "Secrets owned by the Core workload slice (ADR 0003 layout), by ARN: db_app ({registry_dsn, eval_dsn}), db_exporter, identity_keys, staff_keys, bridge_service_key, llm_gateway_token."

  validation {
    condition     = alltrue([for k in keys(var.core_secret_arns) : contains(["db_app", "db_exporter", "identity_keys", "staff_keys", "bridge_service_key", "llm_gateway_token"], k)])
    error_message = "core_secret_arns accepts only db_app, db_exporter, identity_keys, staff_keys, bridge_service_key and llm_gateway_token."
  }
  validation {
    condition     = alltrue([for a in values(var.core_secret_arns) : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[^*?:]+$", a)) && !startswith(a, var.rds_master_secret_arn_guard)])
    error_message = "core_secret_arns values must be concrete Secrets Manager ARNs (no wildcard, no JSON-key suffix) and never the RDS master secret."
  }
}

variable "tenant_id" {
  type    = string
  default = ""
}

variable "core_instance" {
  type    = string
  default = ""
}

variable "exporter_binding_ref" {
  type    = string
  default = ""
}

variable "expected_runtime_db" {
  type    = string
  default = ""
}

variable "expected_eval_db" {
  type    = string
  default = ""
}

variable "platform_instance" {
  type    = string
  default = ""
}

variable "platform_binding_ref" {
  type    = string
  default = ""
}

variable "runtime_extra_environment" {
  type        = map(string)
  default     = {}
  description = "Extra plain settings for core-runtime (PULSO_EVAL_BUDGETS_JSON, PULSO_LLM_*, limits). No secrets; the keys set by this module win."
}

variable "core_exporter_extra_environment" {
  type    = map(string)
  default = {}
}

variable "platform_exporter_extra_environment" {
  type    = map(string)
  default = {}
}

variable "tags" { type = map(string) }

locals {
  env = var.tags["Environment"]

  on = {
    "core-runtime"      = var.enabled && var.core_runtime_enabled
    "core-exporter"     = var.enabled && var.core_exporter_enabled
    "platform-exporter" = var.enabled && var.platform_exporter_enabled
  }

  ext = var.core_secret_arns

  # Secret entries this module owns (names only). Core's core/* entries (db-app, db-exporter, identity-keys,
  # staff-keys, bridge-service-key, llm-gateway-token) are consumed by ARN, never created.
  secret_owner = {
    "core/bridge-signers"           = "core-runtime"
    "core/exporter-keys"            = "core-exporter"
    "platform-exporter/db-readonly" = "platform-exporter"
    "platform-exporter/keys"        = "platform-exporter"
  }
  entries = { for k, o in local.secret_owner : k => o if local.on[o] }
  arn     = { for k, s in aws_secretsmanager_secret.this : k => s.arn }

  control_api_url = "http://${var.control_api_dns_name}:${var.control_api_port}"
  signers         = try(local.arn["core/bridge-signers"], "")
  exporter_keys   = try(local.arn["core/exporter-keys"], "")
  platform_keys   = try(local.arn["platform-exporter/keys"], "")

  workloads = {
    "core-runtime" = {
      image         = var.core_image
      command       = ["runtime"]
      port          = var.core_runtime_port
      cpu           = 512
      memory        = 1024
      desired_count = var.core_runtime_desired_count
      health_check  = ["CMD-SHELL", "python -c 'import urllib.request as u; u.urlopen(\"http://127.0.0.1:${var.core_runtime_port}/healthz\")'"]
      volumes       = { keys = "/run/pulso-keys", tmp = "/tmp" }
      environment = merge(
        var.runtime_extra_environment,
        var.llm_gateway_url == "" ? {} : { AGENTCORE_LLM_GATEWAY_URL = var.llm_gateway_url },
        {
          PULSO_TENANT_ID       = var.tenant_id
          PULSO_CONTROL_API_URL = local.control_api_url
          PULSO_LAB_BROKER_URL  = local.control_api_url
        },
      )
      secrets = merge(
        {
          AGENTCORE_REGISTRY_DSN            = "${lookup(local.ext, "db_app", "")}:registry_dsn::"
          AGENTCORE_EVAL_DSN                = "${lookup(local.ext, "db_app", "")}:eval_dsn::"
          CORE_IDENTITY_KEYS_JSON           = lookup(local.ext, "identity_keys", "")
          CORE_STAFF_KEYS_JSON              = lookup(local.ext, "staff_keys", "")
          PULSO_SERVICE_KEYS_JSON           = lookup(local.ext, "bridge_service_key", "")
          PULSO_BRIDGE_IDENTITY_SIGNER_JSON = "${local.signers}:identity::"
          PULSO_BRIDGE_STAFF_SIGNER_JSON    = "${local.signers}:staff::"
          PULSO_BRIDGE_CALLBACK_SIGNER_JSON = "${local.signers}:callback::"
          PULSO_BRIDGE_EXECUTOR_SIGNER_JSON = "${local.signers}:executor::"
        },
        contains(keys(local.ext), "llm_gateway_token") ? { AGENTCORE_LLM_GATEWAY_TOKEN = local.ext["llm_gateway_token"] } : {},
      )
      secret_arns = compact(concat(
        [for k in ["db_app", "identity_keys", "staff_keys", "bridge_service_key", "llm_gateway_token"] : lookup(local.ext, k, "")],
        [local.signers],
      ))
      missing = concat(
        [for k in ["db_app", "identity_keys", "staff_keys", "bridge_service_key"] : k if !contains(keys(local.ext), k)],
        var.llm_gateway_url != "" && !contains(keys(local.ext), "llm_gateway_token") ? ["llm_gateway_token"] : [],
      )
      database_sg = var.core_database_security_group_id
    }
    "core-exporter" = {
      image         = var.core_image
      command       = ["exporter"]
      port          = null
      cpu           = 256
      memory        = 512
      desired_count = var.core_exporter_desired_count
      health_check  = null
      volumes       = { keys = "/run/pulso-keys", tmp = "/tmp", state = "/var/lib/pulso-exporter" }
      environment = merge(
        var.core_exporter_extra_environment,
        {
          EXPECTED_RUNTIME_DB        = var.expected_runtime_db
          EXPECTED_EVAL_DB           = var.expected_eval_db
          PULSO_TENANT_ID            = var.tenant_id
          PULSO_CORE_INSTANCE        = var.core_instance
          PULSO_INGEST_BASE_URL      = local.control_api_url
          PULSO_EXPORTER_BINDING_REF = var.exporter_binding_ref
          PULSO_EXPORTER_STATE_DIR   = "/var/lib/pulso-exporter"
        },
      )
      secrets = {
        CORE_EXPORT_DATABASE_URL            = lookup(local.ext, "db_exporter", "")
        PULSO_EXPORTER_KEY_CONTROL_API_SEED = "${local.exporter_keys}:control_api_seed::"
        PULSO_EXPORTER_KEY_LAB_BROKER_SEED  = "${local.exporter_keys}:lab_broker_seed::"
      }
      secret_arns = compact([lookup(local.ext, "db_exporter", ""), local.exporter_keys])
      missing     = contains(keys(local.ext), "db_exporter") ? [] : ["db_exporter"]
      database_sg = var.core_database_security_group_id
    }
    "platform-exporter" = {
      image         = var.platform_exporter_image
      command       = null
      port          = null
      cpu           = 256
      memory        = 512
      desired_count = var.platform_exporter_desired_count
      health_check  = null
      volumes       = { keys = "/run/pulso-keys", tmp = "/tmp", state = "/var/lib/pulso-platform-exporter" }
      environment = merge(
        var.platform_exporter_extra_environment,
        {
          PULSO_CONTROL_API_URL = local.control_api_url
          PULSO_TENANT_ID       = var.tenant_id
          PLATFORM_INSTANCE     = var.platform_instance
          PULSO_BINDING_REF     = var.platform_binding_ref
          EXPORTER_STATE_PATH   = "/var/lib/pulso-platform-exporter/state.sqlite"
        },
      )
      # PLATFORM_DB_URL is the whole read-only credential (a connection string); the key seed is provisional until
      # the platform exporter materialises it like ADR 0009 (PL-L5). No static bearer token is ever injected.
      secrets = {
        PLATFORM_DB_URL                     = try(local.arn["platform-exporter/db-readonly"], "")
        PULSO_EXPORTER_KEY_CONTROL_API_SEED = "${local.platform_keys}:control_api_seed::"
      }
      secret_arns = compact([try(local.arn["platform-exporter/db-readonly"], ""), local.platform_keys])
      missing     = []
      database_sg = var.platform_database_security_group_id
    }
  }
  active = { for k, v in local.workloads : k => v if local.on[k] }

  db_rules = {
    for k, v in local.active : k => v if(k == "platform-exporter" ? var.manage_platform_database_ingress : var.manage_core_database_ingress)
  }
  engine_callers = local.on["core-runtime"] ? var.engine_caller_security_group_ids : {}
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.entries

  name                    = "${var.secret_name_prefix}/${each.key}"
  kms_key_id              = var.kms_key_arn == "" ? null : var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = merge(var.tags, { Workload = "pulso-${each.value}" })
}

module "iam" {
  source   = "../workload_iam"
  for_each = local.active

  workload_name               = "pulso-${each.key}"
  aws_region                  = var.aws_region
  own_secret_arns             = each.value.secret_arns
  secret_kms_key_arns         = var.kms_key_arn == "" ? [] : [var.kms_key_arn]
  task_statements             = []
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  permissions_boundary        = var.permissions_boundary
  tags                        = var.tags
}

resource "aws_cloudwatch_log_group" "bridge" {
  for_each = local.active

  name              = "/pulso/${local.env}/pulso-${each.key}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_security_group" "bridge" {
  for_each = local.active

  name_prefix = "${local.env}-pulso-${each.key}-"
  description = "Pulso ${each.key}: no ingress except the explicit rules; egress is explicit."
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    precondition {
      condition     = each.value.database_sg != ""
      error_message = "${each.key} needs its database security group (core_database_security_group_id or platform_database_security_group_id)."
    }
    precondition {
      condition     = length(each.value.missing) == 0
      error_message = "${each.key} is missing core_secret_arns entries: ${join(", ", each.value.missing)}."
    }
    precondition {
      condition     = var.control_api_security_group_id != "" && var.control_api_dns_name != ""
      error_message = "control_api_security_group_id and control_api_dns_name (engine_platform outputs) are required."
    }
  }
}

# F2 (callbacks, runtime) and F3 (observations, exporters): the engine side is opened here too, by security-group
# reference, so nothing depends on engine_platform core_callback_security_group_ids.
resource "aws_vpc_security_group_egress_rule" "to_control_api" {
  for_each = local.active

  security_group_id            = aws_security_group.bridge[each.key].id
  referenced_security_group_id = var.control_api_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.control_api_port
  to_port                      = var.control_api_port
  description                  = "control-api"
}

resource "aws_vpc_security_group_ingress_rule" "control_api_from_bridge" {
  for_each = local.active

  security_group_id            = var.control_api_security_group_id
  referenced_security_group_id = aws_security_group.bridge[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = var.control_api_port
  to_port                      = var.control_api_port
  description                  = "pulso-${each.key} to control-api"
}

# F5 and the platform read: each service reaches exactly one database security group.
resource "aws_vpc_security_group_egress_rule" "to_database" {
  for_each = local.active

  security_group_id            = aws_security_group.bridge[each.key].id
  referenced_security_group_id = each.value.database_sg
  ip_protocol                  = "tcp"
  from_port                    = var.database_port
  to_port                      = var.database_port
  description                  = "PostgreSQL only"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_bridge" {
  for_each = local.db_rules

  security_group_id            = each.value.database_sg
  referenced_security_group_id = aws_security_group.bridge[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = var.database_port
  to_port                      = var.database_port
  description                  = "PostgreSQL from pulso-${each.key}"
}

# F7: AWS APIs through the shared VPC endpoints; ECR layers through the S3 gateway endpoint prefix list.
resource "aws_vpc_security_group_egress_rule" "vpc_https" {
  for_each = local.active

  security_group_id = aws_security_group.bridge[each.key].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "VPC endpoints (AWS APIs)"
}

resource "aws_vpc_security_group_egress_rule" "s3_layers" {
  for_each = var.s3_egress_enabled ? toset(keys(local.active)) : toset([])

  security_group_id = aws_security_group.bridge[each.key].id
  prefix_list_id    = var.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 gateway endpoint (ECR image layers)"
}

# The runtime consumes the LLM gateway only (ADR 0004): no provider egress, no NAT.
resource "aws_vpc_security_group_egress_rule" "to_llm_gateway" {
  count = local.on["core-runtime"] && var.llm_gateway_security_group_id != "" ? 1 : 0

  security_group_id            = aws_security_group.bridge["core-runtime"].id
  referenced_security_group_id = var.llm_gateway_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.llm_gateway_port
  to_port                      = var.llm_gateway_port
  description                  = "LLM gateway"
}

# F1: control-api and worker call core-runtime; both ends are opened here.
resource "aws_vpc_security_group_ingress_rule" "runtime_from_engine" {
  for_each = local.engine_callers

  security_group_id            = aws_security_group.bridge["core-runtime"].id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.core_runtime_port
  to_port                      = var.core_runtime_port
  description                  = "${each.key} to core-runtime"
}

resource "aws_vpc_security_group_egress_rule" "engine_to_runtime" {
  for_each = local.engine_callers

  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.bridge["core-runtime"].id
  ip_protocol                  = "tcp"
  from_port                    = var.core_runtime_port
  to_port                      = var.core_runtime_port
  description                  = "${each.key} to core-runtime"
}

# Private DNS core-runtime.<env>.pulso.internal in the shared namespace; no ALB, no WAF.
resource "aws_service_discovery_service" "core_runtime" {
  count = local.on["core-runtime"] ? 1 : 0

  name = "core-runtime"
  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.service_discovery_namespace_id != ""
      error_message = "service_discovery_namespace_id (the shared <env>.pulso.internal namespace) is required for core-runtime."
    }
  }
}

module "workload" {
  source   = "../workload"
  for_each = local.active

  name                        = "pulso-${each.key}"
  image                       = each.value.image
  command                     = each.value.command
  cluster_arn                 = var.cluster_arn
  subnet_ids                  = var.private_subnet_ids
  security_group_ids          = [aws_security_group.bridge[each.key].id]
  task_role_arn               = module.iam[each.key].task_role_arn
  execution_role_arn          = module.iam[each.key].execution_role_arn
  aws_region                  = var.aws_region
  log_group_name              = aws_cloudwatch_log_group.bridge[each.key].name
  port                        = each.value.port
  cpu                         = each.value.cpu
  memory                      = each.value.memory
  desired_count               = each.value.desired_count
  create_service              = true
  environment                 = each.value.environment
  secrets                     = each.value.secrets
  health_check_command        = each.value.health_check
  read_only_root_filesystem   = true
  ephemeral_volumes           = each.value.volumes
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  service_registry_arn        = each.key == "core-runtime" ? aws_service_discovery_service.core_runtime[0].arn : null
  tags                        = merge(var.tags, { Workload = "pulso-${each.key}" })
}

output "enabled" { value = var.enabled }

output "security_group_ids" {
  value       = { for k, sg in aws_security_group.bridge : k => sg.id }
  description = "Per service. core-runtime is what the LLM gateway side admits; all three are already admitted on control-api here."
}

output "task_definition_arns" {
  value = { for k, w in module.workload : k => w.task_definition_arn }
}

output "core_runtime_dns_name" {
  value       = local.on["core-runtime"] ? "core-runtime.${local.env}.pulso.internal" : null
  description = "Feed http://<this>:<port> to engine_platform core_runtime_url."
}

output "secret_names" {
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.name }
  description = "Entry names only; values are set out of band."
}

output "secret_variable_names" {
  value       = { for k, v in local.active : k => sort(keys(v.secrets)) }
  description = "Environment variable names injected as secrets, per service (never values)."
}

output "execution_secret_arns" {
  value       = { for k, v in local.active : k => v.secret_arns }
  description = "The only secrets each execution role may resolve."
}

output "container_settings" {
  value = { for k, v in local.active : k => {
    command                   = v.command
    port                      = v.port
    environment               = v.environment
    read_only_root_filesystem = try(module.workload[k].container_definition.readonlyRootFilesystem, false)
    ephemeral_volumes         = { for m in try(module.workload[k].container_definition.mountPoints, []) : m.sourceVolume => m.containerPath }
  } }
  description = "Plain (non-secret) settings per service, read back from the rendered container definition."
}

output "rendered_containers" {
  value       = { for k, w in module.workload : k => w.container_definition }
  description = "Rendered container definitions per service (secret entries are ARN references)."
}

output "rendered_secrets" {
  value       = { for k, w in module.workload : k => { for s in w.container_definition.secrets : s.name => s.valueFrom } }
  description = "Secret variable name to Secrets Manager reference actually rendered per service (ARNs, never values)."
}
