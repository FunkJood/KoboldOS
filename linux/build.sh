#!/bin/bash

# Linux build script for KoboldOS

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building KoboldOS for Linux...${NC}"

# Check if Swift is installed
if ! command -v swift &> /dev/null; then
    echo -e "${RED}Error: Swift is not installed. Please install Swift 5.10 or later.${NC}"
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "Package.swift" ]; then
    echo -e "${RED}Error: Package.swift not found. Please run this script from the KoboldOS root directory.${NC}"
    exit 1
fi

# Create build directory
BUILD_DIR=".build-linux"
echo -e "${YELLOW}Creating build directory: $BUILD_DIR${NC}"
mkdir -p "$BUILD_DIR"

# Resolve dependencies
echo -e "${YELLOW}Resolving dependencies...${NC}"
swift package resolve

# Build the CLI executable with Web GUI support
echo -e "${YELLOW}Building kobold CLI with Web GUI support...${NC}"
swift build -c release -Xswiftc -DWEB_GUI

# Show build results
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${YELLOW}Executable location: .build/release/kobold${NC}"

# Show usage
echo ""
echo "To run KoboldOS daemon:"
echo "  .build/release/kobold daemon --port 8080 --token your-secret-token"
echo ""
echo "To run KoboldOS with Web GUI:"
echo "  .build/release/kobold web --port 8080 --web-port 8081 --username admin --password admin --token your-secret-token"
echo ""
echo "To see all available commands:"
echo "  .build/release/kobold --help"