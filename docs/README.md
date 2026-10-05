# Documentation index

Start with the quickstart; the rest is reference. These docs are checked against the code by `tests/test_docs_consistency.py` (documented subcommands, flags, variables, modules and links must exist).

| Doc | Read it to |
|---|---|
| [aws-prod-quickstart.md](aws-prod-quickstart.md) | create and deploy prod from your machine, one page |
| [architecture.md](architecture.md) | see the account diagram, what talks to what, data classes |
| [operations.md](operations.md) | run day 2: start/stop, deploy, roll back, secrets, restore, data load, teardown |
| [agent-services.md](agent-services.md) | turn on agent-core serve and tool-service for support-platform (`agent_services_enabled`) |
| [service-deployment.md](service-deployment.md) | ship a change to one service (build in the cloud, deploy a digest, roll back) without a full apply: for service teams |
| [modification-guide.md](modification-guide.md) | change the Terraform: layout, module contracts, variables, TDD, CI |
| [troubleshooting.md](troubleshooting.md) | fix known failures with exact checks |
| [security-model.md](security-model.md) | understand who can do what, trade-offs, what is not protected |
| [costs.md](costs.md) | estimate and control the monthly bill |
| [decisions.md](decisions.md) | ADR index and the simplification decision |
| [run-and-health.md](run-and-health.md) | see how each service runs on the hosts: image, command, env names, ports, probes, restart, start order, limits |
| [runbooks/build-and-release.md](runbooks/build-and-release.md) | build with Podman, scan, push to ECR, pin digests, roll out and roll back when there is no CI |
| [prodlike-rehearsal.md](prodlike-rehearsal.md) | rehearse the host stacks locally with Podman (`scripts/prodlike`) before any apply |

Temporary Linux build host for agents (cargo and tests off the Windows PC): [buildbox.md](buildbox.md).

Supporting references: [secrets-keys.md](secrets-keys.md) (secret key names), [db-bootstrap.md](db-bootstrap.md) (database roles and scripts), [aws-plan-review-checklist.md](aws-plan-review-checklist.md) (offline checker), [aws-asks.md](aws-asks.md) (decision log of asks), module READMEs under `terraform/modules/hackathon_*`, and [deploy/hackathon](../deploy/hackathon/README.md) (compose bundles).

Older pages kept as background, superseded where they differ: [hackathon-deploy.md](hackathon-deploy.md), [hackathon-foundations.md](hackathon-foundations.md), [runbook-new-account.md](runbook-new-account.md).

