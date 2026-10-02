# Windows-first and external boundaries

Windows/PowerShell is the initial developer host. Podman may use its Linux VM; do not move development to WSL automatically. Infrastructure belongs here; improvement-engine owns detection/improvement. Agent Core and model routing are external dependencies, not products to implement. Missing services are explicit failures.

## AWS identity boundary

The GitHub Actions OIDC provider is an account-scoped bootstrap identity, not
an environment resource: `staging` and `prod` both receive its approved ARN.
Each environment creates a deploy role plus separate ECS execution and runtime
roles. The ECS service principal is fixed in Terraform; the runtime policy is
derived from the environment's secret and storage outputs, rather than caller
supplied policy or trust JSON. This keeps environment composition from silently
creating duplicate OIDC providers or arbitrary workload privileges.
