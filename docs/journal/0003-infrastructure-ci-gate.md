# I01 — gate propio de contratos de infraestructura

## Alcance entregado

`.github/workflows/ci.yml` es el gate remoto propio de `infra`. Se ejecuta en
pull requests y en pushes a `main`, corre la suite portable de contratos de
Python en `windows-latest` y `ubuntu-latest`, y cancela ejecuciones antiguas
del mismo workflow/ref. El checkout está fijado por SHA, no conserva
credenciales y el workflow declara solamente `contents: read`.

No recibe ni lee secretos. Tampoco ejecuta Podman, PostgreSQL, LocalStack,
Terraform ni despliegues: esos límites son intencionales. La ruta PostgreSQL
real sigue siendo el workflow reutilizable de I01 y únicamente quedará
certificada cuando `improvement-engine` lo invoque desde su propia CI.

## Evidencia TDD

1. Se añadió `tests/test_infrastructure_ci_workflow.py` antes de modificar el
   workflow. Falló porque el nombre estable `infrastructure-ci` aún no existía
   (`bootstrap-ci` era el valor heredado).
2. Se renombró el gate, su grupo de concurrencia, job y paso para reflejar su
   contrato actual, sin ampliar permisos ni cambiar el comando probado.
3. `python -m unittest tests.test_infrastructure_ci_workflow -v` pasó con los
   dos comportamientos: activación/matriz/comando y límites de seguridad.
4. `python -m unittest discover -s tests -v` pasó con 7 pruebas. Es evidencia
   local del contrato textual; el estado de GitHub Actions se verificará sobre
   el commit publicado de la PR.
