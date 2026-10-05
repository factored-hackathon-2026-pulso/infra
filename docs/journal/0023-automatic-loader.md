# 0023 Automatic data loader on the engine host (option A)

- Why: user decision 2026-10-05: data loading runs automatically in AWS; `engine_host_can_load` defaults to false.
- What: `auto_loader_enabled` (default off): dedicated loader role assumable only by the engine host role (ExternalId), systemd
  timer + one-shot on the engine host (marker `engine/inbox/READY.json`, idempotent by sha256, STS credentials in a 0600 tmpfs file,
  bounded pipeline container, k>=10 gate before publication, status/failed marker), swap and a c7i-flex.large default engine type.
  `docs/auto-loader.md`; ask to the data-pipeline owners in reports-claude/ASKS.
- Tests: `tests/test_auto_loader_contract.py`; tftests in hackathon_iam (loader_role), hackathon_data (auto_loader),
  hackathon_compute (agent_services), envs/hackathon (loader). Results in the PR description.
- Not verified: nothing applied or run on a host; pipeline contracts and memory fit unmeasured; the host can assume the role (residual risk).
