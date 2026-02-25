#!/bin/bash

# Comprehensive Linux build script for KoboldOS with Web GUI support

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Building KoboldOS for Linux with Web GUI support${NC}"
echo -e "${BLUE}===============================================${NC}"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}🔍 Checking prerequisites...${NC}"

# Check if Swift is installed
if ! command_exists swift; then
    echo -e "${RED}❌ Error: Swift is not installed. Please install Swift 5.10 or later.${NC}"
    echo "You can install Swift on Ubuntu with:"
    echo "  wget https://download.swift.org/swift-5.10-release/ubuntu2004/swift-5.10-RELEASE/swift-5.10-RELEASE-ubuntu20.04.tar.gz"
    echo "  tar xzf swift-5.10-RELEASE-ubuntu20.04.tar.gz"
    echo "  sudo mv swift-5.10-RELEASE-ubuntu20.04 /usr/share/swift"
    echo "  echo 'export PATH=\"/usr/share/swift/usr/bin:\$PATH\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
    exit 1
fi

# Check Swift version
SWIFT_VERSION=$(swift --version | head -n 1)
echo -e "${GREEN}✅ Swift found: ${SWIFT_VERSION}${NC}"

# Check if we're in the right directory
if [ ! -f "Package.swift" ]; then
    echo -e "${RED}❌ Error: Package.swift not found. Please run this script from the KoboldOS root directory.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Running from correct directory${NC}"

# Clean previous builds if requested
if [ "$1" = "clean" ]; then
    echo -e "${YELLOW}🧹 Cleaning previous builds...${NC}"
    rm -rf .build .build-linux
    echo -e "${GREEN}✅ Clean completed${NC}"
fi

# Create build directory
BUILD_DIR=".build-linux"
echo -e "${YELLOW}📂 Creating build directory: $BUILD_DIR${NC}"
mkdir -p "$BUILD_DIR"

# Resolve dependencies
echo -e "${YELLOW}📥 Resolving dependencies...${NC}"
swift package resolve

# Build with Web GUI support
echo -e "${YELLOW}🔨 Building KoboldOS with Web GUI support...${NC}"
swift build -c release -Xswiftc -DWEB_GUI --product kobold

# Check if build was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Build completed successfully!${NC}"
    echo -e "${BLUE}📦 Executable location: .build/release/kobold${NC}"

    # Show file info
    if [ -f ".build/release/kobold" ]; then
        SIZE=$(du -h ".build/release/kobold" | cut -f1)
        echo -e "${BLUE}📊 Binary size: ${SIZE}${NC}"
    fi

    echo ""
    echo -e "${GREEN}🚀 How to run KoboldOS:${NC}"
    echo -e "${BLUE}1. Run as daemon:${NC}"
    echo "   .build/release/kobold daemon --port 8080 --token your-secret-token"
    echo ""
    echo -e "${BLUE}2. Run with Web GUI:${NC}"
    echo "   .build/release/kobold web --port 8080 --web-port 8081 --username admin --password admin --token your-secret-token"
    echo ""
    echo -e "${BLUE}3. See all available commands:${NC}"
    echo "   .build/release/kobold --help"
    echo ""
    echo -e "${GREEN}🌐 Web GUI will be accessible at: http://localhost:8081${NC}"
    echo -e "${GREEN}🔐 Default credentials: admin / admin${NC}"
    echo -e "${GREEN}🔧 API endpoint: http://localhost:8080${NC}"

else
    echo -e "${RED}❌ Build failed.${NC}"
    exit 1
fi