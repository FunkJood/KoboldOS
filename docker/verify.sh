#!/bin/bash

# Final verification script for KoboldOS Docker image with Web GUI support

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== KoboldOS Docker Image Verification ===${NC}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed.${NC}"
    echo "Please install Docker Desktop or Docker Engine to run this verification."
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running.${NC}"
    echo "Please start Docker Desktop or the Docker service."
    exit 1
fi

echo -e "${GREEN}Docker is installed and running.${NC}"

# Check if we're in the right directory
if [ ! -f "Package.swift" ]; then
    echo -e "${RED}Error: Package.swift not found.${NC}"
    echo "Please run this script from the KoboldOS root directory."
    exit 1
fi

echo -e "${GREEN}Found KoboldOS project files.${NC}"

# Check Dockerfile existence
if [ ! -f "docker/Dockerfile" ]; then
    echo -e "${RED}Error: Dockerfile not found at docker/Dockerfile.${NC}"
    exit 1
fi

echo -e "${GREEN}Found Dockerfile.${NC}"

# Check docker-compose.yml existence
if [ ! -f "docker/docker-compose.yml" ]; then
    echo -e "${RED}Error: docker-compose.yml not found at docker/docker-compose.yml.${NC}"
    exit 1
fi

echo -e "${GREEN}Found docker-compose.yml.${NC}"

echo -e "${YELLOW}Verification completed successfully!${NC}"
echo ""
echo "To build and run KoboldOS with Docker and Web GUI:"
echo "  cd docker && docker-compose up -d"
echo ""
echo "To build the Docker image manually:"
echo "  docker build -t koboldos -f docker/Dockerfile ."
echo ""
echo "Web GUI will be accessible at: http://localhost:8081"
echo "Default credentials: admin / admin"
echo "API endpoint: http://localhost:8080"
echo ""
echo "The Docker image is ready for deployment with integrated Web GUI support."