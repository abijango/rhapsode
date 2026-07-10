# Multi-stage build for rhapsode-server
FROM rust:1-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/rhapsode-server /usr/local/bin/rhapsode-server
ENV RHAPSODE_DATA_DIR=/data \
    RHAPSODE_LIBRARY_AUDIO=/library/audio \
    RHAPSODE_LIBRARY_EBOOK=/library/ebook \
    RHAPSODE_BIND=0.0.0.0:8080 \
    RHAPSODE_LOG=info
EXPOSE 8080
# Compose sets user: "1026:100" to match Synology PUID/PGID
ENTRYPOINT ["/usr/local/bin/rhapsode-server"]
