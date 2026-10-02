# Pulso infra — agent contract

Read CONTEXT.md and relevant docs/adr before changing code. Windows/PowerShell first. This repo owns Terraform/AWS deployment infrastructure for improvement-engine and for running Agent Core as a deployed workload (ADR 0003). It does not own either service's local environment, Agent Core's code, image build, schema, migrations or runtime behavior, or an LLM gateway.

## Development discipline

- Work on feature branches and isolated worktrees. Small PRs; no routine main writes or force pushes.
- Vertical TDD: one observable test RED, minimal GREEN, refactor. Record exact commands/results in docs/journal with each slice.
- Prefer real dependencies; mocks only at external boundaries. No AWS apply, public exposure or paid model calls without scoped authorization.
- Independent adversarial review closes each slice. Do not claim a dependency, cloud deployment or security control is working from a stub or structural check.
- No data, credentials, Terraform state, logs or private prompts in Git. Do not mutate bank source files.
- Documentation is sliced with code: explain current behavior, limitations and reproduction; do not prewrite implementation claims.

## Verified commands

Bootstrap tests: `python -m unittest discover -s tests -v`. Terraform CI also runs fmt and credential-free init/validate for every environment. These checks do not certify AWS or authorize an apply. Subsequent slice docs must add commands only after verifying them.

## Agent skills

### Issue tracker

GitHub Issues in pulso-factored/infra. See docs/agents/issue-tracker.md.

### Triage labels

Five canonical labels, mapped in docs/agents/triage-labels.md.

### Domain docs

Single context CONTEXT.md and docs/adr/. See docs/agents/domain.md.
