# Database bootstrap (hackathon single-host profile)

One RDS PostgreSQL 16 instance (module `hackathon_data`) holds three databases. Terraform creates the instance only: the
postgres provider needs network reachability, and the instance is in isolated subnets. Databases and roles are created
from the host (SSM Session Manager shell, `psql`) with the scripts in `terraform/modules/hackathon_data/sql/`.

| Database | Roles | Created by |
|---|---|---|
| `core_runtime` | `core_owner` (migrations), `core_app` (DML), `core_exporter_ro` (read only) | `00`, `10`, then `agentcore migrate` |
| `core_eval` | `core_owner`, `core_eval_app`, `core_exporter_ro` | `00`, `10`, then `agentcore migrate` |
| `pulso` | `pulso_app`, `pulso_loader`, `pulso_raw_ro`, `pulso_augmented_ro`, `pulso_product_ro` (schemas `raw`, `augmented`, `product`, `pulso`) | `00`, engine `db/sql/001..090`, `30` |

Core roles follow ADR 0003 (one instance, two logical databases). The `pulso` database follows the engine design
(`db/README.md`, `db/sql/*.sql`): the engine SQL creates the schemas, the NOLOGIN roles and the column-level grants; `30`
only enables login. Do not edit the engine's generated SQL here.

## Passwords

All role passwords and the master password live in the one Secrets Manager secret `<name_prefix>/hackathon` (JSON).
Terraform generates `RDS_MASTER_PASSWORD` and every `DB_PASSWORD_*` key, and assembles the DSNs from them
([secrets-wiring](secrets-wiring.md)); nobody types a password. Never paste a password in a command line or a
ticket. The scripts read passwords from environment variables via psql `\getenv`.

## Run (on the host, by a human, after applying a reviewed plan)

```sh
SECRET=$(aws secretsmanager get-secret-value --secret-id <name_prefix>/hackathon --query SecretString --output text)
export PGHOST=<db_endpoint> PGPORT=5432 PGUSER=pulso_master PGSSLMODE=require
export PGPASSWORD=$(echo "$SECRET" | jq -r .RDS_MASTER_PASSWORD)
for k in CORE_OWNER CORE_APP CORE_EVAL_APP CORE_EXPORTER_RO PULSO_APP PULSO_LOADER PULSO_RAW_RO PULSO_AUGMENTED_RO PULSO_PRODUCT_RO; do
  export DB_PASSWORD_$k=$(echo "$SECRET" | jq -r .DB_PASSWORD_$k); done
psql -d postgres     -f sql/00_databases_roles.sql
psql -d core_runtime -v app_role=core_app      -f sql/10_core_grants.sql
psql -d core_eval    -v app_role=core_eval_app -f sql/10_core_grants.sql
for f in 001_roles_schemas 010_raw 020_augmented 030_product 090_grants; do psql -d pulso -f <engine>/db/sql/$f.sql; done
psql -d pulso        -f sql/30_pulso_logins.sql
# then Core's idempotent migration (agentcore migrate, as core_owner); re-run 10_core_grants.sql if needed
```

Then compose the DSNs (`postgresql://core_app:<pw>@<db_endpoint>:5432/core_runtime?sslmode=require`, and so on) and write
them to the secret keys `CORE__AGENTCORE_REGISTRY_DSN`, `CORE__AGENTCORE_EVAL_DSN`, `SUPPORT__CC_DATABASE_URL`, `PULSO__PULSO_DATABASE_URL`.

## Limits (not verified)

The scripts were not run against a live PostgreSQL; they were reviewed by reading only. `\getenv` needs psql 15 or newer.
The RDS master is not a superuser; `GRANT core_owner TO CURRENT_USER` is what lets it create databases owned by
`core_owner`. TLS is forced by the parameter group (`rds.force_ssl=1`). Rotating the master password out of band makes
the `RDS_MASTER_PASSWORD` key and the instance diverge from Terraform state; Terraform does not manage the live value.
