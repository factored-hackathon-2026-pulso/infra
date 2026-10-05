variable "aws_region" {
  type        = string
  description = "Region for the bootstrap resources. Single-region prod (N. Virginia)."
  default     = "us-east-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Optional. Globally unique name of the remote-state bucket. Null (default) derives pulso-prod-tfstate-<account id>, so nobody has to pick a name."
  default     = null

  validation {
    condition     = var.state_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,56}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid lowercase S3 bucket name (3-58 characters: a-z, 0-9, dot, hyphen; a -trail suffix is appended for the CloudTrail bucket)."
  }
}
variable "state_key" {
  type        = string
  description = "Object key of the state file for the first environment composition, used only in the emitted backend snippet."
  default     = "pulso/prod/terraform.tfstate"
}

variable "tags" {
  type        = map(string)
  description = "Ownership tags applied to every bootstrap resource."
  default = {
    ManagedBy   = "terraform-bootstrap"
    Environment = "bootstrap"
    Service     = "pulso"
  }
}

variable "budget_alert_email" {
  type        = string
  description = "Mailbox a human reads for budget alerts. Empty means no budget is declared. Never committed; pass via tfvars or -var."
  default     = ""

  validation {
    condition     = var.budget_alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be empty or an email address."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly cost ceiling in USD for the budget alarm (AWS-06). Alerts at 50, 80 and 100 percent."
  default     = 100
}

variable "account_alias" {
  type        = string
  description = "Optional IAM account alias (globally unique). Empty means none."
  default     = ""
}

variable "cloudtrail_enabled" {
  type        = bool
  description = "Create a multi-region management-event trail into a private bucket (first copy of management events is free; S3 storage is billed). Off by default; enable when auditing is needed."
  default     = false
}

variable "github_org" {
  type        = string
  description = "GitHub organization allowed to assume the deploy role. Empty with empty github_repo means no OIDC provider or role."
  default     = ""

  validation {
    condition     = (var.github_org == "") == (var.github_repo == "")
    error_message = "Set github_org and github_repo together, or leave both empty."
  }
}

variable "github_repo" {
  type        = string
  description = "GitHub repository (without org) of the infra repo."
  default     = ""
}

variable "github_allowed_refs" {
  type        = list(string)
  description = "Git refs allowed to assume the deploy role, for example refs/heads/main. No wildcards."
  default     = ["refs/heads/main"]

  validation {
    condition     = alltrue([for r in var.github_allowed_refs : !strcontains(r, "*")])
    error_message = "Wildcard refs are not allowed."
  }
}

variable "ecr_repository_prefix" {
  type        = string
  description = "Prefix of ECR repositories (<prefix>/pulso-engine), matching the <env>/pulso-engine convention."
  default     = "pulso-prod"
}

variable "ecr_repositories" {
  type        = set(string)
  description = "Repositories to create. The console image is not needed. Defaults are the images the hackathon compose bundles pull (caddy is a digest-pinned mirror of the upstream image)."
  default     = ["pulso-engine", "core-runtime", "llm-gateway", "support-platform-api", "support-platform-web", "caddy", "agent-core-serve", "tool-service", "data-pipeline", "otlp-forwarder"]
}
