# I07 — concrete AWS foundation

## Decision

Replace interface-only Terraform modules with resource declarations for the
two approved roots: `staging` and `prod` (the latter is the hackathon demo).
The engine remains responsible for all local Podman/Compose/LocalStack assets;
none are reintroduced here.

## Scope

Network, security groups, GitHub OIDC/IAM roles, Fargate service, encrypted
versioned S3 buckets, private RDS PostgreSQL, Secrets Manager, API Gateway,
CloudWatch/SNS alarms and deployment runbook are represented as Terraform.
Inputs that would fabricate security topology—VPN/customer gateway, OIDC
subjects/thumbprints, API integration—remain explicit gaps.

## Verification

The new structural contract started RED because no AWS resources existed, then
went GREEN with `python -m unittest discover -s tests -v`. Terraform binary is
not installed on this Windows host; CI remains the authoritative formatter and
credential-free validator until its result is available. No plan/apply ran.
