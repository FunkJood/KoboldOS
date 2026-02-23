# Multi-stage build for KoboldOS Docker image
FROM swift:6.0-focal AS builder

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy Swift package files
COPY docker/Package.swift ./Package.swift
COPY Sources ./Sources

# Build the app with Web GUI support
RUN swift build -c release -Xswiftc -DWEB_GUI

# Runtime stage
FROM ubuntu:focal AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    libcurl4 \
    libssl1.1 \
    libxml2 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --create-home --shell /bin/bash kobold

# Copy built executable from builder stage
COPY --from=builder /app/.build/release/kobold /usr/local/bin/kobold

# Switch to non-root user
USER kobold
WORKDIR /home/kobold

# Expose default ports
EXPOSE 8080
EXPOSE 8081

# Define environment variables with defaults
ENV PORT=8080
ENV WEB_PORT=8081
ENV AUTH_TOKEN=kobold-secret
ENV USERNAME=admin
ENV PASSWORD=admin

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Entry point - run with Web GUI by default
ENTRYPOINT ["kobold", "web", "--port", "${PORT}", "--web-port", "${WEB_PORT}", "--username", "${USERNAME}", "--password", "${PASSWORD}", "--token", "${AUTH_TOKEN}"]