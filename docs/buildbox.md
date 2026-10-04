# Buildbox: a temporary Linux build host

## Why

Many agents compiling Rust (`cargo`) and running test suites saturate the Windows PC. The buildbox is a TEMPORARY Linux
instance in the AWS account that any agent can use through SSM: sync a worktree, run a command, fetch the results. It is
a separate Terraform root, `terraform/envs/buildbox`, with its own state key `buildbox/terraform.tfstate`. Nothing in prod
depends on it and it depends on nothing of prod (account default VPC and a default public subnet). Removing it is one
`terraform destroy`.

What it creates (module `terraform/modules/buildbox`): one `c6i.2xlarge` on-demand Amazon Linux 2023 instance (IMDSv2,
encrypted 40 GB root, encrypted 100 GB gp3 data volume mounted at `/work`, both deleted on termination), a security
group with NO ingress and no key pair (access is SSM only, no NAT), a bucket `pulso-prod-buildbox-<account id>` (7 day
expiry, SSE-S3, no versioning, public access blocked, TLS only, `force_destroy`), an instance role (SSM core plus that
bucket only) and the scoped IAM user `pulso-buildbox` (no access key is created by Terraform). Everything is tagged
`Purpose=buildbox`, `Ephemeral=true`.

## Cost

About 0.34 USD per hour while running (on-demand). Stopped, you pay only the disks, about 8 USD per month. The box stops
itself after 30 minutes without a running job (a systemd timer checks marker files in `/work/.jobs`). `buildbox.ps1 status`
prints the state, uptime, running jobs and an estimate.

## Human setup (3 steps)

1. Apply the root with the ADMIN profile (state bucket from bootstrap; copy `backend.hcl.example` outside Git and fill it in):

   ```powershell
   $env:AWS_PROFILE = '<admin profile>'
   terraform -chdir=terraform/envs/buildbox init -backend-config=<path to your backend.hcl>
   terraform -chdir=terraform/envs/buildbox apply
   ```

2. In the IAM console create an access key for the user `pulso-buildbox` (Security credentials > Create access key).
3. Enter it locally, never in a file in Git: `aws configure --profile pulso-buildbox` (region `us-east-1`).

The first boot installs the toolchain (git, gcc/clang/lld, openssl, rustup, Node 22, Python 3.12 and uv, docker, jq,
awscli v2); `buildbox.ps1 up` waits for SSM, so allow a few minutes the first time.

## How agents use it

All commands default to `-Profile pulso-buildbox` and region `us-east-1`. Profiles named default, payana*, higo*,
standar* and management* are refused. State-changing commands print what they will do and ask for `YES`; agents pass
`-Yes`.

```powershell
./scripts/buildbox.ps1 status
./scripts/buildbox.ps1 up -Yes
./scripts/buildbox.ps1 sync -Worktree D:\.codex\factored\worktrees\engine-lane-x -Lane lane-x -Yes
./scripts/buildbox.ps1 run -Lane lane-x -Cmd 'cargo test -j 2 --offline --no-fail-fast' -Jobs 2 -Timeout 60 -Yes
./scripts/buildbox.ps1 logs -Lane lane-x -Id <job id printed by sync>
./scripts/buildbox.ps1 fetch -Lane lane-x -Id <job id> -Dest D:\tmp\lane-x-results
./scripts/buildbox.ps1 gc -Yes
./scripts/buildbox.ps1 stop -Yes
```

- `sync` tars the worktree INCLUDING `.git` but excluding `target/`, `node_modules/`, `.terraform/`, `*.tfstate*`,
  `.env`, `*.pem` and credential-looking files (the list is printed) and uploads it as `jobs/<lane>/<id>.tar.gz`. It
  prints the job id and remembers it per lane, so `run` without `-Id` uses the last sync.
- `run` sends one SSM command (`AWS-RunShellScript`, this instance only). On the box the runner script extracts into
  `/work/<lane>/<job>`, exports `CARGO_TARGET_DIR=/work/target/<lane>` (warm cache per lane), installs the toolchain pinned
  by the repo `rust-toolchain.toml`, takes one of at most 3 slots, runs your command and uploads `combined.log`,
  `exit-code` and `result.json` to `out/<lane>/<id>/`. `-NoWait` returns right after sending.
- `--offline` needs a warm cargo registry: do one run without it (for example `cargo fetch`) per lane the first time.
- A Postgres for tests: start one inside the job, for example `docker run -d --rm -p 5432:5432 -e POSTGRES_PASSWORD=test postgres:16`.

## Limits

- At most 3 concurrent jobs per box; others wait for a slot (up to the job timeout). Use `-j 2`.
- Linux only. Windows-specific tests (Pester, console-event signals, `demo-magic.ps1`) must still run locally.
- The work volume is 100 GB; `gc` removes old work dirs but keeps the cargo registry and target caches.
- Objects in the bucket expire after 7 days.

## Remove everything

```powershell
./scripts/buildbox.ps1 down -AdminProfile <admin profile>
./scripts/buildbox.ps1 verify-gone
```

`down` runs `terraform destroy` of `terraform/envs/buildbox` with the admin profile you pass, shows the plan and needs the
typed word `DESTROY` (`-Yes` does not skip it). The IAM user is force-destroyed even if you created an access key. The
equivalent by hand is `terraform -chdir=terraform/envs/buildbox destroy`. `verify-gone` fails if any resource tagged
`Purpose=buildbox` remains in us-east-1 or the bucket still exists (the tagging API can list a terminated instance for a
short while: retry in a few minutes).

## Troubleshooting

- `No buildbox instance found`: the root was not applied (step 1) or you use the wrong profile or account.
- `did not become SSM online`: first boot is still installing, or the box has no outbound internet (default VPC without
  an internet gateway route). Retry `up` after a few minutes; the log is `/var/log/buildbox-init.log` on the box.
- `AccessDenied`: the scoped user can only start/stop the tagged instance, send commands to it and use the bucket.
- A run fails with `Failed`: read `buildbox.ps1 logs`; `exit-code` and `result.json` hold the details.
- The box stopped during a long idle wait: run `up` again; caches on `/work` survive stop/start.
- The scoped policy JSON is the output `user_policy_json` of the root if it must be attached elsewhere.
