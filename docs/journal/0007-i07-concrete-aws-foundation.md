# I07 — concrete AWS foundation

## Decision

Replace interface-only Terraform modules with resource declarations for the
two approved roots: `staging` and `prod` (the latter is the hackathon demo).
The engine remains responsible for all local Podman/Compose/LocalStack assets;
none are reintroduced here.

## Scope

Network, security groups, GitHub OIDC/IAM roles, Fargate service, encrypted
versioned S3 buckets, private RDS PostgreSQL, Secrets Manager, CloudWatch/SNS
alarms and deployment runbook are represented as Terraform. The HTTP API is
deferred pending an enforceable edge contract.
Inputs that would fabricate security topology—VPN/customer gateway, OIDC
subjects/thumbprints, API integration—remain explicit gaps.

## Verification

The new structural contract started RED because no AWS resources existed, then
went GREEN with `python -m unittest discover -s tests -v`. Terraform binary is
not installed on this Windows host; CI remains the authoritative formatter and
credential-free validator until its result is available. No plan/apply ran.

## Review remediation

The first independent security/infrastructure review found six implementation
gaps: S3 had no explicit KMS default encryption, the workload had no explicit
outbound PostgreSQL rule, task execution and application permissions shared a
role, each environment attempted to create the account-global GitHub OIDC
provider, `alarm_email` had no consumer, and the Fargate definition omitted
logging and a port mapping. This remediation makes those boundaries concrete:

- both buckets require the supplied KMS key and S3 Bucket Keys;
- separate SG rule resources permit only workload-to-database TCP/5432 while
  preserving required HTTPS egress, avoiding a cyclic inline SG definition;
- the environment accepts the single account-level GitHub OIDC provider ARN;
  Fargate gets separate hardcoded execution and runtime roles. Runtime access
  is restricted to its generated secret and the source/artifact buckets;
- a non-null alarm mailbox creates an email SNS subscription and AWS confirmation
  remains an explicit pre-apply step;
- the Fargate container emits `awslogs` and maps the configured service port.

## Final security remediation

The runtime role now has the minimum KMS action set required to read its
Secrets Manager value and use the single supplied SSE-KMS key for S3 objects:
`Decrypt` and `GenerateDataKey`, both scoped to `kms_key_arn`. It has no
wildcard KMS action or resource; `Encrypt` and `DescribeKey` are deliberately
absent because the runtime does not invoke them directly. KMS calls must also
arrive via S3 or Secrets Manager in the configured region, so a compromised
runtime cannot request a CMK data key directly. S3 calls are bound to the
exact source/artifact bucket ARNs in `kms:EncryptionContext:aws:s3:arn`;
because both buckets enable S3 Bucket Keys, those are bucket—not object—ARNs.
Secrets calls are bound to the exact runtime secret ARN via
`kms:EncryptionContext:SecretARN`.

Each bucket also has a deny-only `PutObject` policy. Default encryption is not
enough by itself because a caller can supply another encryption header. The
policy denies a missing KMS-key header, a non-`aws:kms` algorithm, and any KMS
key ARN other than `kms_key_arn`; it is generated from one map so both source
and artifact buckets get the same invariant.

The prior HTTP API v2 declaration was removed. An HTTP API v2 is public by
default and cannot consume the edge security group, so an API lacking an
approved authenticated route or private ingress was not a harmless placeholder.
`docs/contracts/edge-integration-v1.md` records the concrete inputs and tests
required for a future reviewed edge slice.

The associated edge security group, public HTTPS rules and workload ingress
rule were removed in the same slice. They had no consumer after API deferral
and would otherwise leave a pre-authorized public attachment in the graph.

These are Terraform declarations only. They have not been applied or tested
against an AWS account.

## Final verification

After the final independent infrastructure/security review, the portable
contract suite passed: `python -m unittest discover -s tests -v` (**24 tests**)
and `git diff --check` were green. The Windows host has no `terraform` binary,
so `terraform fmt -check`, `init -backend=false` and `validate` were not run
locally; the pinned credential-free CI workflow remains the required gate for
both environment roots. No plan, apply, AWS credentials or external deployment
was attempted.
