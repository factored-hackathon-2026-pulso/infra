# Build and release runbook (no hosted CI)

Hosted CI is unavailable (the Actions budget is exhausted), so **nothing builds, scans, pushes or deploys by itself**. The
only gates are the ones you run here, by hand, in this order. Every step is local until step 4; steps 4 to 7 touch AWS and
need an explicit order from the account owner and a dedicated profile (`aws-prod.ps1` refuses `default` and the other
protected names). Nothing in this document has been run against AWS.

Targets: every host is `x86_64`, so every image is built `linux/amd64`. Build with `--format docker`: Podman's default OCI
format silently drops `HEALTHCHECK` (`scripts/release-engine.ps1` now does both when `-Engine podman`).

## 0. Preconditions

| Check | How |
|---|---|
| Clean checkout at the commit to release | `git status` empty, `git rev-parse HEAD` noted. The release script tags the image with that SHA and refuses nothing else. |
| One build at a time, with headroom | free RAM above 3 GB for the engine (Rust), 1 GB for the others; Podman machine memory at least 4 GiB; nothing else heavy running. `scripts/prodlike/prodlike.py build <name>` refuses below the threshold. Rust builds use `CARGO_BUILD_JOBS=1`. |
| Tools | Podman, PowerShell 7, the AWS CLI (steps 4 to 7 only), `syft` and `trivy` (optional but expected, see step 3). |

## 1. Build locally

Per image, from this repository (no push without `-Push`):

```
pwsh scripts/release-engine.ps1 -Engine podman -Context <source checkout> -Dockerfile <Dockerfile> -ImageName <name> -OutDir release-out/<name>
```

| Image (SSM key) | Context | Dockerfile | Notes |
|---|---|---|---|
| engine `pulso` | the improvement-engine checkout | its root `Dockerfile` | about 6 min cold; `CARGO_BUILD_JOBS=1` is the default in the file |
| `gateway` | the llm-gateway checkout | its `Dockerfile` | |
| `tools` | the tool-service checkout | its `Dockerfile` | bases are unpinned (`uv:latest`): record the resolved digests in the release notes |
| `agent` | the agent-core checkout | its `Dockerfile` | `--build-arg GIT_SHA=<40 hex>`; the image HEALTHCHECK probes 8000, compose overrides it for 8001 |
| `core` | improvement-engine `core-bridge` | `core-bridge/Dockerfile` | `-BuildContext core=<agent-core checkout at the pin>` |
| `support_api`, `support_web` | support-platform `backend`, `frontend` | per the platform brief | pending |
| forwarder (optional) | the improvement-engine checkout | `docker/otlp-forwarder.Dockerfile` of this repo | only if the observability fragment is wired |
| `proxy` (Caddy) | none | none | mirrored by `aws-prod.ps1 images -CaddyUpstreamDigest sha256:...` |

`aws-prod.ps1 images` (without `-Service`) builds the five original images the same way and writes `prod.tfvars`; it does not
know `agent`, `tools` or the forwarder, so add those digests by hand (step 5).

## 2. Rehearse the exact image locally

Before anything leaves the machine, run the local image through the prod-like stack
([prodlike-rehearsal.md](../prodlike-rehearsal.md)): `prodlike.py build`, `up`, `smoke`, optionally `chaos`. It uses the same
compose files, health checks and env names as the hosts. A red `up` (an unhealthy container) stops the release.

## 3. Scan and record

`release-engine.ps1` writes `deploy-manifest.json` with the image digest, the git SHA, an SPDX SBOM (when `syft` exists) and a
`trivy` report (when it exists). If a tool is missing the manifest says `skipped` with the reason; it is never faked.
Policy: no CRITICAL finding with a fix available in the final layer; anything else goes into the release notes with a reason.
Validate offline: `python release/validate_manifest.py release-out/<name>/deploy-manifest.json`.

## 4. Push to ECR (explicit order only)

```
pwsh scripts/release-engine.ps1 -Engine podman -Context <src> -Dockerfile <df> -ImageName <name> -OutDir release-out/<name> `
  -Push -AwsProfile <dedicated profile> -EcrRepository <account>.dkr.ecr.us-east-1.amazonaws.com/prod/<repo>
```

ECR repositories are created by the bootstrap root; their tags are `IMMUTABLE` and they scan on push. The script pushes a
digest-derived tag, reads the **registry** digest back (`RepoDigests`) and refuses to write a manifest without one. That
digest, not the local image id, is what is pinned.

## 5. Pin the digests

* First environment: put the registry digests in `prod.tfvars` under `images` (full `repo@sha256:...` references, per host:
  core `core`, `gateway`, `agent`, `tools`; platform `support_api`, `support_web`, `proxy`; engine `pulso`, `proxy`). Terraform
  seeds SSM `/pulso/<workload>/images/<key>` from them and then ignores the value.
* Later releases: do not edit Terraform; `aws-prod.ps1 deploy` changes the SSM parameter.

## 6. Roll out

```
pwsh scripts/aws-prod.ps1 deploy -Profile <profile> -Service <name> -Digest sha256:<64 hex> -Wait
```

Order: core host first (`llm-gateway`, `tool-service`, `agent-core`, each alone), then the engine, then the platform. The
document `pulso-deploy-<workload>` runs `deploy-stack.sh` on the host: render, pull, `up -d`, wait until every container is
healthy or exited 0 twice in a row (300 s), otherwise restore the previous digests. Database migrations: agent-core migrates in
its one-shot service before `serve`; the engine applies its own at start.
Verify: `aws-prod.ps1 status -Profile <profile>`, then on the host `docker compose -p pulso ps` through an SSM session, then the
smoke test through CloudFront.

## 7. Roll back

```
pwsh scripts/aws-prod.ps1 deploy -Profile <profile> -Service <name> -Rollback -Wait
```

It re-deploys the previous digest from the parameter history (and refuses one that is not digest-pinned or not in ECR). A
failed deploy already rolled the host back and restored the parameter. **Not covered:** an image rollback does not undo a
database migration; the only data rollback is the daily EBS snapshot (Postgres has its own volume).

## 8. What this process does not give you

No build on push, no scan gate, no signed provenance, no second reviewer, and `latest` bases are only as reproducible as the
day you built. Keep `release-out/<name>/` and the git SHA with the release notes. Restoring hosted CI would replace steps 1, 3
and part of 2 with a workflow; steps 4 to 7 stay manual by design.
