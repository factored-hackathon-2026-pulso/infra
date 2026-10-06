# Edge audit: CloudFront and the host proxies for the full system

Audit of what stands between a browser and the platform, the API, the WebSocket and the engine in the complete profile ([prod.tfvars.complete.example](../terraform/envs/hackathon/prod.tfvars.complete.example)): one CloudFront distribution on its own `*.cloudfront.net` domain (no custom domain, no WAF, no viewer allowlist: the public URL is intentionally unrestricted, a risk the owner accepted), a public origin per host (profile `free_plan`), Caddy on each host, then the containers. Read-only review of `origin/main` at `74851d4` (infra PR 45) against the platform's own edge contract (support-platform `docs/platform/deploy/edge.md`, 2026-10-05) and `docs/reports-claude/PLATFORM_DEPLOY_READINESS_2026-10-06.md`. Nothing was applied; nothing here was exercised against a real distribution.

Line numbers refer to `origin/main` at that commit. Infra pull request 46 (`claude/infra-platform-contract`, "PR 46" below) merged while this audit was being written and fixes several rows; the rows say so, and the line numbers still point at the pre-merge files so each gap stays traceable. This audit does not edit those files.

## The routes today

| Viewer path | CloudFront behaviour | Origin | Host proxy | Container |
|---|---|---|---|---|
| `/` , `/assets/*`, SPA routes | default behaviour (`hackathon_edge/main.tf:183-192`) | `platform` (host port 80) | `platform/Caddyfile:24` `reverse_proxy support-platform-web:80` | nginx, `try_files` to `index.html` |
| `/api/*` (REST) | the same default behaviour | `platform` | `platform/Caddyfile:23` `reverse_proxy /api/* support-platform-api:8000` | API |
| `/api/v1/ws?token=` (WebSocket) | the same default behaviour (GET is allowed, `Managed-AllViewer` forwards `Upgrade` and `Connection`) | `platform` | the same `/api/*` proxy (Caddy upgrades by itself) | API, heartbeat every 25 s |
| `/pulso/*` (engine routes, console) | `ordered_cache_behavior` `/pulso/*` (`main.tf:194-204`) | `engine` (host port 8080) | `engine/Caddyfile:20-21`, prefix kept | `pulso:8080` |
| `/api/v1/internal/*`, `/internal*`, `/pulso/internal*` | reach the proxy | | answered 404 by Caddy before any proxying (`platform/Caddyfile:19-20`, `engine/Caddyfile:16-17`) | never reached |
| `/healthz` | reaches the proxy | | Caddy answers `ok` itself (before the origin check) | |
| anything without the `X-Origin-Verify` header | | | 403 from Caddy (origin protection against another distribution or a scanner on the public IP; this is not a viewer restriction and stays) | |

Cache policy is `Managed-CachingDisabled` on both behaviours (`main.tf:189`, `201`): nothing is cached, which is what the API and the WebSocket need. Forwarded to the origin: everything (`Managed-AllViewer`, `main.tf:190`, `202`): all viewer headers including `Authorization`, cookies and query strings (the WebSocket token). The security headers policy adds HSTS, `nosniff`, frame deny and a referrer policy.

## What the platform needs for same-origin SPA calls

1. The SPA must be built with `VITE_API_URL=/` so it calls `/api/v1/...` and `wss://<domain>/api/v1/ws` on its own origin. support-platform `main` accepts `/` or an empty value (`frontend/src/lib/config.ts`); an unset value still means `http://localhost:8000`, which is the Dockerfile default (`frontend/Dockerfile`, `ARG VITE_API_URL`). Build it with `aws-prod.ps1 images -Service support-platform-web -ViteApiUrl /` (the flag refused `/` before this change: `scripts/aws-prod.ps1:509`).
2. `CC_PUBLIC_APP_URL` and `CC_CORS_ORIGINS` come from SSM parameters derived from the CloudFront domain (`terraform/envs/hackathon/main.tf:417-427`); no human value. Same-origin calls need no CORS; the origin in the list is harmless.
3. No cookies are used by the API, so no cookie forwarding or `SameSite` question exists.
4. `X-Forwarded-Proto: https` must reach the API (scheme of absolute URLs and `wss`), and the client address should be the viewer's (rows E5 and E6).

## Gaps and risks

