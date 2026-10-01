# I04 — legacy local asset migration inventory

`infra` is Terraform/AWS deployment infrastructure. It is **not authoritative**
for local development, engine fixtures, Podman Compose, LocalStack, PostgreSQL
integration tests, or an engine doctor.

The pre-existing `local/` profiles and `scripts/doctor.py` remain temporarily
as a migration inventory only. Their contents must not be extended, invoked by
infra CI, or presented as an AWS deployment readiness check. The canonical
owner is `pulso-factored/improvement-engine`, where I03 established the
engine-local test and development boundary.

Do not add Compose files, container test workflows, fixture data, an engine
doctor, or a reusable engine-test workflow to this repository. A future
cleanup PR may remove inventory assets only after it verifies the replacement
in `improvement-engine`; this baseline intentionally makes no such claim.

The former `postgres-integration.yml` reusable workflow has been removed:
an `infra` PR cannot validate an `improvement-engine` migration and must not
require a cross-repository Actions permission or pinned foreign workflow SHA.
