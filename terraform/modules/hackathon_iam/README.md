# hackathon_iam

Three EC2 instance roles and profiles, one per host (ADR 0007): `core` (agent-core plus llm-gateway),
`platform` (support-platform), `engine` (pulso).

Common to all: `AmazonSSMManagedInstanceCore` (Session Manager, no SSH); log writes to `/<name>/*`;
`ecr:GetAuthorizationToken` (the only `Resource: "*"`); ECR pull on that host's repository ARNs; SSM parameter
reads under `<ssm_parameter_path_prefix>/<workload>/*` only (SecureString uses the AWS-managed `aws/ssm` key,
which needs no extra grant; a customer-managed key would).

| Host | S3 read/write | S3 read-only |
| --- | --- | --- |
| core | `core_s3_prefixes` (default `core/blobs`) | none |
| platform | none | none |
| engine | `engine_s3_prefixes` (default `engine`) | `engine_lake_read_prefixes` (default `landing`, `lake`) |

Permissions boundary on every role: allow-all intersected with a Deny on `iam:*`, `organizations:*` and
`account:*`, so a later widened policy cannot change identity or the organization.

Outputs: `instance_profile_name_{core,platform,engine}`, `instance_role_arn_{core,platform,engine}`,
`boundary_policy_arn`.

Test: `terraform init -backend=false && terraform test` (mock provider).
