# KoboldOS Linux Port

This guide explains how to build and run KoboldOS on Linux systems with integrated Web GUI.

## Prerequisites

- Swift 5.10 or later installed on your system
- Ubuntu 20.04 or newer (other distributions may work but are untested)

## Installing Swift on Ubuntu

```bash
# Download and install Swift
wget https://download.swift.org/swift-5.10-release/ubuntu2004/swift-5.10-RELEASE/swift-5.10-RELEASE-ubuntu20.04.tar.gz
tar xzf swift-5.10-RELEASE-ubuntu20.04.tar.gz
sudo mv swift-5.10-RELEASE-ubuntu20.04 /usr/share/swift

# Add to PATH
echo 'export PATH="/usr/share/swift/usr/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Building KoboldOS

From the root of the KoboldOS repository:

```bash
# Run the build script
./linux/build.sh
```

Or build manually:

```bash
# Resolve dependencies
swift package resolve

# Build the CLI executable with Web GUI support
swift build -c release -Xswiftc -DWEB_GUI
```

## Running KoboldOS

After building, you can run KoboldOS in different modes:

### Daemon Mode
```bash
# Start the daemon
.build/release/kobold daemon --port 8080 --token your-secret-token
```

### Web GUI Mode
```bash
# Start with integrated Web GUI
.build/release/kobold web --port 8080 --web-port 8081 --username admin --password admin --token your-secret-token
```

Then access the Web GUI at `http://localhost:8081` with credentials `admin/admin`.

## Platform Differences

The Linux version of KoboldOS has the following differences from the macOS version:

1. **Calendar Integration**: Disabled on Linux (no EventKit equivalent)
2. **Contacts Integration**: Disabled on Linux (no Contacts framework equivalent)
3. **AppleScript Integration**: Disabled on Linux (macOS-specific)
4. **Keychain Storage**: Uses file-based storage instead of macOS Keychain

All other core functionality remains the same, including:
- Full HTTP API with authentication
- Agent execution with all tools
- Memory management
- Task scheduling
- Workflow execution
- Integrated Web GUI

## Security Considerations

On Linux, secrets are stored in `~/.koboldos/secrets/` as plain text files. In a production environment, you should:

1. Set appropriate file permissions:
   ```bash
   chmod 700 ~/.koboldos/secrets/
   ```

2. Consider using encrypted storage solutions like:
   - EncFS
   - eCryptfs
   - LUKS encrypted partition

## Docker Deployment

For easier deployment, consider using the Docker image instead of building from source:

```bash
# From the docker directory
docker-compose -f docker/docker-compose.yml up -d
```

See `docker/README.md` for more details.