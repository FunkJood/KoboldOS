# KoboldOS Linux Cross-Compilation Guide

This document explains how to properly cross-compile KoboldOS for Linux x86_64 systems.

## Supported Platforms

- Ubuntu 20.04+ (Focal Fossa and later)
- Debian 11+ (Bullseye and later)
- CentOS/RHEL 8+
- Other Linux distributions with Swift 5.10+ support

## Prerequisites

### Swift Installation

For Ubuntu/Debian:
```bash
# Download Swift 5.10
wget https://download.swift.org/swift-5.10-release/ubuntu2004/swift-5.10-RELEASE/swift-5.10-RELEASE-ubuntu20.04.tar.gz

# Extract and install
tar xzf swift-5.10-RELEASE-ubuntu20.04.tar.gz
sudo mv swift-5.10-RELEASE-ubuntu20.04 /usr/share/swift

# Add to PATH
echo 'export PATH="/usr/share/swift/usr/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### System Dependencies

Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install -y \
    curl \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsqlite3-dev \
    build-essential
```

CentOS/RHEL:
```bash
sudo yum update
sudo yum groupinstall -y "Development Tools"
sudo yum install -y \
    curl-devel \
    openssl-devel \
    libxml2-devel \
    sqlite-devel
```

## Cross-Compilation Settings

### Target Triple

For Linux x86_64, use the target triple: `x86_64-unknown-linux-gnu`

### Compiler Flags

When building with Swift Package Manager, use these flags:

```bash
# Enable Web GUI support
swift build -c release -Xswiftc -DWEB_GUI

# Specify target explicitly (optional)
swift build -c release -Xswiftc -target -Xswiftc x86_64-unknown-linux-gnu
```

## Conditional Compilation

KoboldOS uses conditional compilation for platform-specific features:

- `#if os(Linux)` - Linux-specific code
- `#if WEB_GUI` - Web GUI support
- `#if os(macOS)` - macOS-specific code

### Excluded Components on Linux

The following components are excluded from Linux builds:
- Calendar integration (EventKit)
- Contacts integration (Contacts framework)
- AppleScript support
- Native GUI (AppKit)

## Build Process

### Using the Build Script

```bash
# Run the Linux build script
./scripts/build-linux.sh

# Clean previous builds first
./scripts/build-linux.sh clean
```

### Manual Build

```bash
# Resolve dependencies
swift package resolve

# Build with Web GUI support
swift build -c release -Xswiftc -DWEB_GUI

# Run the built executable
.build/release/kobold web --port 8080 --web-port 8081
```

## Docker Cross-Compilation

The Docker image handles cross-compilation automatically:

```bash
# Build for Linux using Docker
docker build -t koboldos -f docker/Dockerfile .

# Run with automatic platform detection
docker run -p 8080:8080 -p 8081:8081 koboldos
```

## Troubleshooting

### Missing Dependencies

If you get linking errors, ensure all system dependencies are installed:

```bash
# Ubuntu/Debian
sudo apt-get install -y pkg-config

# Check library paths
pkg-config --libs sqlite3
```

### Swift Version Issues

Ensure you're using Swift 5.10 or later:

```bash
swift --version
```

### Conditional Compilation Errors

If Web GUI components don't compile, ensure the WEB_GUI flag is set:

```bash
swift build -Xswiftc -DWEB_GUI
```

## Performance Optimization

For production builds, consider these optimizations:

```bash
# Optimize for size
swift build -c release -Xswiftc -Osize

# Optimize for speed
swift build -c release -Xswiftc -O

# Enable whole module optimization
swift build -c release -Xswiftc -whole-module-optimization
```

## Testing Cross-Compilation

To test if your build works on Linux:

```bash
# Run the test compilation script
./linux/test_compile.sh

# Check the resulting binary
file .build/release/kobold
```

The binary should show: `ELF 64-bit LSB executable, x86-64`