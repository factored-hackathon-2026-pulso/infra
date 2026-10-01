# I01 — PostgreSQL aislado reutilizable en CI

## Alcance entregado

`.github/workflows/postgres-integration.yml` es un workflow reutilizable con
`workflow_call`. Al ser invocado desde `improvement-engine`, hace checkout del
repositorio llamador y corre el único gate explícito de U02:

```text
cargo +1.98.1 test --locked --package improvement-engine-core --test postgres_artifact_migration -- --ignored
```

El job usa una instancia PostgreSQL 17 Alpine con digest fijado, un nombre de
base/usuario de prueba y una contraseña no secreta, limitada a la red efímera
del service container de GitHub Actions. `PULSO_ALLOW_DESTRUCTIVE_TEST_DB=1`
y la URL sólo viven en el job. El workflow pide únicamente `contents: read`,
no recibe `secrets`, no acepta un comando del llamador y falla el job si la
migración o la prueba fallan.

## Límites deliberados

Este slice no despliega AWS, no aplica Terraform, no crea recursos pagos, no
contiene datos del banco y no cambia `improvement-engine`. El consumidor debe
referenciar el workflow por SHA desde su propia CI; esa integración pertenece
al cambio de U02, no a este repositorio. Antes de la primera invocación hay que
habilitar o confirmar, en los Actions settings de `infra`, el acceso de
`improvement-engine` al reusable workflow privado. La CI del caller será la
evidencia de que la frontera cross-repo y el test real funcionan; los tests de
este repositorio no pueden probarla por sí solos.

El desarrollo local sigue siendo Windows-first. La ejecución local de
contenedores Podman está sin verificar por la incompatibilidad de cgroups de
la VM actual; el workflow de GitHub Actions no se presenta como evidencia de
que dicha ruta local funciona. El test remoto usa el service container aislado
de GitHub, no LocalStack ni una base compartida.

## Evidencia de TDD

1. `tests/test_postgres_integration_workflow.py` fue introducido antes del
   workflow: falló porque el archivo no existía.
2. Una vez creado, comprueba activación reutilizable, permisos mínimos,
   imagen fijada, health check, URL/consentimiento aislados, comando exacto
   con lockfile, y ausencia de secretos, AWS, Terraform o producción.
3. Ejecutar `python -m unittest discover -s tests -v` valida los contratos
   estáticos de este repositorio. La evidencia de ejecutar el gate contra el
   servicio real llegará en la CI del repositorio llamador; local green no es
   evidencia de GitHub Actions.
4. Como guardia de compilación del comando fijado, en el checkout U02 se
   ejecutó `cargo +1.98.1 test --locked --package improvement-engine-core
   --test postgres_artifact_migration`. Compiló con el lockfile y dejó una
   prueba ignorada como se espera, sin URL ni consentimiento destructivo. No
   equivale a ejecutar la migración: la prueba real sigue reservada al job
   PostgreSQL efímero del caller.
