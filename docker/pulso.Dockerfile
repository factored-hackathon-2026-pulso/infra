# TEMPLATE. The engine repo owns the real Dockerfile; use this one only when the engine repo has none.
# Multi-stage Rust build, non-root, read-only-rootfs friendly (writes only to /tmp, which the ECS task mounts
# as a volume). Build context = the ENGINE repo root. Adjust BIN and the console path if they differ.
FROM rust:1-bookworm AS build
WORKDIR /src
COPY . .
ARG BIN=pulso
RUN cargo build --release --locked --bin ${BIN}

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin pulso
ARG BIN=pulso
COPY --from=build /src/target/release/${BIN} /usr/local/bin/pulso
# Static console build (served from the console/ prefix or by pulso). Fails the build if the dist is missing.
COPY --from=build /src/debug-console/dist /opt/pulso/console
USER 10001:10001
ENV TMPDIR=/tmp
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/pulso"]
