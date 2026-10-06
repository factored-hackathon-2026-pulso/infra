# 0025 INFRA-D: the complete profile, the edge audit, the acceptance script, the day-one runbook

Date: 2026-10-06. Lane INFRA-D (Claude). Offline only: no `terraform` command, no AWS call, no credential, no `apply`, no image build. Branch `claude/infra-fullstack-profile`, worktree `D:\.codex\factored\worktrees\infra-claude-fullstack`.

## What was done

1. `terraform/envs/hackathon/prod.tfvars.complete.example`: every service flag on, three `m7i-flex.large` hosts, all ten image slots, no secret value. `tests/test_fullstack_profile_contract.py` pins: (a) every `*_enabled` bool variable that defaults to false is true, hosts and edge on, instance types valid for the Free Plan; (b) `AGENTCORE_ALLOW_DOUBLES`, `AGENTCORE_ALLOW_DEMO` and `PULSO_REGISTRY_TOKEN` appear nowhere in the profile, the bundle, the secret contract, the root or its modules; (c) the platform host is enabled and, once the bundle declares it, runs `CC_ENV=staging` with the demo settings (skipped only if the bundle stops declaring it; infra PR 46 declares it).
2. `docs/edge-audit.md`: routes, WebSocket, timeouts, forwarded headers, same-origin SPA, fourteen gaps with file and line.
3. `scripts/aws-acceptance.ps1` and `scripts/tests/aws-acceptance.Tests.ps1`: fourteen checks, PASS or FAIL or SKIP with the reason, host-side checks as printed SSM commands or sent with `-HostChecks Run`, tokens only in memory and on curl's standard input.
4. `docs/infra-day-one.md`: twelve layers with commands, human steps, checks, timings and a troubleshooting table.
5. Images and data (found while verifying them):
   - `Set-ImagesInTfvars` rewrote the images block with six keys, so building any one service dropped `agent`, `tools`, `pipeline` and `forwarder` from `prod.tfvars` (and re-inserted a `core` placeholder). It now keeps them (`scripts/tests/aws-fullstack.Tests.ps1`).
   - The builder stage `images` block lacked `forwarder` and `pipeline`, so `plan -Stage builder` with the complete profile would have failed the variable validation.
   - `-ViteApiUrl /` (the same-origin build) was refused by the URL check.
   - `-Builder host` had no recipe for `data-pipeline` and `otlp-forwarder`; the forwarder source zip did not contain this repository's Dockerfile (a manual step in the docs): the script now adds `docker/otlp-forwarder.Dockerfile` unless the source has it.
   - The loader passed `DATASET_PREFIX=landing/bank` without a trailing slash; the data pipeline strips the prefix and takes the first path segment as the table, so no table matched and `ingest_bank` would have loaded nothing. `pulso-loader.sh` now normalises the slash.
   - The engine image on `main` lacks python3, PyYAML and `scripts/regression`: engine pull request 122 was stacked on 119 and merged into 119's branch after 119 reached `main`. Re-landed as engine pull request 130.
   - The `TF_PLUGIN_CACHE_DIR` advice in `docs/troubleshooting.md` contradicted the machine's finding (it must be unset); corrected.

## Verified and not

Python `unittest discover -s tests`: one full run, 440 tests; one failure that is already on `main` (`test_prodlike_serve`: PR 45 added `LANG_THRESHOLDS` to `secrets.tf` but not to `scripts/prodlike/env_contract.json`), fixed here by adding the name; the affected modules then passed together with the new contract test. Parse check of the three PowerShell files. NOT run: Pester (CI runs it on Windows), `terraform fmt`, `validate`, `test` (the machine's provider start takes minutes; not run by instruction), any AWS or HTTP call. The behaviour of the acceptance script against a real distribution is unobserved; its HTTP and aws calls are mocked in the tests.
