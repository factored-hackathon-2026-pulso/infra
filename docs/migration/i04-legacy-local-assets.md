# I04 — legacy local asset migration inventory

`infra` is Terraform/AWS deployment infrastructure. It is **not authoritative**
for local development, engine fixtures, Podman Compose, LocalStack, PostgreSQL
integration tests, or an engine doctor.

The pre-existing `local/` profiles and `scripts/doctor.py` were removed in I06
after verifying they had no infra CI/Terraform consumer. Their removal does not
claim a like-for-like replacement in `improvement-engine`; see the exact
evidence and boundary in [I06 removal](i06-legacy-local-removal.md).

Do not add Compose files, container test workflows, fixture data, an engine
doctor, or a reusable engine-test workflow to this repository.

The former `postgres-integration.yml` reusable workflow has been removed:
an `infra` PR cannot validate an `improvement-engine` migration and must not
require a cross-repository Actions permission or pinned foreign workflow SHA.
