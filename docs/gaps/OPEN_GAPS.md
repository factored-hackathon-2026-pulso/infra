# Open infrastructure gaps

These are external decisions required to apply Terraform, not reasons to
pretend the declared resources are deployed.

| Gap | Owner | Evidence needed | Safe fallback |
|---|---|---|---|
| GitHub OIDC thumbprint and exact subject claims | Pulso AWS/GitHub administrators | Approved `github_oidc_thumbprints` and least-privilege `github_subjects` | No AWS plan/apply; CI remains credential-free validation |
| State bucket/table and bootstrap authority | Pulso AWS administrators | Existing governed state location or authorization for a bootstrap apply | Keep backend examples only |
| VPN/customer-gateway details | Network owner | Customer gateway, routing and approval | No VPN resource or route is created |
| API-to-engine integration URI and auth contract | improvement-engine owner | Published engine listener/health/auth contract | API has no invented route integration |
| Alarm destination | Service owner | Confirmed endpoint/on-call escalation | SNS topic is created only when `alarm_email` is configured |
