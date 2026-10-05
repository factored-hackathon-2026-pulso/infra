# 0021 agent services: FX table, staff keys for the registry CLI, registry seed

- Why: agent-core now serves its own tools (`convertir_moneda` reads a fixed table from `AGENTCORE_FX_RATES_FILE`) and
  its registry CLI verifies a real admin credential with the staff keys (`AGENTCORE_STAFF_KEYS_FILE`); the seed of
  agents must reach the core host.
- What: `FILES__AGENT__FX_RATES` secret key and `AGENTCORE_FX_RATES_FILE`, `AGENTCORE_STAFF_KEYS_FILE` in
  `compose.agents.yaml`; the start script also mirrors `core/artifacts/registry-seed/`; runbook "Loading the agents".
- TDD: red then green in `tests/test_agent_services_contract.py`, `modules/hackathon_data/agent_services.tftest.hcl`,
  `modules/hackathon_compute/agent_services.tftest.hcl`; compute 33, data 23, envs/hackathon 24 passed; python unittest 215 OK (1 skipped); rendered core prepare.sh passes `bash -n`.
- Not verified: nothing applied; the import procedure was not run against a deployed stack.
