# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Swift-based command-line tool for interacting with Bluetooth Low Energy (BLE) devices on macOS. It provides several commands: `scan` for discovering BLE devices and their services/characteristics, `monitor` for real-time BLE device monitoring, `bridge` for establishing a serial TTY connection to BLE devices, and `autobridge` for interactive terminal sessions with BLE devices.

## Build Commands

```bash
# Build the project
swift build -c release --disable-sandbox

# Build using Makefile
make build

# Install locally 
make install

# Clean build artifacts
make clean

# Run tests
swift test
```

## Architecture

### Command Structure
- **main.swift**: Entry point using Swift ArgumentParser with four subcommands
- **commands/scan.swift**: BLE device scanning functionality with CoreBluetooth integration
- **commands/monitor.swift**: Real-time BLE device monitoring with live updates
- **commands/bridge.swift**: Serial bridge implementation creating PTY connections
- **commands/autobridge.swift**: Interactive terminal bridge with direct I/O to BLE devices

### Core Components

#### Scanner (scan.swift:77-122)
- Implements `CBCentralManagerDelegate` for BLE device discovery
- Supports scanning for all devices or filtering by service UUID
- Handles macOS Monterey compatibility issues with background scanning
- Connects to discovered peripherals to enumerate services and characteristics

#### StreamBridge (bridge.swift:125-223)
- Bidirectional stream bridge between PTY and BLE connections
- Uses custom FileHandle streams for PTY communication
- Integrates with CornucopiaStreams library for BLE connectivity
- Handles PTY reconnection on close events

#### Autobridge (autobridge.swift:13-122)
- Extends bridge functionality by connecting the terminal directly to the created PTY
- Provides immediate interactive I/O with BLE devices through the terminal
- Uses TerminalSession (autobridge.swift:124-245) for terminal management:
  - Applies raw mode to stdin for character-by-character input
  - Bidirectional data flow: stdin → PTY slave → BLE and BLE → PTY slave → stdout
  - Handles Ctrl-C (0x03) for graceful exit and terminal restoration
- Arguments: Service UUID (required), Device UUID (optional)
- Option: `--file-name` to write PTY path to a file
- Useful for quick testing and debugging BLE serial communication

#### Custom Stream Classes
- **FileHandleInputStream/FileHandleOutputStream**: Custom stream implementations for FileHandle integration
- Located in `FileHandleStream/` directory

### Dependencies
- **Swift ArgumentParser**: Command-line interface
- **Chalk**: Terminal color output
- **CornucopiaStreams**: BLE stream connectivity (external library)
- **CoreBluetooth**: macOS BLE framework

### Platform Requirements
- macOS 12+ (specified in Package.swift)
- Bluetooth permissions required for terminal application
- Uses `openpty()` system call for PTY creation

## Key Implementation Details

- UUIDs validated using regex in `CBUUID+Validation.swift`
- Signal handling for graceful SIGINT termination
- RunLoop-based event handling for continuous operation
- Color-coded output using peripheral/service/characteristic hierarchy
- PTY path can be written to file for external process integration

## Future Developments

### Text UI for Autobridge Mode
- A full-featured text-based user interface (TUI) is planned for the autobridge command
- Would provide enhanced visualization of BLE communication, connection status, and device information
- Could include features like scrollable history, split-pane views, and interactive device selection
- Potential frameworks: Swift's swift-term or ncurses-based solutions