# Stage 1: Build hashed React 19 + Inertia v2 + Vite assets into public/
FROM node:22-alpine AS frontend
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# Stage 2: Minimal pure-Mo production runtime (zero Node, zero SQLite, zero Redis)
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*

# Note: expects mo binary on host build or copy from official mo release image
ARG MO_BIN=/usr/local/bin/mo
WORKDIR /app
COPY . /app
COPY --from=frontend /app/public /app/public
RUN mkdir -p /var/lib/vellum

ENV MO_BIND=0.0.0.0
ENV MO_PORT=8080
VOLUME ["/var/lib/vellum"]
EXPOSE 8080

CMD ["sh", "-c", "mkdir -p /var/lib/vellum && rm -rf /var/lib/vellum/public && cp -r /app/public /var/lib/vellum/public && exec mo serve /app/main.mo --bind 0.0.0.0 --port 8080 --workers 4 --data /var/lib/vellum"]
