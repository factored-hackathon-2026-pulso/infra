# I05 — staging and production-demo environments only

## Decision

Removed the `demo` Terraform environment. `staging` is the validation root and
`prod` is the hackathon demo root. CI validates them in that order, using
backend-free initialization and read-only provider locks.

## Safety boundary

This does not create a CD system: there is no workflow dispatch, schedule,
AWS credential, OIDC write permission, Terraform plan or Terraform apply.
Any future deployment workflow must be an explicitly authorized, independently
reviewed slice after the AWS resource design exists.

## Verification

The RED contract showed the former `demo` directory and CI iteration. The
final result must run the complete Python suite and Terraform 1.10.5 fmt plus
backend-free validation for `staging` and `prod`; independent infra/security
review is required before commit.
