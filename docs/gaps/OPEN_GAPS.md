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
