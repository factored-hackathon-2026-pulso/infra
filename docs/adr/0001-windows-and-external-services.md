# Windows-first and external boundaries

Windows/PowerShell is the initial developer host. Podman may use its Linux VM; do not move development to WSL automatically. Infrastructure belongs here; improvement-engine owns detection/improvement. Agent Core and model routing are external dependencies, not products to implement. Missing services are explicit failures.
