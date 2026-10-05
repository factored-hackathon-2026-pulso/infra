# 0020 agent-core serve with its seven real pieces

- Why: agent-core main (PR #42, #38) ships the real transcript (Postgres, same database), calibration and classifier
  (artifact directories, `AGENTCORE_CALIBRATION_DIR` and `AGENTCORE_CLASSIFIER_ARTIFACTS_DIR`) and moves the field
  classifier to `agent_core.composition.classification`.
- What: `agent_serve_args` defaults to the seven real pieces; `compose.agents.yaml` mounts `/srv/data/agent/artifacts`
  read-only and points both directories there; the core start script mirrors `s3://<bucket>/core/artifacts/
  {calibrations,classifiers}/` when agent-core is on the host; the core role reads `core/artifacts/*`; runbook and
  `prod.tfvars.example` updated. Transcript needs no infra (its table comes from `agentcore migrate`).
- TDD: new runs in `modules/hackathon_compute/agent_services.tftest.hcl`, `envs/hackathon/agent_services.tftest.hcl`
  and `tests/test_agent_services_contract.py`, red first, then green; terraform test hackathon_compute 33, hackathon_iam 18, envs/hackathon 24 passed; `python -m unittest discover -s tests` 214 OK (1 skipped); rendered core prepare.sh passes `bash -n`.
- Not verified: nothing applied; no real artifacts exist yet (agent-core TEMAS-ABIERTOS, unit 6).
