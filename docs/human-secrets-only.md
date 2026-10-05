# What the human provides: external provider keys only

Everything else is wired ([secrets-wiring](secrets-wiring.md)). After the apply, the only secret keys still holding `CHANGE_ME` are these. Names only; never paste a value into chat, Git or a command line.

| Secret key | Provider and where to get it | Needed for |
|---|---|---|
| `GATEWAY__OPENROUTER_API_KEY` | OpenRouter account, Settings, Keys | every model call |
| `GATEWAY__JEV_API_KEY` | JEV provider account (the same key is also written to `AGENT__AGENTCORE_JEV_API_KEY` by the script; agent-core serve does not start without it) | agent-core serve, `/v1/jev` |
| `LANGFUSE__LANGFUSE_PUBLIC_KEY`, `LANGFUSE__LANGFUSE_SECRET_KEY` | Langfuse project (US cloud), Settings, API keys. OPTIONAL: only with `otlp_forwarder_enabled` | tracing |

How to set (one key at a time; the value is typed hidden, nothing is echoed, logged or written to the repository; the script asks for the word SET):

```powershell
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey GATEWAY__OPENROUTER_API_KEY
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey GATEWAY__JEV_API_KEY
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey LANGFUSE__LANGFUSE_PUBLIC_KEY   # optional
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey LANGFUSE__LANGFUSE_SECRET_KEY   # optional
```

Check (names and SET/UNSET only): `.\scripts\aws-prod.ps1 status -Profile pulso-prod`. It lists the human keys still unset and, separately, any wired key still unset (that would mean `seed-secret-keys` is needed on a secret created before the wiring). Hosts read a new value at the next `pulso-stack` restart or deploy.

Anything else that asks for a typed value is a defect of the wiring: report it.
