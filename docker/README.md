# KoboldOS Docker Deployment

This guide explains how to deploy KoboldOS using Docker with integrated Web GUI.

## Prerequisites

- Docker installed on your system
- Docker Compose (optional but recommended)

## Building the Image

From the root of the KoboldOS repository:

```bash
docker build -t koboldos -f docker/Dockerfile .
```

## Running with Docker

### Basic Usage

```bash
docker run -d \
  --name koboldos \
  -p 8080:8080 \
  -p 8081:8081 \
  -e PORT=8080 \
  -e WEB_PORT=8081 \
  -e AUTH_TOKEN=your-secret-token \
  -e USERNAME=admin \
  -e PASSWORD=admin \
  koboldos
```

### With Docker Compose

```bash
docker-compose -f docker/docker-compose.yml up -d
```

This will start both KoboldOS with Web GUI and Ollama services.

## Environment Variables

- `PORT`: Port to run the daemon on (default: 8080)
- `WEB_PORT`: Port to run the Web GUI on (default: 8081)
- `AUTH_TOKEN`: Authentication token for the API (default: kobold-secret)
- `USERNAME`: Username for Web GUI authentication (default: admin)
- `PASSWORD`: Password for Web GUI authentication (default: admin)

## Accessing the Web GUI

Once running, the Web GUI will be available at `http://localhost:8081`
Default credentials: admin / admin

## Accessing the API

The API will be available at `http://localhost:8080`

### Health Check
```bash
curl http://localhost:8080/health
```

### Agent Endpoint
```bash
curl -X POST http://localhost:8080/agent \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello, world!", "agent_type": "general"}'
```

## Persistent Storage

To persist data between container restarts, uncomment the volume mount in docker-compose.yml:

```yaml
volumes:
  - ./data:/home/kobold/.local/share/KoboldOS
```

## Updating the Image

To update to the latest version:

```bash
docker-compose -f docker/docker-compose.yml down
docker-compose -f docker/docker-compose.yml up -d --build
```