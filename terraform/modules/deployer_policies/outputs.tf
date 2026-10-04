output "deployer_policy_json_core" {
  description = "Identity policy for the teams that ship agent-core and llm-gateway (core host). Attach it to the IAM users or roles created for them."
  value       = jsonencode(local.policies["core"])
}

output "deployer_policy_json_platform" {
  description = "Identity policy for the support-platform team (platform host)."
  value       = jsonencode(local.policies["platform"])
}

output "deployer_policy_json_engine" {
  description = "Identity policy for the engine team (engine host)."
  value       = jsonencode(local.policies["engine"])
}
