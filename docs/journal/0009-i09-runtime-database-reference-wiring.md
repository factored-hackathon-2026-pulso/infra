# I09 — runtime database reference wiring

## Decision

The ECS task receives a PostgreSQL endpoint and an externally bootstrapped,
application-role `runtime_database_secret_arn`, never the RDS-managed master
secret ARN, database credentials or a secret value. RDS still generates its
master password through `manage_master_user_password`; that credential remains
outside the ECS role. The runtime role can call `GetSecretValue` on exactly the
existing runtime secret and application-role secret, while direct KMS decrypt
is constrained to Secrets Manager and those secret ARNs.

## Scope and non-claims

This is Terraform wiring only. It does not create a secret value/version in
Terraform, run an ECS task, connect to PostgreSQL, plan or apply AWS.
Application code still chooses when to resolve the ARN and validates its
database connection.

Each environment passes the RDS master-secret ARN into the compute module only
as a Terraform guard input. Blocking `lifecycle.precondition`s on both the ECS
task definition and the runtime IAM policy reject an equal application ARN
before Terraform can create either resource. The guard ARN is not propagated to
the ECS container definition or runtime IAM policy document.

## Prerequisite

Creating the database role `pulso_runtime`, its least-privilege grants and the
corresponding Secrets Manager value is **dependency_blocked** on an approved
bootstrap/migration process. Terraform deliberately receives only its ARN. The
CMK key policy, ECS egress path and VPC endpoint/NAT design also require
approved evidence before claiming the runtime can retrieve that secret.

## Verification

The contract test first failed because the graph had no database-secret output,
runtime inputs or reference-only container environment. It passes after adding
the managed secret output, least-privilege role policy and environment wiring.
Terraform format and backend-free validation for both roots plus the full
portable suite are required before integration.
