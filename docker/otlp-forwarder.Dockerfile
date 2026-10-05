# OTLP forwarder (the single egress to Langfuse Cloud). The engine repo owns the code (scripts/o11y/otlp_forwarder.py);
# this recipe only packages it, because the engine repo has no Dockerfile for it. Build context = the ENGINE repo root:
#   podman build --format docker --platform linux/amd64 -f docker/otlp-forwarder.Dockerfile -t otlp-forwarder:local <engine repo>
# The forwarder listens on 127.0.0.1 ONLY (no bind option), so on a host it runs as a sidecar in the network namespace of its
# producer (deploy/hackathon/core/compose.observability.yaml, network_mode: service:<producer>). Python standard library only.
# Credentials (LANGFUSE_BASE_URL, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY) arrive in the environment at run time, never here.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm
FROM ${PYTHON_IMAGE}
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin forwarder
# The layout is kept: runtrace_bridge.py puts ../triggers on sys.path for agentcore_poller.
COPY scripts/o11y/otlp_forwarder.py scripts/o11y/runtrace_bridge.py scripts/o11y/trace_id.py /opt/pulso/scripts/o11y/
COPY scripts/triggers/agentcore_poller.py /opt/pulso/scripts/triggers/agentcore_poller.py
USER 10001:10001
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PULSO_O11Y_ALLOW_EXTERNAL=1
EXPOSE 4318
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:4318/healthz', timeout=2)"]
ENTRYPOINT ["python", "/opt/pulso/scripts/o11y/otlp_forwarder.py", "--port", "4318"]
