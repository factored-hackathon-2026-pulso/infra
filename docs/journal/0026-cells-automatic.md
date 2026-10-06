# 0026 Bank cells are produced by the loader (lane CELLS-AUTO)

- Why: user decision 2026-10-05, the AWS deployment is automatic from uploaded data to the engine's input cells with no human step. INFRA-D
  found `loader_cells_cmd` empty and `bank_cells.py` in no image, so a human had to produce and upload `engine/inputs/cells.ndjson`.
- What: `deploy/hackathon/engine/loader/run-bank-cells.sh` is the default `loader_cells_cmd` (bundled, installed to
  `/usr/local/lib/pulso-loader/`). It syncs only the six tables and two reference files `bank_cells.py` reads from `landing/bank/` with the
  loader role, runs the engine image's `/opt/pulso/aggregate/bank_cells.py` in a container with no network and no credentials, and writes
  `$CELLS_OUT`. `pulso-loader.sh`: gate (`check_cells_k.py`) before anything is published, cells staged at `bank_cells/<run>/`, the loader
  role assumed again before the pipeline (chained sessions last one hour), `bank_cells/latest.json` moved last after the pipeline, failures
  name the step in `engine/loader/status/last.json`. The engine host's existing inputs mirror already reads `bank_cells/latest.json` (sha256
  plus second k gate), so `PULSO_LOOP_INPUTS_DIR/cells.ndjson` needs no change.
- Choice: engine image over pipeline image (the aggregator is the engine's, the image is already on the host, no cross-team PR); `landing/`
  CSV over the pipeline's silver/gold (names, quarantine and pseudonymised ids differ from the validated aggregator); see `docs/auto-loader.md`.
- E0: the opbench `e0-export` is a research exporter, not a loop input; nothing to automate for the bank loop.
- Tests: `tests/test_cells_auto_contract.py` (offline bash with fake aws/docker: happy path, reuse by run key, wrong sha, missing table,
  k < 10, aggregator failure, ordering in the loader, wiring) and `tests/test_auto_loader_contract.py`; `loader.tftest.hcl` assertion
  updated (not run: no terraform here).
- Not verified: no terraform command, no AWS, never run on real data; duration, memory and disk of the aggregation on EC2 are the
  laptop's figures; needs the engine image from engine PRs 130 (python3) and the cells-auto PR (`bank_cells.py` in the image).
- Interaction: PR 48 also edits `pulso-loader.sh` (dataset prefix with a trailing slash) in a different hunk; the producer normalises the
  prefix itself.
