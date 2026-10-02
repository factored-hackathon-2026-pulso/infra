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
| Engine runtime database-secret contract | improvement-engine + infra | ECS task cannot prove connection to the declared RDS instance | Environment-bound `database_connection_secret_arn`, task injection, least-privilege IAM, rotation and redacted smoke evidence | Do not present ECS/RDS declarations as an operable service |
| Internal debug-ingress contract | improvement-engine + security + infra | `/internal/v1/debug` cannot be exposed safely | Listener/health/auth contract, internal ALB plus identity-aware proxy decision, private access route and integration tests | Keep the debug service unexposed; no API Gateway placeholder |
| Controlled external egress | Security + model-provider owner + infra | Runtime cannot make a governed external provider call | Versioned `egress_profile`, destination-control/logging approach and failure tests | `aws_private_endpoints_only`; dependency unavailable |
| Engine operational metric/alarm contract | improvement-engine + service owner + infra | AWS alarms beyond resource CPU diagnostics | Metric namespace/dimensions, thresholds, destination/runbook and firing/resolved evidence | Do not call the deployment operationally monitored |
