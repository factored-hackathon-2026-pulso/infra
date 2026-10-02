# Infrastructure context

Owns Terraform and AWS deployment of the improvement service: remote-state contracts, network, identity/OIDC, data, compute and infrastructure observability. `improvement-engine` owns reproducible local development, Compose/Podman, fixtures, LocalStack, PostgreSQL integration tests and its CI. Agent Core and model routing are external products; consumer configuration is not implementation of those products.

Terraform has two environments only: `staging` for validation and `prod` for
the hackathon demo. No deployment is automated; a future manually approved
plan/apply design must be introduced as its own reviewed slice.

The Terraform foundation exposes public/private networking and NAT posture,
security, IAM boundaries, deferred compute/database, storage, Secrets, API and
observability contracts. It does not select a VPN topology, compute/database
engine or provider integration. The obsolete local doctor/profile harness was
removed after no-consumer verification; source data stays outside this repo.
