# Terraform deployment runbook

1. Obtain approved backend configuration outside Git for `staging`; never put
   state credentials, data, plans or secrets in this repository.
2. Supply reviewed environment inputs, including immutable `image_digest`,
   explicit OIDC subjects, bucket names and KMS key ARN. Inspect the plan for
   destructive RDS/S3 changes and for a NAT cost posture before approval.
3. Apply staging only through the approved GitHub OIDC role. Run the engine
   smoke/health workflow owned by `improvement-engine`; this repo cannot claim
   application health merely from Terraform success.
4. Review staging evidence before separately approving the prod demo plan.
   `prod` is a hackathon demo environment, not a banking production claim.
5. On an alarm, preserve CloudWatch logs and Terraform plan/state evidence,
   page the configured owner, and use a reviewed rollback/change rather than
   deleting state or resources manually.

No CI workflow in this repository applies Terraform automatically.
