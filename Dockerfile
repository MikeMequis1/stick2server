# syntax=docker/dockerfile:1

FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
RUN dart build cli -o /app/build -t bin/server.dart

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /app /data \
    && useradd --uid 10001 --home-dir /app --shell /usr/sbin/nologin planner \
    && chown -R planner:planner /data /app
COPY --from=build /app/build/bundle /app
USER planner
ENV PORT=8090 DB_PATH=/data/planner-server.sqlite
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8090/v1/health || exit 1
ENTRYPOINT ["/app/bin/server"]
