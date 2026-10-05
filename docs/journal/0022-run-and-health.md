# 0022 Run and health of the host stacks (INFRA-B)

Date: 2026-10-05. Branch `claude/infra-run-health`, from `origin/main` 7251d8f. Nothing applied, no AWS call, no credential.

## What was compared

Each image's own Dockerfile, health code and env readers (engine, llm-gateway, tool-service; agent-core for the probe facts only)
against `deploy/hackathon/*`, the `hackathon_compute` start scripts and the `hackathon_data` secret and SSM keys. The result is
`docs/run-and-health.md`; the findings that were small mismatches were fixed here.

## Slice, RED then GREEN

`tests/test_run_health_contract.py` was written first: 11 of 16 tests failed on the unmodified tree (gateway not published and
unprobed, consumers not waiting for health, `/srv/data/pulso` not chowned, no `--force-recreate`, engine tokens absent, Caddy
stripping the prefix the engine serves under, `.env.example` incomplete, release script without `--format docker`/`--platform`,
forwarder recipe absent). After the changes:

```
python -m unittest discover -s tests          -> 257 tests OK (220 before, +16 run-health, +21 prodlike)
terraform test in modules/hackathon_compute   -> 33 passed
terraform test in modules/hackathon_data      -> 29 passed
terraform test in envs/hackathon              -> see the PR description for the final run
```

Terraform expectations changed on purpose: `allowed_ports` of the core host gains `8080:8080`, and the "gateway is never published"
assertion became "published on 8080 only" (the network module already opened 8080 from the engine security group).

## Limits of this evidence

Static and mock-provider tests only. No image was pulled onto a host, no `pulso run` saw the new tokens, Caddy's prefix handling was
not exercised in a browser, the forwarder image was not built. Changing `user_data` means `user_data_replace_on_change` would replace
the hosts on the next apply (harmless while nothing is applied). The two new generated tokens reach an existing secret version only
through `aws-prod.ps1 seed-secret-keys` (merge-only).

## Related

`docs/prodlike-rehearsal.md` (local Podman rehearsal and its slots), `docs/runbooks/build-and-release.md` (no-CI release).