| # | Where (file:line on `main`) | Gap | Effect | Status |
|---|---|---|---|---|
| E1 | `hackathon_edge/main.tf:162-170` (public origin) and `:154-160` (VPC origin) | no `origin_read_timeout`: CloudFront waits 30 s | the platform waits for agent-core up to 55 s (copilot answers, builder evaluation; PRODLIKE measured 10 to 60 s per turn with real mimo flash); the viewer gets a 504 at 30 s while the work continues | PR 46 sets 60 s (the maximum without a quota increase) and the platform's `CC_AGENT_CORE_TIMEOUT_SECONDS=55`. Turns that need more than 60 s (PRODLIKE saw 91 to 144 s behind gateway timeouts) still end as an error at 55 s: a quota increase to 180 s is the only lever, not requested |
| E2 | `platform/compose.yaml:23-24` | the API health check calls `GET /` (404), so the container is never healthy and the proxy (`depends_on ... service_healthy`, `:53-57`) never starts | the site is down on first boot | PR 46 moves it to `/readyz` |
| E3 | `platform/compose.yaml` (no `CC_ENV`), `docs/secrets-wiring.md:72` | the platform runtime mode is not set | demo accounts and the dev MFA code only exist with `CC_ENV=staging`; the default is not that | PR 46 sets `CC_ENV: staging` and the demo seed settings. `tests/test_fullstack_profile_contract.py` pins it |
| E4 | `platform/compose.yaml:16-30` | no `stop_grace_period` on the API | a deploy cuts requests at Docker's 10 s | PR 46: 30 s |
| E5 | `platform/Caddyfile:23` | Caddy sends `X-Forwarded-Proto: http` (the CloudFront to origin hop is HTTP) | the API builds `http://` and `ws://` absolute URLs | PR 46: `header_up X-Forwarded-Proto https` |
| E6 | `platform/Caddyfile:1-4` | no `trusted_proxies`: Caddy replaces `X-Forwarded-For` with its peer | the API sees a CloudFront address as the client (rate limits, audit) | PR 46 trusts `private_ranges`. In `free_plan` the origin is public: CloudFront connects from public addresses, so `private_ranges` does not match them and the client address stays a CloudFront one. Cosmetic for the demo; the exact fix is to trust the CloudFront origin-facing ranges (the managed prefix list `com.amazonaws.global.cloudfront.origin-facing`) in Caddy, which needs the list rendered into the file: follow-up |
| E7 | `hackathon_edge/main.tf:162-170`, `variables.tf:44-47` | `origin_protocol_policy = http-only` on a public origin | the CloudFront to EC2 hop is plain HTTP across the public network: session tokens, the demo password at login and the WebSocket token are readable on that path. Only the CloudFront prefix list reaches the ports (security groups) and `X-Origin-Verify` is checked, but the bytes are not encrypted | cannot be fixed without a custom domain: CloudFront needs a certificate for the origin name, and `*.compute.amazonaws.com` names cannot get one. A consequence of "no custom domain", recorded here so it is a conscious one |
| E8 | `hackathon_edge/main.tf:188`, `:200` | `compress = true` with `Managed-CachingDisabled`: CloudFront compresses only when the cache policy enables gzip or brotli, and this one does not; Caddy and nginx send nothing compressed either | the SPA bundle travels uncompressed | optional: `encode zstd gzip` in the platform Caddyfile route (additive); not done here, the file belongs to the platform bundle |
| E9 | `hackathon_edge/main.tf:183-192` | SPA hashed assets (`/assets/*`) are not cached at the edge | every asset request reaches the platform host | optional: one more `ordered_cache_behavior` `/assets/*` with `Managed-CachingOptimized` (the SPA already marks them immutable); not done here to keep this change out of the module that PR 46 edited |
| E10 | `engine/Caddyfile:20` | `@pulso path /pulso/*` | `/pulso` without the slash is answered by the platform SPA (CloudFront default behaviour), not the engine | cosmetic; link to `/pulso/` |
| E11 | `terraform/envs/hackathon/main.tf:417-427` and `hackathon_compute/templates/prepare.sh.tftpl:44-50` | the platform host reads `CC_PUBLIC_APP_URL` and `CC_CORS_ORIGINS` from SSM at `pulso-stack` start; the parameters exist only after the distribution exists, which needs the host (a cycle documented in `main.tf`). A missing parameter is skipped silently | on the very first apply the API can start without them and, with the staging runtime rules, exit while compose keeps restarting it on the same stale env file | runbook: after the apply finishes, `sudo systemctl restart pulso-stack` on the platform host, then check (`docs/infra-day-one.md`, layer 5) |
| E12 | `hackathon_network/main.tf:194-199` | the CloudFront managed prefix list is one inbound rule that counts as the list's maximum entries (about 55) against the default 60 rules per security group | the platform group also carries the 8000 rules from core and engine: close to the limit; one more rule in that group fails the apply with a quota error | watch at plan time; a quota increase is the way out. Not changed |
| E13 | `hackathon_edge/main.tf:212-214` | CloudFront default certificate | viewer TLS is whatever CloudFront's default certificate allows (no minimum-version control) | accepted with "no custom domain" |
| E14 | edge module (no `logging_config`) | CloudFront standard logs are off | correct for the WebSocket token in the query string: it must not enter logs (platform edge.md section 7) | keep it off, or exclude `cs-uri-query` if logs are ever enabled |

## WebSocket, timeouts and headers in one place

- WebSocket: no extra behaviour. Heartbeat 25 s (`CC_REALTIME_HEARTBEAT_SECONDS`) is below every idle timeout on the path, including CloudFront's origin read timeout. Deploys close sockets with 1012 and the SPA reconnects.
- Origin read timeout: 30 s on `main` (E1), 60 s with PR 46. Platform to agent-core: 55 s. agent-core `serve` itself and the gateway use their own limits (gateway profile `timeout_s` 20 per generation).
- Keep-alive: CloudFront origin keep-alive stays at its 5 s default; Caddy's idle timeout is longer, so CloudFront never reuses a connection Caddy just closed.
- Forwarded headers: all viewer headers reach Caddy. `Host` is the `*.cloudfront.net` name; Caddy listens on `:80` and `:8080` for any host. `X-Forwarded-Host` is set by Caddy; `X-Forwarded-Proto` and `X-Forwarded-For` are E5 and E6.
- `/api/v1/internal/*`: reached by agent-core (grant check) and the engine (announce, evidence) over the private network on host port 8000 (security group limited to the core and engine groups), never through CloudFront.

## What this audit changed

Only `scripts/aws-prod.ps1` (`-ViteApiUrl /`) and the tests and docs of this change. The rows fixed by PR 46 are marked; E6 (part), E7 to E10, E12 and E13 stay open for their owners; nothing here edits `hackathon_edge`, the Caddyfiles or the platform compose bundle.
