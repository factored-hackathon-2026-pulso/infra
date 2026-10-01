# Infrastructure context

Owns Terraform and AWS deployment of the improvement service: remote-state contracts, network, identity/OIDC, data, compute and infrastructure observability. `improvement-engine` owns reproducible local development, Compose/Podman, fixtures, LocalStack, PostgreSQL integration tests and its CI. Agent Core and model routing are external products; consumer configuration is not implementation of those products.

The legacy doctor/local assets are migration inventory, not an authoritative stack. Missing configuration/tool/backend is a failure with remediation, not a healthy stack. LocalStack emulates S3 only and does not certify AWS IAM/VPC. Source data stays outside this repository.
