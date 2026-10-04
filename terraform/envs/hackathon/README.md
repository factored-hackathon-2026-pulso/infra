# hackathon environment

Cheap demo: network, data, iam, three compute hosts (core, platform, engine; private subnets, one NAT) and edge
(CloudFront with VPC origins and WAF), all real modules. Nothing here is applied without authorization; see `docs/hackathon-deploy.md` for the order.

```powershell
terraform -chdir=terraform/envs/hackathon init -backend=false
terraform -chdir=terraform/envs/hackathon validate
terraform -chdir=terraform/envs/hackathon test
```

Real runs: `terraform init -backend-config=backend.hcl` (copy `backend.hcl.example` outside Git), then a tfvars
file with `region`, `cloudfront_waf_region` (must be N. Virginia), `ecr_registry_url` and `images` (digests); optional `uploader_principal_arns`, `loader_role_arns`, `break_glass_principal_arns`, `enable_waf`. Kill switch: `-var enabled=false` (stops the instance).
