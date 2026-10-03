# Infrastructure context

Owns Terraform and AWS deployment of the improvement service and of Agent Core (ADR 0003): remote-state contracts, network, identity/OIDC, data, compute and infrastructure observability. `improvement-engine` owns reproducible local development, Compose/Podman, fixtures, LocalStack, PostgreSQL integration tests and its CI. Agent Core is a second workload on the same foundation (ADR 0003): its code, image build, schema, migrations and runtime behavior stay in `agent-core`. The LLM gateway (`llm-gateway` repository) is a third workload (ADR 0004): stateless, private, and the only one that calls model providers; its code, image build and runtime behavior stay there. The providers behind it are external products; consumer configuration is not implementation of them.

Terraform has two environments only: `staging` for validation and `prod` for
the hackathon demo. No deployment is automated; a future manually approved
plan/apply design must be introduced as its own reviewed slice.

The Terraform foundation exposes public/private networking and NAT posture,
security, IAM boundaries, deferred compute/database, storage, Secrets, API and
observability contracts. It does not select a VPN topology, compute/database
engine or provider integration. The obsolete local doctor/profile harness was
removed after no-consumer verification; source data stays outside this repo.
