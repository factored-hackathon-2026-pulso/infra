# Open infrastructure gaps

These are external decisions required to apply Terraform, not reasons to
pretend the declared resources are deployed.

| Gap | Owner | Evidence needed | Safe fallback |
|---|---|---|---|
| Account-level GitHub OIDC provider and exact subject claims | Pulso AWS/GitHub administrators | Existing approved `github_oidc_provider_arn` and least-privilege `github_subjects` | No AWS plan/apply; CI remains credential-free validation |
| State bucket/table and bootstrap authority | Pulso AWS administrators | Existing governed state location or authorization for a bootstrap apply | Keep backend examples only |
| VPN/customer-gateway details | Network owner | Customer gateway, routing and approval | No VPN resource or route is created |
| Authenticated or private edge contract for a public HTTP API | improvement-engine and security owners | Published engine listener/health/auth contract plus approved authorizer or private-ingress architecture | No public HTTP API is created; the versioned contract remains non-deploying |
| Alarm destination confirmation | Service owner | Confirmed mailbox/on-call escalation and AWS SNS subscription confirmation | Non-null `alarm_email` creates an email subscription, but no alert is deliverable until its recipient confirms |
| Runtime database role and secret bootstrap | Database/security owners | ECS cannot prove a least-privilege connection to the declared RDS instance | Approved migration creating `pulso_runtime`, least-privilege grants, rotation and an externally managed `runtime_database_secret_arn`; the task must never receive the RDS master secret | Runtime remains dependency_blocked; do not present ECS/RDS declarations as an operable service |
| Runtime secret retrieval path | Network/KMS owners | Terraform alone cannot prove ECS retrieves the role secret | CMK key policy plus approved ECS egress or VPC endpoint path for Secrets Manager/KMS and a redacted smoke | Do not claim an ECS/RDS connection from a validated Terraform graph alone |
| Internal debug-ingress contract | improvement-engine + security + infra | `/internal/v1/debug` cannot be exposed safely | Listener/health/auth contract, internal ALB plus identity-aware proxy decision, private access route and integration tests | Keep the debug service unexposed; no API Gateway placeholder |
| Controlled external egress | Security + model-provider owner + infra | Runtime cannot make a governed external provider call | Versioned `egress_profile`, destination-control/logging approach and failure tests | `aws_private_endpoints_only`; dependency unavailable |
| Engine operational metric/alarm contract | improvement-engine + service owner + infra | AWS alarms beyond resource CPU diagnostics | Metric namespace/dimensions, thresholds, destination/runbook and firing/resolved evidence | Do not call the deployment operationally monitored |
