# hackathon environment

Cheap single-host demo: network, data, iam, compute (one EC2 in a private subnet, one NAT) and edge
(CloudFront with VPC origin and WAF). Modules `hackathon_network|iam|edge|data` (compute is instantiated three times: core, platform, engine) may be stubs until lane A/B
are merged. Nothing here is applied without authorization; see `docs/hackathon-deploy.md` for the order.

```powershell
terraform -chdir=terraform/envs/hackathon init -backend=false
terraform -chdir=terraform/envs/hackathon validate
terraform -chdir=terraform/envs/hackathon test
```

Real runs: `terraform init -backend-config=backend.hcl` (copy `backend.hcl.example` outside Git), then a tfvars
file with `ecr_registry_url` and `images` (digests). Kill switch: `-var enabled=false` (stops the instance).
